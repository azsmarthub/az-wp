#!/usr/bin/env bash
# ssl.sh — SSL certificate management via Certbot
[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

# ---------------------------------------------------------------------------
# Install Certbot
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot..."

    apt-get install -y -q certbot python3-certbot-nginx 2>&1 | grep -E "^(Setting up)" | tail -3

    log_sub "Certbot installed."
}

# ---------------------------------------------------------------------------
# Check DNS resolution
# ---------------------------------------------------------------------------
check_dns() {
    local domain_ip=""

    log_sub "Checking DNS for $DOMAIN ..."

    # Resolve domain A record
    if command -v dig >/dev/null 2>&1; then
        domain_ip="$(dig +short A "$DOMAIN" 2>/dev/null | head -1)"
    elif command -v host >/dev/null 2>&1; then
        domain_ip="$(host -t A "$DOMAIN" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
    else
        domain_ip="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
    fi

    if [[ -z "$domain_ip" ]]; then
        log_warn "Could not resolve $DOMAIN — no A record found."
        return 1
    fi

    # Compare with VPS public IP
    if [[ "$domain_ip" != "$PUBLIC_IP" ]]; then
        log_warn "DNS mismatch: $DOMAIN resolves to $domain_ip, but VPS IP is $PUBLIC_IP."
        return 1
    fi

    log_sub "$DOMAIN resolves to $domain_ip (matches VPS IP)."

    # Check www subdomain
    local www_ip=""
    WWW_RESOLVES=false

    if command -v dig >/dev/null 2>&1; then
        www_ip="$(dig +short A "www.${DOMAIN}" 2>/dev/null | head -1)"
    elif command -v host >/dev/null 2>&1; then
        www_ip="$(host -t A "www.${DOMAIN}" 2>/dev/null | awk '/has address/ {print $NF; exit}')"
    else
        www_ip="$(getent ahosts "www.${DOMAIN}" 2>/dev/null | awk '{print $1; exit}')"
    fi

    if [[ "$www_ip" == "$PUBLIC_IP" ]]; then
        WWW_RESOLVES=true
        log_sub "www.${DOMAIN} resolves correctly."
    else
        log_sub "www.${DOMAIN} does not resolve to this VPS (skipping www in SSL)."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Issue SSL certificate
# ---------------------------------------------------------------------------
issue_certificate() {
    local wp_admin_email
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || wp_admin_email="${WP_ADMIN_EMAIL:-}"

    if [[ -z "$wp_admin_email" ]]; then
        die "WP_ADMIN_EMAIL not set. Cannot issue SSL certificate."
    fi

    # Check DNS first
    if ! check_dns; then
        log_warn "DNS not pointing to this VPS. Skipping SSL."
        state_set "SSL_ISSUED" "false"
        return 0
    fi

    # Build certbot arguments
    local certbot_args=(
        --nginx
        --non-interactive
        --agree-tos
        --email "$wp_admin_email"
        -d "$DOMAIN"
    )

    if [[ "$WWW_RESOLVES" == "true" ]]; then
        certbot_args+=(-d "www.${DOMAIN}")
    fi

    log_sub "Requesting SSL certificate from Let's Encrypt..."

    if certbot "${certbot_args[@]}"; then
        state_set "SSL_ISSUED" "true"

        # Ensure HSTS header is present in Nginx config
        local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
        if [[ -f "$nginx_conf" ]]; then
            if ! grep -q "Strict-Transport-Security" "$nginx_conf"; then
                # Add HSTS after ssl_protocols or ssl_dhparam line
                if grep -q "ssl_protocols\|ssl_dhparam" "$nginx_conf"; then
                    sed -i '/ssl_protocols\|ssl_dhparam/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$nginx_conf"
                    log_sub "Added HSTS header to Nginx config."
                fi
            fi
        fi

        service_reload nginx
        log_sub "SSL certificate issued for $DOMAIN"
    else
        state_set "SSL_ISSUED" "false"
        log_warn "SSL certificate failed. You can try again via: az-wp ssl issue"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Setup SSL auto-renewal
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
