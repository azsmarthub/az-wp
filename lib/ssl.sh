#!/usr/bin/env bash
# ssl.sh — SSL certificate issuance
#
# Strategy: detect existing valid cert → bootstrap origin :443 → run certbot
# via HTTP-01 through Cloudflare's "301 HTTP → HTTPS" path. This is the same
# pattern FlashPanel and other panels use to renew certs behind CF proxy
# without requiring user action at Cloudflare.
#
# Order of attempts:
#   1. Direct HTTP-01 via certbot --nginx (works when CF proxy is off, or
#      when CF does not force HTTPS on /.well-known/acme-challenge).
#   2. Reuse-existing-cert bootstrap: find an existing valid cert for the
#      domain (from FlashPanel, previous azwp, cPanel, raw LE paths, or a
#      user-supplied file), use it as the origin :443 cert, then run
#      certbot --webroot. LE follows CF's 301 to HTTPS, origin serves the
#      valid cert, CF Full (Strict) accepts, the webroot location serves
#      the challenge file, validation passes. Replaces bootstrap cert
#      with the freshly-issued LE cert on success.
#   3. Fail with actionable instructions for the user.
#
# Honors env var AZWP_SSL_STAGING=1 to use LE staging (no rate limits).

[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

AZWP_SSL_BOOTSTRAP_DIR="/etc/ssl/azwp-bootstrap"

# ---------------------------------------------------------------------------
# Install certbot (nginx plugin for method 1; webroot doesn't need a plugin)
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot..."
    apt_install certbot python3-certbot-nginx
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

# Detect Cloudflare proxy via response headers
detect_cloudflare_proxy() {
    local headers
    headers="$(curl -sI --max-time 8 "http://${DOMAIN}/" 2>/dev/null)" || return 1
    grep -qiE '^(server:[[:space:]]*cloudflare|cf-ray:)' <<<"$headers"
}

# ---------------------------------------------------------------------------
# Cert match: return 0 if $1 cert file covers $DOMAIN (CN or SAN) and is
# valid for at least 7 more days.
# ---------------------------------------------------------------------------
_cert_matches_domain() {
    local cert="$1"
    [[ -f "$cert" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    local text
    text="$(openssl x509 -in "$cert" -noout -text 2>/dev/null)" || return 1
    grep -qE "(CN[[:space:]]*=[[:space:]]*${DOMAIN}([[:space:]]|$|,)|DNS:${DOMAIN}([[:space:]]|$|,))" <<<"$text"
}

# Given a cert file path, find the matching key file. Echoes key path on stdout.
_find_key_for_cert() {
    local cert="$1"
    local dir base candidates=()
    dir="$(dirname "$cert")"
    base="$(basename "$cert")"

    case "$base" in
        server.crt)    candidates+=("$dir/server.key") ;;
        fullchain.pem) candidates+=("$dir/privkey.pem") ;;
        cert.pem)      candidates+=("$dir/privkey.pem" "$dir/key.pem") ;;
        *.crt)         candidates+=("${cert%.crt}.key") ;;
        *.pem)         candidates+=("${cert%.pem}.key" "${cert%.pem}-key.pem") ;;
    esac
    candidates+=("$dir/privkey.pem" "$dir/server.key" "$dir/key.pem")

    local k
    for k in "${candidates[@]}"; do
        [[ -f "$k" ]] && { printf '%s' "$k"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# Search common locations for a valid cert matching $DOMAIN.
# On success prints "cert_path|key_path" and returns 0.
# ---------------------------------------------------------------------------
_find_existing_cert() {
    local patterns=(
        # Let's Encrypt native
        "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        "/etc/letsencrypt/live/${DOMAIN}-*/fullchain.pem"
        # azwp's own bootstrap dir (previous install)
        "${AZWP_SSL_BOOTSTRAP_DIR}/cert.pem"
        # User-staged cert before reinstall
        "/tmp/azwp-preinstall/cert.pem"
        "/tmp/azwp-preinstall/fullchain.pem"
        # FlashPanel
        "/root/.flashpanel/certificates/*/server.crt"
        # CloudPanel
        "/etc/nginx/ssl-certificates/${DOMAIN}.crt"
        # CyberPanel / OLS
        "/etc/letsencrypt/live/${DOMAIN}/cert.pem"
        # cPanel
        "/var/cpanel/ssl/apache_tls/${DOMAIN}/combined"
        # Generic panel/ssl dirs
        "/etc/ssl/${DOMAIN}/fullchain.pem"
        "/etc/ssl/${DOMAIN}/cert.pem"
    )

    local pat cert key
    for pat in "${patterns[@]}"; do
        # shellcheck disable=SC2086
        for cert in $pat; do
            [[ -f "$cert" ]] || continue
            if _cert_matches_domain "$cert"; then
                if key="$(_find_key_for_cert "$cert")" && [[ -f "$key" ]]; then
                    printf '%s|%s' "$cert" "$key"
                    return 0
                fi
            fi
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# Bootstrap nginx :443 using an existing cert so Cloudflare Full (Strict)
# accepts the origin, allowing LE HTTP-01 to validate via the 301→HTTPS path.
# ---------------------------------------------------------------------------
_bootstrap_nginx_with_cert() {
    local src_cert="$1" src_key="$2"
    local conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    [[ -f "$conf" ]] || { log_error "nginx vhost not found: $conf"; return 1; }

    log_sub "Bootstrap: reusing existing cert → $(basename "$(dirname "$src_cert")")/$(basename "$src_cert")"

    mkdir -p "$AZWP_SSL_BOOTSTRAP_DIR"
    chmod 700 "$AZWP_SSL_BOOTSTRAP_DIR"
    cp "$src_cert" "$AZWP_SSL_BOOTSTRAP_DIR/cert.pem"
    cp "$src_key"  "$AZWP_SSL_BOOTSTRAP_DIR/key.pem"
    chmod 600 "$AZWP_SSL_BOOTSTRAP_DIR/key.pem"

    # Inject :443 block if the vhost does not already have one
    if ! grep -qE '^\s*listen\s+443\s+ssl' "$conf"; then
        local ssl_block="    listen 443 ssl;
    listen [::]:443 ssl;
    ssl_certificate ${AZWP_SSL_BOOTSTRAP_DIR}/cert.pem;
    ssl_certificate_key ${AZWP_SSL_BOOTSTRAP_DIR}/key.pem;"

        awk -v block="$ssl_block" '
            {print}
            /listen \[::\]:80;/ && !done {print block; done=1}
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    # Ensure webroot has the .well-known/acme-challenge path used by certbot --webroot
    mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"
    chown -R "$SITE_USER:$SITE_USER" "${WEB_ROOT}/.well-known" 2>/dev/null || true

    if ! nginx -t >/dev/null 2>&1; then
        log_error "Bootstrap: nginx config test failed"
        nginx -t 2>&1 | tail -5
        return 1
    fi
    service_reload nginx
    log_sub "Bootstrap: origin :443 now serving existing cert"
    return 0
}

# After cert is issued, swap nginx to use the new LE cert and remove bootstrap
_promote_cert_to_nginx() {
    local new_cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local new_key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    local conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    [[ -f "$new_cert" && -f "$new_key" ]] || { log_error "Promote: LE cert not found"; return 1; }

    sed -i "s|${AZWP_SSL_BOOTSTRAP_DIR}/cert.pem|${new_cert}|g" "$conf"
    sed -i "s|${AZWP_SSL_BOOTSTRAP_DIR}/key.pem|${new_key}|g"   "$conf"

    if ! nginx -t >/dev/null 2>&1; then
        log_error "Promote: nginx config test failed"
        return 1
    fi
    service_reload nginx

    # Bootstrap cert no longer needed for runtime; keep it as a fallback for
    # future re-issuance so we never get stuck at chicken-and-egg again.
    log_sub "Promoted to Let's Encrypt cert; bootstrap preserved in ${AZWP_SSL_BOOTSTRAP_DIR}"
}

# ---------------------------------------------------------------------------
# Certbot wrappers
# ---------------------------------------------------------------------------
_certbot_staging_flag() {
    [[ "${AZWP_SSL_STAGING:-}" == "1" ]] && echo "--staging"
}

# Method 1: direct HTTP-01 via --nginx (works when no CF proxy or CF doesn't
# force HTTPS on ACME path).
_issue_http01_nginx() {
    local email="$1" staging
    staging="$(_certbot_staging_flag)"

    local args=(
        --nginx --non-interactive --agree-tos
        --preferred-challenges http
        --email "$email"
        -d "$DOMAIN"
    )
    [[ "$WWW_RESOLVES" == "true" ]] && args+=(-d "www.${DOMAIN}")
    [[ -n "$staging" ]] && args+=("$staging")

    log_sub "Method 1: HTTP-01 via nginx"
    certbot "${args[@]}" 2>&1
}

# Method 2: webroot HTTP-01 (expects :443 bootstrapped with a valid cert).
_issue_http01_webroot() {
    local email="$1" staging
    staging="$(_certbot_staging_flag)"

    local args=(
        certonly --webroot -w "$WEB_ROOT"
        --non-interactive --agree-tos
        --email "$email"
        -d "$DOMAIN"
    )
    [[ "$WWW_RESOLVES" == "true" ]] && args+=(-d "www.${DOMAIN}")
    [[ -n "$staging" ]] && args+=("$staging")

    log_sub "Method 2: HTTP-01 via webroot (reuse-cert bootstrap)"
    certbot "${args[@]}" 2>&1
}

# ---------------------------------------------------------------------------
# Post-issue: HSTS + state + reload
# ---------------------------------------------------------------------------
_post_issue_success() {
    local method="$1"
    state_set "SSL_ISSUED" "true"
    state_set "SSL_TYPE" "letsencrypt"
    state_set "SSL_METHOD_USED" "$method"

    local conf="/etc/nginx/sites-available/${DOMAIN}.conf"
    if [[ -f "$conf" ]] && ! grep -q "Strict-Transport-Security" "$conf"; then
        sed -i '/server_tokens off;/a \    add_header Strict-Transport-Security "max-age=63072000" always;' "$conf"
        service_reload nginx
    fi

    log_sub "Let's Encrypt SSL active for $DOMAIN (method: $method)"
    log_sub "Auto-renew enabled via certbot.timer. Compatible with Cloudflare Full (Strict)."
}

_post_issue_fail() {
    local reason="$1"
    state_set "SSL_ISSUED" "false"
    log_warn "SSL certificate failed: $reason"
    printf "\n"
    printf "  ${YELLOW}How to fix:${NC}\n"
    if detect_cloudflare_proxy 2>/dev/null; then
        printf "  Your domain is behind Cloudflare proxy and no existing cert was\n"
        printf "  found on this VPS to bootstrap the :443 origin.\n\n"
        printf "  ${GREEN}Pick one of these (ordered by ease):${NC}\n\n"
        printf "  1) ${BOLD}Reuse an existing cert${NC} (zero Cloudflare action)\n"
        printf "     Place a valid cert + key for $DOMAIN at:\n"
        printf "       /tmp/azwp-preinstall/cert.pem\n"
        printf "       /tmp/azwp-preinstall/privkey.pem\n"
        printf "     Then run: azwp ssl issue\n\n"
        printf "  2) ${BOLD}Pause Cloudflare proxy${NC} temporarily (grey cloud)\n"
        printf "     DNS → click orange cloud on $DOMAIN and www → grey\n"
        printf "     Run: azwp ssl issue\n"
        printf "     Click back to orange once cert is issued.\n\n"
        printf "  3) ${BOLD}Disable 'Always Use HTTPS'${NC} temporarily\n"
        printf "     CF → SSL/TLS → Edge Certificates → Always Use HTTPS: Off\n"
        printf "     Run: azwp ssl issue  (then toggle back on)\n\n"
    else
        printf "  Check that DNS points to this VPS and port 80 is reachable,\n"
        printf "  then retry: azwp ssl issue\n\n"
    fi
}

# ---------------------------------------------------------------------------
# Main dispatcher
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

    local cf_proxy=false
    if detect_cloudflare_proxy; then
        cf_proxy=true
        log_sub "Cloudflare proxy detected."
    fi

    log_sub "Requesting Let's Encrypt certificate..."

    # ----- Attempt 1: direct HTTP-01 via --nginx -----
    # Skip this attempt when CF proxy is detected, because CF with default
    # settings usually redirects HTTP → HTTPS at the edge, making HTTP-01
    # on :80 fail before it can reach origin.
    if [[ "$cf_proxy" == "false" ]]; then
        local output
        if output="$(_issue_http01_nginx "$wp_admin_email")"; then
            _post_issue_success "http-01-nginx"
            return 0
        fi
        printf '%s\n' "$output"
        log_sub "HTTP-01 via nginx failed — trying reuse-cert bootstrap"
    fi

    # ----- Attempt 2: reuse-existing-cert bootstrap + webroot HTTP-01 -----
    local existing
    if existing="$(_find_existing_cert)"; then
        local src_cert="${existing%|*}" src_key="${existing#*|}"
        if _bootstrap_nginx_with_cert "$src_cert" "$src_key"; then
            local output
            if output="$(_issue_http01_webroot "$wp_admin_email")"; then
                _promote_cert_to_nginx
                _post_issue_success "http-01-webroot-bootstrap"
                return 0
            fi
            printf '%s\n' "$output"
            log_sub "Webroot HTTP-01 failed after bootstrap"
        fi
    else
        log_sub "No existing cert found to bootstrap :443"
    fi

    # ----- Fail -----
    _post_issue_fail "All methods failed"
    return 0
}

# ---------------------------------------------------------------------------
# Renewal hook
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
