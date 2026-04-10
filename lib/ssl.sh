#!/usr/bin/env bash
# ssl.sh — SSL certificate management (azwp)
#
# Strategy (same as m-wp, proven to work on bs-doctor.com):
#
#   1. Domain DNS → this server directly → Let's Encrypt HTTP-01 via certbot --nginx
#   2. Domain DNS → Cloudflare proxy IP  → 10-year self-signed origin cert
#      (CF in "Full" mode accepts any origin cert. Visitors see CF's edge cert,
#      so the self-signed is only used for the CF↔origin leg. No LE required.
#      No user action at CF. No chicken-and-egg. Just works.)
#   3. DNS not propagated or points elsewhere → skip with hint
#
# For CF "Full (Strict)" mode, self-signed is rejected (526). User must switch
# to "Full" OR manually install a Cloudflare Origin Certificate at
# ${SS_DIR}/{fullchain,privkey}.pem. The post-issue check warns when origin
# returns 526 via CF so the user knows what to do.

[[ -n "${_AZ_SSL_LOADED:-}" ]] && return 0
_AZ_SSL_LOADED=1

AZ_SS_DIR_BASE="/etc/azwp/ssl"

# ---------------------------------------------------------------------------
# Install certbot (only used when DNS is direct to this server)
# ---------------------------------------------------------------------------
install_certbot() {
    log_sub "Installing Certbot..."
    apt_install certbot python3-certbot-nginx
    log_sub "Certbot installed."
}

# ---------------------------------------------------------------------------
# Get this server's public IP
# ---------------------------------------------------------------------------
_get_server_ip() {
    local ip
    ip="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)" || \
    ip="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null)" || \
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || \
    ip=""
    printf '%s' "$ip"
}

# ---------------------------------------------------------------------------
# Resolve A record for $1
# ---------------------------------------------------------------------------
_resolve_domain() {
    local domain="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1
    elif command -v host >/dev/null 2>&1; then
        host -t A "$domain" 2>/dev/null | awk '/has address/ {print $NF; exit}'
    else
        getent ahosts "$domain" 2>/dev/null | awk '{print $1; exit}'
    fi
}

# ---------------------------------------------------------------------------
# Is $1 a Cloudflare anycast IPv4?
# Source: https://www.cloudflare.com/ips-v4
# ---------------------------------------------------------------------------
_is_cloudflare_ip() {
    local ip="$1"
    local first="${ip%%.*}"
    local rest="${ip#*.}"
    local second="${rest%%.*}"
    case "${first}.${second}" in
        104.16|104.17|104.18|104.19|104.20|104.21|104.22|104.23) return 0 ;;
        104.24|104.25|104.26|104.27|104.28|104.29|104.30|104.31) return 0 ;;
        172.64|172.65|172.66|172.67|172.68|172.69|172.70|172.71) return 0 ;;
        162.158) return 0 ;;
        103.21|103.22|103.31) return 0 ;;
        108.162) return 0 ;;
        131.0)   return 0 ;;
        141.101) return 0 ;;
        173.245) return 0 ;;
        188.114) return 0 ;;
        190.93)  return 0 ;;
        197.234) return 0 ;;
        198.41)  return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Inject listen 443 ssl + ssl_certificate into the existing :80 server block
# of the site's vhost. Both ports end up sharing all location blocks.
# Safe to call multiple times — updates cert paths if :443 already present.
# ---------------------------------------------------------------------------
_nginx_enable_443() {
    local cert_path="$1" key_path="$2"
    local conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    [[ -f "$conf" ]] || { log_error "nginx vhost not found: $conf"; return 1; }

    if grep -qE '^\s*listen\s+443\s+ssl' "$conf"; then
        # Already has :443 — just update cert paths
        sed -i "s|^\(\s*ssl_certificate\)\s\+.*;|\1 ${cert_path};|"      "$conf"
        sed -i "s|^\(\s*ssl_certificate_key\)\s\+.*;|\1 ${key_path};|"   "$conf"
    else
        # Inject listen 443 + cert directives right after `listen [::]:80;`
        local block="    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security \"max-age=63072000\" always;"

        awk -v block="$block" '
            {print}
            /listen \[::\]:80;/ && !done {print block; done=1}
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    nginx -t >/dev/null 2>&1 || { log_error "nginx config test failed"; nginx -t 2>&1 | tail -5; return 1; }
    service_reload nginx
    return 0
}

# ---------------------------------------------------------------------------
# Method A: Let's Encrypt via certbot --nginx (direct DNS to this server)
# ---------------------------------------------------------------------------
_issue_letsencrypt() {
    local email="$1"
    local include_www=""
    [[ "$WWW_RESOLVES" == "true" ]] && include_www="-d www.${DOMAIN}"

    rm -rf /etc/letsencrypt/accounts/ 2>/dev/null || true

    log_sub "Requesting Let's Encrypt certificate (HTTP-01 via nginx)..."
    local args=(
        --nginx --non-interactive --agree-tos
        --preferred-challenges http
        --email "$email"
        -d "$DOMAIN"
    )
    [[ -n "$include_www" ]] && args+=(-d "www.${DOMAIN}")
    [[ "${AZWP_SSL_STAGING:-}" == "1" ]] && { args+=(--staging); log_sub "Using LE STAGING (test cert)"; }

    if ! certbot "${args[@]}" 2>&1 | tail -15; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Method B: Self-signed origin cert (CF-proxied domains, CF Full mode)
# 10-year validity; no renewal needed during normal site lifetime.
# ---------------------------------------------------------------------------
_issue_self_signed() {
    command -v openssl >/dev/null 2>&1 || { log_error "openssl not found"; return 1; }

    local ss_dir="${AZ_SS_DIR_BASE}/${DOMAIN}"
    mkdir -p "$ss_dir"
    chmod 700 "$(dirname "$ss_dir")" "$ss_dir"

    log_sub "Generating 10-year self-signed origin cert for ${DOMAIN}..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -days 3650 \
        -keyout "$ss_dir/privkey.pem" \
        -out    "$ss_dir/fullchain.pem" \
        -subj   "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN}" \
        >/dev/null 2>&1

    chmod 600 "$ss_dir/privkey.pem"
    chmod 644 "$ss_dir/fullchain.pem"

    if ! _nginx_enable_443 "$ss_dir/fullchain.pem" "$ss_dir/privkey.pem"; then
        return 1
    fi
    printf '%s/fullchain.pem|%s/privkey.pem' "$ss_dir" "$ss_dir"
    return 0
}

# ---------------------------------------------------------------------------
# Verify that CF can actually reach the self-signed origin (catches Full Strict)
# Returns 0 if HTTPS via CF returns a working status, 1 if CF rejects.
# ---------------------------------------------------------------------------
_verify_cf_accepts_origin() {
    # Give CF a moment to pick up the new :443 listener
    sleep 2
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/" 2>/dev/null)" || code="000"
    case "$code" in
        5[23][0-9])
            # 520-526: Cloudflare error codes (526 = Invalid SSL cert → Full Strict)
            return 1
            ;;
        000)
            # Timeout / unreachable
            return 1
            ;;
        *)
            # Any 2xx/3xx/4xx from origin means CF reached origin successfully
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Post-issue: state + WP URL rewrite + friendly summary
# ---------------------------------------------------------------------------
_post_issue_success() {
    local method="$1"
    state_set "SSL_ISSUED" "true"
    state_set "SSL_TYPE" "$method"
    state_set "SSL_METHOD_USED" "$method"

    # Update WordPress URLs if installed
    if [[ -n "${SITE_USER:-}" && -d "${WEB_ROOT:-/nonexistent}" ]] && command -v wp >/dev/null 2>&1; then
        sudo -u "$SITE_USER" wp --path="$WEB_ROOT" option update home    "https://${DOMAIN}" 2>/dev/null | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp --path="$WEB_ROOT" option update siteurl "https://${DOMAIN}" 2>/dev/null | grep -v Deprecated || true
    fi

    log_sub "SSL active for ${DOMAIN} (method: ${method})"
}

# ---------------------------------------------------------------------------
# Main entrypoint
# ---------------------------------------------------------------------------
issue_certificate() {
    local wp_admin_email
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || wp_admin_email="${WP_ADMIN_EMAIL:-}"
    [[ -z "$wp_admin_email" ]] && die "WP_ADMIN_EMAIL not set."

    log_sub "Resolving ${DOMAIN} ..."
    local apex_ip server_ip www_ip
    apex_ip="$(_resolve_domain "$DOMAIN")"
    server_ip="$(_get_server_ip)"

    WWW_RESOLVES=false
    www_ip="$(_resolve_domain "www.${DOMAIN}")"
    if [[ -n "$server_ip" && -n "$www_ip" && "$www_ip" == "$server_ip" ]]; then
        WWW_RESOLVES=true
    fi

    if [[ -z "$apex_ip" ]]; then
        log_warn "DNS does not resolve for ${DOMAIN}. SSL skipped."
        log_info "Point your DNS to ${server_ip:-this server}, then run: azwp ssl issue"
        state_set "SSL_ISSUED" "false"
        return 0
    fi
    log_sub "${DOMAIN} → ${apex_ip}"

    # --- Case 1: Direct DNS to this server ---
    if [[ -n "$server_ip" && "$apex_ip" == "$server_ip" ]]; then
        log_sub "Direct DNS (no proxy) — using Let's Encrypt"
        if _issue_letsencrypt "$wp_admin_email"; then
            _post_issue_success "letsencrypt"
            return 0
        fi
        log_warn "Let's Encrypt failed. Site is up on HTTP only."
        log_sub  "Common causes: DNS not propagated, port 80 blocked, LE rate limit."
        log_sub  "Retry: azwp ssl issue"
        state_set "SSL_ISSUED" "false"
        return 0
    fi

    # --- Case 2: Cloudflare proxy ---
    if _is_cloudflare_ip "$apex_ip"; then
        log_sub "Cloudflare proxy detected (${apex_ip}) — using self-signed origin cert"
        log_sub "(CF terminates TLS at edge; origin cert is used only for CF↔origin link.)"
        if ! _issue_self_signed >/dev/null; then
            log_warn "Self-signed generation failed."
            state_set "SSL_ISSUED" "false"
            return 0
        fi

        # Verify CF actually accepts our self-signed (fails only in Full Strict)
        log_sub "Verifying Cloudflare can reach origin ..."
        if _verify_cf_accepts_origin; then
            _post_issue_success "self-signed"
            log_sub "Cloudflare Full mode accepted origin cert. Site is live via HTTPS."
            return 0
        fi

        # CF returned 5xx — most likely Full (Strict) rejecting the self-signed
        log_warn "Cloudflare rejected the self-signed origin cert (likely 'Full (Strict)' mode)."
        printf "\n"
        printf "  ${YELLOW}How to fix (pick one):${NC}\n\n"
        printf "  1) ${BOLD}Switch CF SSL mode to 'Full'${NC} (not 'Full (Strict)')\n"
        printf "     CF dashboard → SSL/TLS → Overview → select ${GREEN}Full${NC}\n"
        printf "     Then run: azwp ssl issue\n\n"
        printf "  2) ${BOLD}Install a Cloudflare Origin Certificate${NC} manually\n"
        printf "     CF dashboard → SSL/TLS → Origin Server → Create Certificate\n"
        printf "     Save the cert/key and replace these files:\n"
        printf "       ${AZ_SS_DIR_BASE}/${DOMAIN}/fullchain.pem\n"
        printf "       ${AZ_SS_DIR_BASE}/${DOMAIN}/privkey.pem\n"
        printf "     Then: systemctl reload nginx\n\n"
        printf "  3) ${BOLD}Grey-cloud the DNS record${NC} (remove CF proxy)\n"
        printf "     Direct DNS → this server, then run: azwp ssl issue\n\n"
        state_set "SSL_ISSUED" "self-signed-not-verified"
        return 0
    fi

    # --- Case 3: DNS points somewhere else ---
    log_warn "${DOMAIN} → ${apex_ip} (not this server, not Cloudflare). SSL skipped."
    log_sub  "If intentional (e.g. other CDN), configure cert manually."
    log_sub  "Otherwise point DNS to ${server_ip:-this server} and retry: azwp ssl issue"
    state_set "SSL_ISSUED" "false"
    return 0
}

# ---------------------------------------------------------------------------
# Auto-renewal setup (for the LE path; self-signed needs no renewal)
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
