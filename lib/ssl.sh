#!/usr/bin/env bash
# ssl.sh — SSL certificate management via Let's Encrypt
# Works with both direct DNS and Cloudflare proxy (HTTP-01 challenge via port 80)
[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

# ---------------------------------------------------------------------------
# Install Certbot
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot..."
    apt_install certbot python3-certbot-nginx
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
# Check if domain resolves (direct or Cloudflare — both OK for HTTP-01)
# ---------------------------------------------------------------------------
check_dns() {
    local domain_ip=""
    WWW_RESOLVES=false

    log_sub "Checking DNS for $DOMAIN ..."

    domain_ip="$(_resolve_domain "$DOMAIN")"

    if [[ -z "$domain_ip" ]]; then
        log_warn "Could not resolve $DOMAIN — no A record found."
        return 1
    fi

    log_sub "$DOMAIN → $domain_ip"

    # Verify HTTP reachability (port 80) — this is what certbot needs
    if curl -sf --max-time 10 -o /dev/null "http://${DOMAIN}/" 2>/dev/null; then
        log_sub "HTTP reachable via port 80 (certbot will work)"
    else
        log_warn "HTTP not reachable on $DOMAIN — certbot may fail"
    fi

    # Check www
    local www_ip
    www_ip="$(_resolve_domain "www.${DOMAIN}")"
    if [[ -n "$www_ip" ]]; then
        WWW_RESOLVES=true
        log_sub "www.${DOMAIN} → $www_ip"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Issue SSL certificate (Let's Encrypt — works behind Cloudflare too)
#
# How it works with Cloudflare proxy:
# - Cloudflare forwards port 80 HTTP to origin
# - Certbot HTTP-01 challenge uses port 80
# - No need to disable proxy or use API tokens
# - Same approach FlashPanel uses
# ---------------------------------------------------------------------------
issue_certificate() {
    local wp_admin_email
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || wp_admin_email="${WP_ADMIN_EMAIL:-}"

    if [[ -z "$wp_admin_email" ]]; then
        die "WP_ADMIN_EMAIL not set."
    fi

    if ! check_dns; then
        log_warn "Domain does not resolve. SSL skipped."
        log_info "Point your DNS to this VPS, then run: azwp ssl issue"
        state_set "SSL_ISSUED" "false"
        return 0
    fi

    # Use certbot with nginx plugin and HTTP-01 challenge
    local certbot_args=(
        --nginx
        --non-interactive
        --agree-tos
        --preferred-challenges http
        --email "$wp_admin_email"
        -d "$DOMAIN"
    )

    if [[ "$WWW_RESOLVES" == "true" ]]; then
        certbot_args+=(-d "www.${DOMAIN}")
    fi

    log_sub "Requesting Let's Encrypt certificate (HTTP-01 challenge)..."

    if certbot "${certbot_args[@]}" 2>&1; then
        state_set "SSL_ISSUED" "true"
        state_set "SSL_TYPE" "letsencrypt"

        # Add HSTS if missing
        local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
        if [[ -f "$nginx_conf" ]] && ! grep -q "Strict-Transport-Security" "$nginx_conf"; then
            sed -i '/server_tokens off;/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$nginx_conf"
        fi

        service_reload nginx
        log_sub "Let's Encrypt SSL active for $DOMAIN"
        log_sub "Auto-renew enabled. Compatible with Cloudflare Full (Strict)."
    else
        state_set "SSL_ISSUED" "false"
        log_warn "SSL certificate failed. You can retry: azwp ssl issue"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Setup SSL auto-renewal
# ---------------------------------------------------------------------------
setup_ssl_renewal() {
    log_sub "Configuring SSL auto-renewal..."

    if ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
        systemctl enable --now certbot.timer 2>/dev/null \
            || log_warn "Could not enable certbot.timer."
    fi
    log_sub "certbot.timer is active."

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    log_sub "SSL auto-renewal configured."
}
