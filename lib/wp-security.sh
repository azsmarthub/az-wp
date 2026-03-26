#!/usr/bin/env bash
# wp-security.sh — WordPress security scanning (checksum + malware + alerts)
[[ -n "${_AZ_WP_SECURITY_LOADED:-}" ]] && return 0
_AZ_WP_SECURITY_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
AZ_SECURITY_LOG_DIR="/var/log/az-wp/security"
AZ_SECURITY_SCRIPT="/usr/local/bin/az-wp-security-scan"

# ---------------------------------------------------------------------------
# Install security tools
# ---------------------------------------------------------------------------
install_security_tools() {
    log_sub "Installing security scan tools..."

    # Install pip3 + Wordfence CLI (all optional — won't crash if fail)
    log_sub "Installing Wordfence CLI (optional)..."
    NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip python3-venv > /dev/null 2>&1 || true
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --break-system-packages wordfence > /dev/null 2>&1 || \
            pip3 install wordfence > /dev/null 2>&1 || \
            log_warn "Wordfence CLI install failed (optional — scan will use checksums only)"
        # Accept Wordfence free license non-interactively
        if command -v wordfence >/dev/null 2>&1; then
            wordfence configure --default --accept-terms > /dev/null 2>&1 || true
            log_sub "Wordfence CLI configured (free license)"
        fi
    else
        log_warn "pip3 not available — Wordfence CLI skipped"
    fi

    # Install wp-cli doctor command (optional)
    log_sub "Installing WP-CLI doctor..."
    sudo -u "$SITE_USER" wp package install wp-cli/doctor-command --path="$WEB_ROOT" > /dev/null 2>&1 || true

    # Install mail utilities (optional)
    log_sub "Installing mail tools (email alerts)..."
    NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp msmtp-mta mailutils > /dev/null 2>&1 || true

    # Create log directory
    mkdir -p "$AZ_SECURITY_LOG_DIR"
    chown root:root "$AZ_SECURITY_LOG_DIR"
    chmod 750 "$AZ_SECURITY_LOG_DIR"

    log_sub "Security tools installed."
}

# ---------------------------------------------------------------------------
# Create the scan script (called by cron)
# ---------------------------------------------------------------------------
create_scan_script() {
    local site_user="${1:-$SITE_USER}"
    local web_root="${2:-$WEB_ROOT}"
    local domain="${3:-$DOMAIN}"

    cat > "$AZ_SECURITY_SCRIPT" <<'SCANEOF'
#!/usr/bin/env bash
# az-wp Security Scanner — runs via cron
# Tier 1: WP core + plugin checksum (daily, <5s)
# Tier 2: WP doctor health check (weekly, <10s)
# Tier 3: Wordfence malware scan (weekly, 1-5min)

set -uo pipefail

SCANEOF

    # Append with variable expansion
    cat >> "$AZ_SECURITY_SCRIPT" <<SCANVARS
SITE_USER="${site_user}"
WEB_ROOT="${web_root}"
DOMAIN="${domain}"
LOG_DIR="${AZ_SECURITY_LOG_DIR}"
SCANVARS

    cat >> "$AZ_SECURITY_SCRIPT" <<'SCANEOF2'
DATE=$(date '+%Y-%m-%d')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$LOG_DIR/scan-${DATE}.log"
ALERT_FILE="$LOG_DIR/.last-alert"
ISSUES_FOUND=0
REPORT=""

log() { printf "[%s] %s\n" "$TIMESTAMP" "$1" >> "$LOG_FILE"; }
alert() { ISSUES_FOUND=$((ISSUES_FOUND + 1)); REPORT="${REPORT}\n⚠ $1"; log "ALERT: $1"; }

mkdir -p "$LOG_DIR"

# Get alert email: custom config > WP admin email
ADMIN_EMAIL=""
if [[ -f /etc/az-wp/config ]]; then
    ADMIN_EMAIL=$(grep "^SECURITY_ALERT_EMAIL=" /etc/az-wp/config 2>/dev/null | cut -d= -f2 | tr -d '[:space:]') || true
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
    ADMIN_EMAIL=$(sudo -u "$SITE_USER" wp option get admin_email --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated | tr -d '[:space:]') || ADMIN_EMAIL=""
fi

log "=== Security Scan Started ==="
log "Domain: $DOMAIN"
log "Mode: $1"

case "${1:-daily}" in
    daily)
        # --- Tier 1: Core checksum verification ---
        log "--- Tier 1: Core Checksum ---"
        core_result=$(sudo -u "$SITE_USER" wp core verify-checksums --path="$WEB_ROOT" 2>&1 | grep -v Deprecated)
        if echo "$core_result" | grep -qi "success"; then
            log "Core files: OK (no modifications)"
        else
            alert "WordPress core files MODIFIED!\n$core_result"
        fi

        # --- Tier 1: Plugin checksum verification ---
        log "--- Tier 1: Plugin Checksums ---"
        plugin_result=$(sudo -u "$SITE_USER" wp plugin verify-checksums --all --path="$WEB_ROOT" 2>&1 | grep -v Deprecated)
        if echo "$plugin_result" | grep -qi "success\|no plugins"; then
            log "Plugin files: OK"
        elif echo "$plugin_result" | grep -qi "could not verify\|error"; then
            # Some plugins can't be verified (custom/premium) — warning not alert
            log "Plugin check: some plugins not verifiable (custom/premium)"
        else
            alert "Plugin files MODIFIED!\n$plugin_result"
        fi

        # --- Quick file permission check ---
        log "--- File Permissions ---"
        wp_config_perm=$(stat -c '%a' "$WEB_ROOT/wp-config.php" 2>/dev/null)
        if [[ "$wp_config_perm" != "640" && "$wp_config_perm" != "600" ]]; then
            alert "wp-config.php permissions: $wp_config_perm (should be 640)"
        else
            log "wp-config.php permissions: $wp_config_perm (OK)"
        fi

        # --- Check for suspicious PHP files in uploads ---
        log "--- Uploads PHP Check ---"
        php_in_uploads=$(find "$WEB_ROOT/wp-content/uploads" -name "*.php" -type f 2>/dev/null | head -5)
        if [[ -n "$php_in_uploads" ]]; then
            alert "PHP files found in uploads directory!\n$php_in_uploads"
        else
            log "Uploads: no PHP files (OK)"
        fi

        # --- Check for recently modified files (last 24h) ---
        log "--- Recent File Changes ---"
        recent_changes=$(find "$WEB_ROOT/wp-content" -name "*.php" -newer "$LOG_DIR/.scan-marker" -type f 2>/dev/null | grep -v '/cache/' | head -10)
        if [[ -n "$recent_changes" ]]; then
            log "Recently modified PHP files:\n$recent_changes"
        fi
        touch "$LOG_DIR/.scan-marker"
        ;;

    weekly)
        # Run daily checks first
        "$0" daily

        # --- Tier 2: WP Doctor health check ---
        log "--- Tier 2: WP Doctor ---"
        if sudo -u "$SITE_USER" wp doctor check --all --path="$WEB_ROOT" 2>&1 | grep -v Deprecated > "$LOG_DIR/doctor-${DATE}.log" 2>&1; then
            log "WP Doctor: all checks passed"
        else
            doctor_issues=$(grep -c "^Error\|Warning\|error" "$LOG_DIR/doctor-${DATE}.log" 2>/dev/null | tr -d '[:space:]')
            doctor_issues="${doctor_issues:-0}"
            if [[ "$doctor_issues" -gt 0 ]]; then
                alert "WP Doctor found $doctor_issues issues. See: $LOG_DIR/doctor-${DATE}.log"
            fi
        fi

        # --- Tier 2: Check WordPress/plugin updates ---
        log "--- Update Check ---"
        core_update=$(sudo -u "$SITE_USER" wp core check-update --path="$WEB_ROOT" 2>&1 | grep -v Deprecated | grep -c "version" || echo "0")
        plugin_updates=$(sudo -u "$SITE_USER" wp plugin list --update=available --path="$WEB_ROOT" 2>&1 | grep -v Deprecated | grep -c "available" || echo "0")
        if [[ "$core_update" -gt 0 ]]; then
            log "WordPress core update available"
        fi
        if [[ "$plugin_updates" -gt 0 ]]; then
            log "$plugin_updates plugin updates available"
        fi

        # --- Tier 3: Wordfence malware scan ---
        log "--- Tier 3: Wordfence Malware Scan ---"
        if command -v wordfence >/dev/null 2>&1; then
            # Check if Wordfence is configured (requires license acceptance)
            # Ensure configured, then scan
            wordfence configure --default --accept-terms >/dev/null 2>&1 || true
            if wordfence malware-scan "$WEB_ROOT" \
                    --output-path "$LOG_DIR/wordfence-${DATE}.txt" \
                    --accept-terms 2>> "$LOG_FILE"; then
                malware_count="$(wc -l < "$LOG_DIR/wordfence-${DATE}.txt" 2>/dev/null | tr -d '[:space:]')"
                malware_count="${malware_count:-0}"
                if [[ "$malware_count" -gt 0 ]]; then
                    alert "Wordfence found $malware_count potential threats! See: $LOG_DIR/wordfence-${DATE}.txt"
                else
                    log "Wordfence: no malware found"
                fi
            else
                log "Wordfence scan failed or not configured (run: wordfence configure)"
            fi
        else
            log "Wordfence CLI not installed (skipped)"
        fi
        ;;
esac

log "=== Scan Complete: $ISSUES_FOUND issues found ==="

# --- Send email alert if issues found ---
if [[ "$ISSUES_FOUND" -gt 0 && -n "$ADMIN_EMAIL" ]]; then
    # Rate limit: max 1 alert email per 6 hours
    if [[ -f "$ALERT_FILE" ]]; then
        last_alert=$(cat "$ALERT_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        if [[ $((now - last_alert)) -lt 21600 ]]; then
            log "Alert email skipped (rate limit: 1 per 6h)"
            exit 0
        fi
    fi

    SUBJECT="[az-wp] Security Alert: $DOMAIN — $ISSUES_FOUND issues"
    BODY="Security scan found $ISSUES_FOUND issue(s) on $DOMAIN at $TIMESTAMP\n\n${REPORT}\n\nFull log: $LOG_FILE\n\n---\naz-wp Security Scanner"

    if command -v mail >/dev/null 2>&1; then
        printf "$BODY" | mail -s "$SUBJECT" "$ADMIN_EMAIL" 2>/dev/null && \
            log "Alert email sent to $ADMIN_EMAIL"
    elif command -v sendmail >/dev/null 2>&1; then
        printf "Subject: $SUBJECT\nTo: $ADMIN_EMAIL\n\n$BODY" | sendmail "$ADMIN_EMAIL" 2>/dev/null && \
            log "Alert email sent to $ADMIN_EMAIL"
    else
        log "No mail command available — alert logged only"
    fi

    date +%s > "$ALERT_FILE"
fi

# Cleanup old logs (keep 30 days)
find "$LOG_DIR" -name "*.log" -o -name "*.txt" -type f -mtime +30 -delete 2>/dev/null || true

exit $ISSUES_FOUND
SCANEOF2

    chmod +x "$AZ_SECURITY_SCRIPT"
    log_sub "Security scan script created: $AZ_SECURITY_SCRIPT"
}

# ---------------------------------------------------------------------------
# Setup security crons
# ---------------------------------------------------------------------------
setup_security_crons() {
    # Daily scan: core + plugin checksums + suspicious files (2:30 AM)
    cat > /etc/cron.d/az-wp-security-daily <<EOF
# az-wp: daily security scan (core + plugin checksums)
30 2 * * * root $AZ_SECURITY_SCRIPT daily > /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/az-wp-security-daily

    # Weekly scan: full scan + wordfence malware (Sunday 4:00 AM)
    cat > /etc/cron.d/az-wp-security-weekly <<EOF
# az-wp: weekly security scan (checksums + doctor + wordfence)
0 4 * * 0 root $AZ_SECURITY_SCRIPT weekly > /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/az-wp-security-weekly

    log_sub "Security crons configured (daily 2:30am, weekly Sunday 4am)."
}

# ---------------------------------------------------------------------------
# Run scan manually
# ---------------------------------------------------------------------------
run_security_scan() {
    local mode="${1:-daily}"

    if [[ ! -x "$AZ_SECURITY_SCRIPT" ]]; then
        log_error "Security scan script not found. Run install first."
        return 1
    fi

    log_info "Running $mode security scan..."
    "$AZ_SECURITY_SCRIPT" "$mode" 2>&1

    local exit_code=$?
    local log_file="$AZ_SECURITY_LOG_DIR/scan-$(date '+%Y-%m-%d').log"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Scan complete: no issues found."
    else
        log_warn "Scan found $exit_code issue(s)."
    fi

    if [[ -f "$log_file" ]]; then
        printf "\n  ${BOLD}Scan Log:${NC}\n"
        tail -30 "$log_file" | sed 's/^/  /'
    fi
}
