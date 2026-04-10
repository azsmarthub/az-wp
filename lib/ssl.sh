#!/usr/bin/env bash
# ssl.sh — SSL certificate management (multi-tier)
#
# Strategy (auto-detect):
#   Tier 1  HTTP-01 via --nginx        (direct DNS, or CF without forced HTTPS)
#   Tier 2  DNS-01 via dns-cloudflare  (CF proxy + CF credentials available)
#
# User can force a method by setting state SSL_METHOD=http-01|dns-01|auto.
# Cloudflare credentials are the same ones used by the cache feature
# (CF_EMAIL + CF_API_KEY in /etc/azwp/config) — no duplicate setup.

[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

CF_CREDS_FILE="/root/.secrets/cloudflare.ini"

# ---------------------------------------------------------------------------
# Install certbot + plugins (nginx + dns-cloudflare)
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot + plugins..."
    apt_install certbot python3-certbot-nginx python3-certbot-dns-cloudflare
    log_sub "Certbot installed."
}

# ---------------------------------------------------------------------------
# DNS helpers
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

check_dns() {
    WWW_RESOLVES=false
    log_sub "Checking DNS for $DOMAIN ..."

    local domain_ip
    domain_ip="$(_resolve_domain "$DOMAIN")"
    if [[ -z "$domain_ip" ]]; then
        log_warn "Could not resolve $DOMAIN — no A record found."
        return 1
    fi
    log_sub "$DOMAIN → $domain_ip"

    local www_ip
    www_ip="$(_resolve_domain "www.${DOMAIN}")"
    if [[ -n "$www_ip" ]]; then
        WWW_RESOLVES=true
        log_sub "www.${DOMAIN} → $www_ip"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Detect if domain is behind Cloudflare proxy (orange cloud)
# Returns 0 if proxied, 1 if not.
# ---------------------------------------------------------------------------
detect_cloudflare_proxy() {
    local headers
    headers="$(curl -sI --max-time 8 "http://${DOMAIN}/" 2>/dev/null)" || return 1
    if grep -qiE '^(server:[[:space:]]*cloudflare|cf-ray:)' <<<"$headers"; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Write CF credentials file for certbot-dns-cloudflare
# Uses Global API Key (already stored by cache feature).
# ---------------------------------------------------------------------------
_write_cf_creds() {
    local cf_email cf_key
    cf_email="$(config_get CF_EMAIL 2>/dev/null)" || cf_email=""
    cf_key="$(config_get CF_API_KEY 2>/dev/null)" || cf_key=""

    if [[ -z "$cf_email" || -z "$cf_key" ]]; then
        return 1
    fi

    mkdir -p "$(dirname "$CF_CREDS_FILE")"
    chmod 700 "$(dirname "$CF_CREDS_FILE")"
    cat > "$CF_CREDS_FILE" <<EOF
# Managed by azwp — Cloudflare credentials for certbot DNS-01
dns_cloudflare_email = ${cf_email}
dns_cloudflare_api_key = ${cf_key}
EOF
    chmod 600 "$CF_CREDS_FILE"
    return 0
}

_has_cf_creds() {
    local cf_email cf_key
    cf_email="$(config_get CF_EMAIL 2>/dev/null)" || cf_email=""
    cf_key="$(config_get CF_API_KEY 2>/dev/null)" || cf_key=""
    [[ -n "$cf_email" && -n "$cf_key" ]]
}

# ---------------------------------------------------------------------------
# Tier 1: HTTP-01 via --nginx
# ---------------------------------------------------------------------------
_issue_http01() {
    local email="$1"
    local args=(
        --nginx
        --non-interactive
        --agree-tos
        --preferred-challenges http
        --email "$email"
        -d "$DOMAIN"
    )
    [[ "$WWW_RESOLVES" == "true" ]] && args+=(-d "www.${DOMAIN}")

    log_sub "Method: HTTP-01 via nginx"
    certbot "${args[@]}" 2>&1
}

# ---------------------------------------------------------------------------
# Tier 2: DNS-01 via Cloudflare plugin
# ---------------------------------------------------------------------------
_issue_dns01_cf() {
    local email="$1"

    if ! _write_cf_creds; then
        log_error "Cloudflare credentials not configured. Run: azwp advanced cloudflare"
        return 1
    fi

    if ! dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
        log_sub "Installing certbot-dns-cloudflare plugin..."
        apt_install python3-certbot-dns-cloudflare
    fi

    local args=(
        -a dns-cloudflare
        -i nginx
        --dns-cloudflare-credentials "$CF_CREDS_FILE"
        --dns-cloudflare-propagation-seconds 30
        --non-interactive
        --agree-tos
        --email "$email"
        -d "$DOMAIN"
    )
    [[ "$WWW_RESOLVES" == "true" ]] && args+=(-d "www.${DOMAIN}")

    log_sub "Method: DNS-01 via Cloudflare API"
    certbot "${args[@]}" 2>&1
}

# ---------------------------------------------------------------------------
# Post-issue: HSTS header + reload + state
# ---------------------------------------------------------------------------
_post_issue_success() {
    local method="$1"
    state_set "SSL_ISSUED" "true"
    state_set "SSL_TYPE" "letsencrypt"
    state_set "SSL_METHOD_USED" "$method"

    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
    if [[ -f "$nginx_conf" ]] && ! grep -q "Strict-Transport-Security" "$nginx_conf"; then
        sed -i '/server_tokens off;/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$nginx_conf"
    fi

    service_reload nginx
    log_sub "Let's Encrypt SSL active for $DOMAIN (method: $method)"
    log_sub "Auto-renew enabled. Compatible with Cloudflare Full (Strict)."
}

_post_issue_fail() {
    local reason="$1"
    state_set "SSL_ISSUED" "false"
    log_warn "SSL certificate failed: $reason"
    printf "\n"
    printf "  ${YELLOW}How to fix:${NC}\n"
    if detect_cloudflare_proxy 2>/dev/null; then
        printf "  Your domain is behind Cloudflare proxy. HTTP-01 is blocked by CF\n"
        printf "  (likely 'Always Use HTTPS' or a Page Rule forcing HTTPS redirect).\n\n"
        printf "  ${GREEN}Recommended — use DNS-01 challenge (bypasses HTTP entirely):${NC}\n"
        printf "    1) azwp advanced cloudflare   ${DIM}# configure CF email + Global API Key${NC}\n"
        printf "    2) azwp ssl issue              ${DIM}# will auto-use DNS-01${NC}\n\n"
        printf "  ${DIM}Alternative: temporarily disable 'Always Use HTTPS' in CF dashboard,${NC}\n"
        printf "  ${DIM}then run 'azwp ssl issue', then re-enable.${NC}\n"
    else
        printf "  Check that DNS points to this VPS and port 80 is reachable,\n"
        printf "  then retry: azwp ssl issue\n"
    fi
    printf "\n"
}

# ---------------------------------------------------------------------------
# Main: issue certificate (smart dispatcher)
# ---------------------------------------------------------------------------
issue_certificate() {
    local wp_admin_email
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || wp_admin_email="${WP_ADMIN_EMAIL:-}"
    [[ -z "$wp_admin_email" ]] && die "WP_ADMIN_EMAIL not set."

    if ! check_dns; then
        log_warn "Domain does not resolve. SSL skipped."
        log_info "Point your DNS to this VPS (or via Cloudflare), then run: azwp ssl issue"
        state_set "SSL_ISSUED" "false"
        return 0
    fi

    local method forced output rc
    forced="$(state_get SSL_METHOD 2>/dev/null)" || forced=""
    [[ -z "$forced" ]] && forced="auto"

    # Resolve method
    if [[ "$forced" == "http-01" ]]; then
        method="http-01"
    elif [[ "$forced" == "dns-01" ]]; then
        method="dns-01"
    else
        # auto: detect CF + creds
        if detect_cloudflare_proxy; then
            log_sub "Cloudflare proxy detected."
            if _has_cf_creds; then
                method="dns-01"
            else
                method="http-01"
                log_sub "No CF credentials — will try HTTP-01 first."
            fi
        else
            method="http-01"
        fi
    fi

    log_sub "Requesting Let's Encrypt certificate..."

    if [[ "$method" == "dns-01" ]]; then
        if output="$(_issue_dns01_cf "$wp_admin_email")"; then
            _post_issue_success "dns-01"
            return 0
        fi
        printf '%s\n' "$output"
        _post_issue_fail "DNS-01 challenge failed — check CF credentials validity"
        return 0
    fi

    # HTTP-01 path
    if output="$(_issue_http01 "$wp_admin_email")"; then
        _post_issue_success "http-01"
        return 0
    fi
    printf '%s\n' "$output"

    # Auto-fallback: HTTP-01 failed + CF proxy + creds available → try DNS-01
    if [[ "$forced" == "auto" ]] && detect_cloudflare_proxy && _has_cf_creds; then
        log_sub "HTTP-01 failed — auto-falling back to DNS-01..."
        if output="$(_issue_dns01_cf "$wp_admin_email")"; then
            _post_issue_success "dns-01"
            return 0
        fi
        printf '%s\n' "$output"
        _post_issue_fail "Both HTTP-01 and DNS-01 failed"
        return 0
    fi

    _post_issue_fail "HTTP-01 challenge failed"
    return 0
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
