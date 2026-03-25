#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Ensure stdin is from terminal (needed when piped via curl | bash)
# Must happen BEFORE set -e to allow graceful failure
# ---------------------------------------------------------------------------
if [[ ! -t 0 ]]; then
    exec 0</dev/tty 2>/dev/null || true
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AZ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export AZ_DIR

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$AZ_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$AZ_DIR/lib/detect.sh"
# shellcheck source=lib/tuning.sh
source "$AZ_DIR/lib/tuning.sh"

# Phase 2+ libraries — conditional sourcing
[[ -f "$AZ_DIR/lib/nginx.sh" ]]     && source "$AZ_DIR/lib/nginx.sh"
[[ -f "$AZ_DIR/lib/php.sh" ]]       && source "$AZ_DIR/lib/php.sh"
[[ -f "$AZ_DIR/lib/mariadb.sh" ]]   && source "$AZ_DIR/lib/mariadb.sh"
[[ -f "$AZ_DIR/lib/redis.sh" ]]     && source "$AZ_DIR/lib/redis.sh"
[[ -f "$AZ_DIR/lib/wordpress.sh" ]] && source "$AZ_DIR/lib/wordpress.sh"
[[ -f "$AZ_DIR/lib/ssl.sh" ]]       && source "$AZ_DIR/lib/ssl.sh"
[[ -f "$AZ_DIR/lib/firewall.sh" ]]  && source "$AZ_DIR/lib/firewall.sh"
[[ -f "$AZ_DIR/lib/security.sh" ]]  && source "$AZ_DIR/lib/security.sh"
[[ -f "$AZ_DIR/lib/cron.sh" ]]      && source "$AZ_DIR/lib/cron.sh"

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
    local ver="${AZ_VERSION:-0.0.0}"
    printf "\n"
    printf "===================================================\n"
    printf "       az-wp-single Installer v%s\n" "$ver"
    printf "===================================================\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Configuration prompts
# ---------------------------------------------------------------------------
prompt_config() {
    local existing_domain
    existing_domain="$(state_get DOMAIN 2>/dev/null)" || true

    if [[ -n "$existing_domain" ]]; then
        log_info "Resuming installation for ${existing_domain}..."
        DOMAIN="$(state_get DOMAIN)"
        PHP_VERSION="$(state_get PHP_VERSION)"
        WP_ADMIN_USER="$(state_get WP_ADMIN_USER)"
        WP_ADMIN_EMAIL="$(state_get WP_ADMIN_EMAIL)"
        WP_ADMIN_PASS="$(state_get WP_ADMIN_PASS)"
        DB_NAME="$(state_get DB_NAME)"
        DB_USER="$(state_get DB_USER)"
        DB_PASS="$(state_get DB_PASS)"
        SITE_USER="$(state_get SITE_USER)"
        WEB_ROOT="$(state_get WEB_ROOT)"
        CACHE_PATH="$(state_get CACHE_PATH)"
        REDIS_SOCK="$(state_get REDIS_SOCK)"
        return 0
    fi

    # --- Domain ---
    local input_domain=""
    while [[ -z "$input_domain" ]]; do
        printf "${BOLD}Domain name${NC} (e.g. example.com): "
        read -r input_domain
        # Basic format validation
        if [[ ! "$input_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            log_warn "Invalid domain format. Try again."
            input_domain=""
        fi
    done
    DOMAIN="$input_domain"

    # --- PHP version (latest by default) ---
    PHP_VERSION="8.5"

    # --- WP admin user ---
    printf "${BOLD}WP admin username${NC} (default: admin): "
    read -r WP_ADMIN_USER
    WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"

    # --- WP admin email ---
    local input_email=""
    while [[ -z "$input_email" ]]; do
        printf "${BOLD}WP admin email${NC}: "
        read -r input_email
        if [[ -z "$input_email" ]]; then
            log_warn "Email cannot be empty."
        fi
    done
    WP_ADMIN_EMAIL="$input_email"

    # --- Generate derived values ---
    # Site user: domain slug (replace dots/hyphens with underscores, truncate)
    SITE_USER="$(printf '%s' "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-32)"

    WEB_ROOT="/home/${SITE_USER}/${DOMAIN}"
    CACHE_PATH="/home/${SITE_USER}/cache/fastcgi"
    REDIS_SOCK="/run/redis/redis-server.sock"

    DB_NAME="wp_$(printf '%s' "$SITE_USER" | cut -c1-12)"
    DB_USER="$(printf '%s' "$DB_NAME" | cut -c1-16)"
    DB_PASS="$(generate_password 24)"
    WP_ADMIN_PASS="$(generate_password 20)"

    # --- Save all to state ---
    state_set "DOMAIN" "$DOMAIN"
    state_set "PHP_VERSION" "$PHP_VERSION"
    state_set "WP_ADMIN_USER" "$WP_ADMIN_USER"
    state_set "WP_ADMIN_EMAIL" "$WP_ADMIN_EMAIL"
    state_set "WP_ADMIN_PASS" "$WP_ADMIN_PASS"
    state_set "DB_NAME" "$DB_NAME"
    state_set "DB_USER" "$DB_USER"
    state_set "DB_PASS" "$DB_PASS"
    state_set "SITE_USER" "$SITE_USER"
    state_set "WEB_ROOT" "$WEB_ROOT"
    state_set "CACHE_PATH" "$CACHE_PATH"
    state_set "REDIS_SOCK" "$REDIS_SOCK"

    log_success "Configuration saved."
}

# ---------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------
run_step() {
    local num="$1"
    local total="$2"
    local description="$3"
    local func_name="$4"

    # Derive step name: strip "step_" prefix
    local step_name="${func_name#step_}"

    if step_done "$step_name"; then
        log_step "$num" "$total" "$description" "SKIP"
        return 0
    fi

    local start_ts
    start_ts="$(date +%s)"

    "$func_name"

    local end_ts
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))

    log_step "$num" "$total" "$description" "OK" "$elapsed"
    step_mark "$step_name"
}

# ---------------------------------------------------------------------------
# Step 1: System preparation
# ---------------------------------------------------------------------------
step_system_prep() {
    # Timezone
    log_sub "Setting timezone to UTC..."
    timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    # Locale
    log_sub "Configuring locale (en_US.UTF-8)..."
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        locale-gen en_US.UTF-8 > /dev/null 2>&1 || true
    fi
    update-locale LANG=en_US.UTF-8 > /dev/null 2>&1 || true

    # System update — show progress, this can take 1-3 min on fresh VPS
    log_sub "Updating package lists..."
    apt-get update -qq 2>&1 | tail -1 || true
    log_sub "Upgrading system packages (this may take a few minutes)..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q 2>&1 | grep -E "^(Get|Fetched|Reading|Unpacking|Setting up|[0-9]+ upgraded)" | tail -5 || true

    # Essential packages
    log_sub "Installing base packages (curl, git, htop, etc.)..."
    NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        curl wget gnupg software-properties-common unzip git bc \
        htop ncdu logrotate apt-transport-https ca-certificates lsb-release \
        2>&1 | grep -E "^(Setting up|[0-9]+ newly)" | tail -3 || true

    # Swap
    if ! swapon --show | grep -q '/'; then
        local swap_mb="${TUNE_SWAP_SIZE:-1024}"
        log_sub "Creating ${swap_mb}MB swap..."
        fallocate -l "${swap_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile
        if ! grep -q '/swapfile' /etc/fstab; then
            printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
        fi
    else
        log_sub "Swap already exists, skipping."
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Create site user
# ---------------------------------------------------------------------------
step_create_user() {
    if id "$SITE_USER" &>/dev/null; then
        log_info "User '$SITE_USER' already exists."
    else
        useradd --create-home --shell /bin/bash "$SITE_USER"
        log_info "Created user: $SITE_USER"
    fi

    # Create web root
    mkdir -p "$WEB_ROOT"
    chown "$SITE_USER":"$SITE_USER" "$WEB_ROOT"

    # Create cache dir
    mkdir -p "$CACHE_PATH"
    chown "$SITE_USER":"$SITE_USER" "$CACHE_PATH"

    # Add www-data to site user group
    usermod -aG "$SITE_USER" www-data 2>/dev/null || true

    log_info "Directories ready: $WEB_ROOT, $CACHE_PATH"
}

# ---------------------------------------------------------------------------
# Step 3: Nginx + FastCGI Cache (cache zone must exist before site config)
# ---------------------------------------------------------------------------
step_nginx() {
    install_nginx
    configure_nginx
    configure_fastcgi_cache
    configure_site
    test_nginx || die "Nginx config test failed"
    service_restart nginx
}

# ---------------------------------------------------------------------------
# Step 5: PHP-FPM
# ---------------------------------------------------------------------------
step_php() {
    install_php
    configure_php_ini
    configure_opcache
    configure_fpm_pools
    test_php_fpm || die "PHP-FPM config test failed"
    service_restart "php${PHP_VERSION}-fpm"
}

# ---------------------------------------------------------------------------
# Step 6: MariaDB
# ---------------------------------------------------------------------------
step_mariadb() {
    install_mariadb
    secure_mariadb
    configure_mariadb
    service_restart mariadb
    create_database
}

# ---------------------------------------------------------------------------
# Step 7: Redis
# ---------------------------------------------------------------------------
step_redis() {
    install_redis
    configure_redis
    service_restart redis-server
    test_redis || log_warn "Redis test failed — check config"
}

# ---------------------------------------------------------------------------
# Step 8: WordPress
# ---------------------------------------------------------------------------
step_wordpress() {
    install_wpcli
    install_wordpress
    configure_wp_extras
    install_redis_plugin
    set_wp_permissions
    setup_wp_cron
    setup_logrotate
}

# ---------------------------------------------------------------------------
# Step 9: SSL
# ---------------------------------------------------------------------------
step_ssl() {
    install_certbot
    issue_certificate
    setup_ssl_renewal
}

# ---------------------------------------------------------------------------
# Step 10: Security
# ---------------------------------------------------------------------------
step_security() {
    setup_ufw
    setup_fail2ban
    harden_all
}

# ---------------------------------------------------------------------------
# CLI menu symlink
# ---------------------------------------------------------------------------
install_cli_menu() {
    if [[ -f "$SCRIPT_DIR/menu.sh" ]]; then
        ln -sf "$SCRIPT_DIR/menu.sh" /usr/local/bin/az-wp
        chmod +x "$SCRIPT_DIR/menu.sh"
        log_info "CLI menu installed: az-wp"
    else
        log_warn "menu.sh not found — CLI menu not installed."
    fi
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
print_summary() {
    local start_time="$1"
    local end_time
    end_time="$(date +%s)"
    local total_elapsed=$(( end_time - start_time ))
    local minutes=$(( total_elapsed / 60 ))
    local seconds=$(( total_elapsed % 60 ))

    printf "\n"
    printf "${GREEN}===================================================\n"
    printf "  Installation Complete!  (%dm %ds)\n" "$minutes" "$seconds"
    printf "===================================================${NC}\n"
    printf "\n"
    printf "  ${BOLD}Website:${NC}    https://%s\n" "$DOMAIN"
    printf "  ${BOLD}WP Admin:${NC}   https://%s/wp-admin\n" "$DOMAIN"
    printf "  ${BOLD}Username:${NC}   %s\n" "$WP_ADMIN_USER"
    printf "  ${BOLD}Password:${NC}   %s\n" "$WP_ADMIN_PASS"
    printf "\n"
    printf "  ${BOLD}DB Name:${NC}    %s\n" "$DB_NAME"
    printf "  ${BOLD}DB User:${NC}    %s\n" "$DB_USER"
    printf "  ${BOLD}DB Pass:${NC}    %s\n" "$DB_PASS"
    printf "\n"
    printf "  ${DIM}Manage: az-wp${NC}\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    az_init
    require_root
    print_banner

    printf "${BOLD}Pre-flight checks:${NC}\n"
    preflight_checks || die "Pre-flight checks failed. Fix the issues above and retry."

    detect_hardware
    detect_ip

    printf "\n"
    prompt_config

    calculate_tune
    print_tune_summary

    confirm "Press ENTER to start or Ctrl+C to abort" || die "Aborted by user."

    local start_time
    start_time="$(date +%s)"

    printf "\n"
    run_step 1 9 "System preparation"           step_system_prep
    run_step 2 9 "Creating site user"            step_create_user
    run_step 3 9 "Installing Nginx + Cache"      step_nginx
    run_step 4 9 "Installing PHP ${PHP_VERSION}" step_php
    run_step 5 9 "Installing MariaDB"            step_mariadb
    run_step 6 9 "Installing Redis"              step_redis
    run_step 7 9 "Installing WordPress"          step_wordpress
    run_step 8 9 "Issuing SSL certificate"       step_ssl
    run_step 9 9 "Security hardening"            step_security

    install_cli_menu
    print_summary "$start_time"
}

main "$@"
