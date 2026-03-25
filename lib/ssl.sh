#!/usr/bin/env bash
# ssl.sh — SSL certificate management
# Handles both direct DNS and Cloudflare proxy automatically
[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

# ---------------------------------------------------------------------------
# Install Certbot
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot + openssl..."
    NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx openssl > /dev/null 2>&1
    log_sub "Certbot installed."
}

# ---------------------------------------------------------------------------
# Resolve domain IP (helper)
# ---------------------------------------------------------------------------
_resolve_domain() {
    local domain="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$domain" 2>/dev/null | head -1
    elif command -v host >/dev/null 2>&1; then
        host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF; exit}'
    else
        getent ahosts "$domain" 2>/dev/null | awk '{print $1; exit}'
    fi
}

# ---------------------------------------------------------------------------
# Detect if domain uses Cloudflare proxy
# ---------------------------------------------------------------------------
_is_cloudflare() {
    local domain_ip="$1"
    # Cloudflare IP ranges (common prefixes)
    # Full list: https://www.cloudflare.com/ips/
    local cf_ranges="103.21. 103.22. 103.31. 104.16. 104.17. 104.18. 104.19. 104.20. 104.21. 104.22. 104.23. 104.24. 104.25. 104.26. 104.27. 108.162. 131.0. 141.101. 162.158. 172.64. 172.65. 172.66. 172.67. 172.68. 172.69. 172.70. 172.71. 173.245. 188.114. 190.93. 197.234. 198.41."
    local prefix
    for prefix in $cf_ranges; do
        if [[ "$domain_ip" == ${prefix}* ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Check DNS and determine SSL strategy
# Sets: DNS_MODE = "direct" | "cloudflare" | "unresolvable"
# ---------------------------------------------------------------------------
check_dns() {
    local domain_ip=""
    DNS_MODE="unresolvable"
    WWW_RESOLVES=false

    log_sub "Checking DNS for $DOMAIN ..."

    domain_ip="$(_resolve_domain "$DOMAIN")"

    if [[ -z "$domain_ip" ]]; then
        log_warn "Could not resolve $DOMAIN — no A record found."
        return 1
    fi

    # Check if IP matches VPS directly
    if [[ "$domain_ip" == "$PUBLIC_IP" ]]; then
        DNS_MODE="direct"
        log_sub "$DOMAIN → $domain_ip (direct to this VPS)"

        # Check www
        local www_ip
        www_ip="$(_resolve_domain "www.${DOMAIN}")"
        if [[ "$www_ip" == "$PUBLIC_IP" ]]; then
            WWW_RESOLVES=true
            log_sub "www.${DOMAIN} also resolves correctly."
        fi
        return 0
    fi

    # Check if IP is Cloudflare
    if _is_cloudflare "$domain_ip"; then
        DNS_MODE="cloudflare"
        log_sub "$DOMAIN → $domain_ip (Cloudflare proxy detected)"
        return 0
    fi

    # IP doesn't match and isn't Cloudflare
    log_warn "$DOMAIN → $domain_ip (not this VPS: $PUBLIC_IP, not Cloudflare)"
    return 1
}

# ---------------------------------------------------------------------------
# Generate self-signed certificate (for Cloudflare Full mode)
# ---------------------------------------------------------------------------
_generate_self_signed() {
    local ssl_dir="/etc/ssl/az-wp"
    mkdir -p "$ssl_dir"

    log_sub "Generating self-signed SSL certificate for Cloudflare..."

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$ssl_dir/${DOMAIN}.key" \
        -out "$ssl_dir/${DOMAIN}.crt" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN}" \
        2>/dev/null

    chmod 600 "$ssl_dir/${DOMAIN}.key"
    chmod 644 "$ssl_dir/${DOMAIN}.crt"

    log_sub "Self-signed cert created (valid 10 years)"
    echo "$ssl_dir"
}

# ---------------------------------------------------------------------------
# Configure Nginx SSL block (for self-signed cert)
# ---------------------------------------------------------------------------
_configure_nginx_ssl() {
    local ssl_dir="$1"
    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    if [[ ! -f "$nginx_conf" ]]; then
        log_error "Nginx config not found: $nginx_conf"
        return 1
    fi

    # Check if already has ssl listen directive
    if grep -q "listen 443 ssl" "$nginx_conf"; then
        log_sub "Nginx already configured for SSL."
        return 0
    fi

    # Add SSL to existing server block:
    # After "listen 80;" add "listen 443 ssl;" and SSL cert paths
    sed -i '/listen 80;/a \    listen 443 ssl;\n    listen [::]:443 ssl;\n    http2 on;\n    ssl_certificate '"$ssl_dir/${DOMAIN}.crt"';\n    ssl_certificate_key '"$ssl_dir/${DOMAIN}.key"';\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_prefer_server_ciphers off;' "$nginx_conf"

    # Add HSTS header
    if ! grep -q "Strict-Transport-Security" "$nginx_conf"; then
        sed -i '/server_tokens off;/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$nginx_conf"
    fi

    log_sub "Nginx SSL configured with self-signed certificate."
}

# ---------------------------------------------------------------------------
# Issue SSL certificate (main function)
# ---------------------------------------------------------------------------
issue_certificate() {
    local wp_admin_email
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || wp_admin_email="${WP_ADMIN_EMAIL:-}"

    if [[ -z "$wp_admin_email" ]]; then
        die "WP_ADMIN_EMAIL not set. Cannot issue SSL certificate."
    fi

    # Detect DNS mode
    if ! check_dns; then
        log_warn "Domain does not resolve. SSL skipped."
        log_info "Point your DNS to $PUBLIC_IP, then run: az-wp ssl issue"
        state_set "SSL_ISSUED" "false"
        return 0
    fi

    case "$DNS_MODE" in
        direct)
            # DNS points directly to VPS → use Let's Encrypt
            _issue_letsencrypt "$wp_admin_email"
            ;;
        cloudflare)
            # DNS through Cloudflare proxy → use self-signed cert
            _issue_cloudflare_ssl
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Let's Encrypt (direct DNS)
# ---------------------------------------------------------------------------
_issue_letsencrypt() {
    local email="$1"

    local certbot_args=(
        --nginx
        --non-interactive
        --agree-tos
        --email "$email"
        -d "$DOMAIN"
    )

    if [[ "$WWW_RESOLVES" == "true" ]]; then
        certbot_args+=(-d "www.${DOMAIN}")
    fi

    log_sub "Requesting Let's Encrypt certificate..."

    if certbot "${certbot_args[@]}" 2>&1; then
        state_set "SSL_ISSUED" "true"
        state_set "SSL_TYPE" "letsencrypt"

        # Ensure HSTS
        local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
        if [[ -f "$nginx_conf" ]] && ! grep -q "Strict-Transport-Security" "$nginx_conf"; then
            sed -i '/ssl_protocols\|ssl_dhparam/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$nginx_conf"
        fi

        service_reload nginx
        log_sub "Let's Encrypt SSL active for $DOMAIN"
    else
        # Certbot failed — fallback to self-signed
        log_warn "Let's Encrypt failed. Falling back to self-signed certificate."
        _issue_cloudflare_ssl
    fi
}

# ---------------------------------------------------------------------------
# Self-signed SSL (Cloudflare proxy or fallback)
# ---------------------------------------------------------------------------
_issue_cloudflare_ssl() {
    local ssl_dir
    ssl_dir="$(_generate_self_signed)"

    _configure_nginx_ssl "$ssl_dir"

    if nginx -t 2>/dev/null; then
        service_reload nginx
        state_set "SSL_ISSUED" "true"
        state_set "SSL_TYPE" "self-signed"
        log_sub "SSL active (self-signed). Set Cloudflare SSL mode to Full."
    else
        log_error "Nginx config test failed after SSL setup."
        state_set "SSL_ISSUED" "false"
    fi
}

# ---------------------------------------------------------------------------
# Setup SSL auto-renewal (Let's Encrypt only)
# ---------------------------------------------------------------------------
setup_ssl_renewal() {
    log_sub "Configuring SSL auto-renewal..."

    # Verify certbot timer is active
    if ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
        systemctl enable --now certbot.timer 2>/dev/null \
            || log_warn "Could not enable certbot.timer."
    fi
    log_sub "certbot.timer is active."

    # Add deploy hook for Nginx reload
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy

    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    log_sub "SSL auto-renewal configured with Nginx reload hook."
}
