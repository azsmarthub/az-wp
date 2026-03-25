#!/usr/bin/env bash
# nginx.sh — Install and configure Nginx
[[ -n "${_AZ_NGINX_LOADED:-}" ]] && return 0
_AZ_NGINX_LOADED=1

# ---------------------------------------------------------------------------
# Install Nginx from official stable repo
# ---------------------------------------------------------------------------
install_nginx() {
    log_sub "Adding nginx.org official repo..."
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null

    local codename
    codename="$(lsb_release -cs)"
    printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu %s nginx\n' \
        "$codename" > /etc/apt/sources.list.d/nginx.list

    printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' \
        > /etc/apt/preferences.d/99-nginx

    log_sub "Installing Nginx..."
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nginx 2>&1 | grep -E "^(Setting up|nginx)" | tail -2

    systemctl enable nginx 2>/dev/null

    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf

    log_sub "Nginx $(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+') installed"
}

# ---------------------------------------------------------------------------
# Configure main nginx.conf
# ---------------------------------------------------------------------------
configure_nginx() {
    log_sub "Configuring nginx.conf..."

    export TUNE_NGINX_WORKERS TUNE_NGINX_RLIMIT_NOFILE TUNE_NGINX_WORKER_CONNECTIONS

    render_template \
        "${AZ_DIR}/templates/nginx/nginx.conf.tpl" \
        /etc/nginx/nginx.conf \
        "TUNE_NGINX_WORKERS TUNE_NGINX_RLIMIT_NOFILE TUNE_NGINX_WORKER_CONNECTIONS"

    log_sub "nginx.conf configured"
}

# ---------------------------------------------------------------------------
# Configure FastCGI cache zone
# ---------------------------------------------------------------------------
configure_fastcgi_cache() {
    log_sub "Configuring FastCGI cache..."

    mkdir -p "$CACHE_PATH"
    chown "$SITE_USER":"$SITE_USER" "$CACHE_PATH"

    export CACHE_PATH TUNE_CACHE_KEYS_ZONE TUNE_CACHE_MAX_SIZE

    render_template \
        "${AZ_DIR}/templates/nginx/fastcgi-cache.conf.tpl" \
        /etc/nginx/conf.d/fastcgi-cache.conf \
        "CACHE_PATH TUNE_CACHE_KEYS_ZONE TUNE_CACHE_MAX_SIZE"

    log_sub "FastCGI cache configured at ${CACHE_PATH}"
}

# ---------------------------------------------------------------------------
# Configure site server block
# ---------------------------------------------------------------------------
configure_site() {
    log_sub "Configuring site: ${DOMAIN}..."

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    export DOMAIN WEB_ROOT PHP_VERSION

    local site_conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    render_template \
        "${AZ_DIR}/templates/nginx/site.conf.tpl" \
        "$site_conf" \
        "DOMAIN WEB_ROOT PHP_VERSION"

    # Single pool mode: replace workers sock with web sock
    if [[ "$TUNE_WORKERS_ENABLED" == "false" ]]; then
        sed -i 's|fpm-workers\.sock|fpm-web.sock|g' "$site_conf"
        # Remove fpm-workers-status location block
        sed -i '/location = \/fpm-workers-status/,/}/d' "$site_conf"
        log_sub "Workers pool disabled — all requests route to web pool"
    fi

    ln -sf "$site_conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

    log_sub "Site ${DOMAIN} configured"
}

# ---------------------------------------------------------------------------
# Test Nginx configuration
# ---------------------------------------------------------------------------
test_nginx() {
    nginx -t 2>&1
    return $?
}
