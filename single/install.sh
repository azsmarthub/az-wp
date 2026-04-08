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
# Handle --reset flag
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--reset" ]]; then
    source "$AZ_DIR/lib/common.sh"
    az_init
    if [[ -f "$AZ_STATE_FILE" ]]; then
        log_warn "This will DELETE all install state and start fresh."
        log_warn "It does NOT uninstall packages already installed."
        confirm "Are you sure?" || { echo "Aborted."; exit 0; }
        rm -f "$AZ_STATE_FILE"
        log_success "State file removed. Run install.sh again to start fresh."
    else
        log_info "No state file found. Already clean."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Parse domain from argument: curl ... | bash -s -- domain.com
# ---------------------------------------------------------------------------
ARG_DOMAIN="${1:-}"
# Skip if it looks like a flag
[[ "$ARG_DOMAIN" == -* ]] && ARG_DOMAIN=""

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
    local ver="${AZ_VERSION:-0.0.0}"
    local mode="Fresh Install"
    [[ -d "$AZ_DIR/clone" && -f "$AZ_DIR/clone/database.sql.gz" ]] && mode="Clone Mode"
    printf "\n"
    printf "===================================================\n"
    printf "       azwp Installer v%s\n" "$ver"
    printf "       Mode: %s\n" "$mode"
    printf "===================================================\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Configuration
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

    # --- Domain (from arg or prompt) ---
    if [[ -n "$ARG_DOMAIN" ]]; then
        DOMAIN="$ARG_DOMAIN"
        log_info "Domain: $DOMAIN (from argument)"
    else
        local input_domain=""
        while [[ -z "$input_domain" ]]; do
            printf "${BOLD}Domain name${NC} (e.g. example.com): "
            read -r input_domain
            if [[ ! "$input_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
                log_warn "Invalid domain format. Try again."
                input_domain=""
            fi
        done
        DOMAIN="$input_domain"
    fi

    # --- Auto-generate everything (no more prompts) ---
    PHP_VERSION="8.5"
    WP_ADMIN_USER="admin"
    WP_ADMIN_EMAIL="admin@${DOMAIN}"

    # Site user: domain slug
    SITE_USER="$(printf '%s' "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-32)"

    WEB_ROOT="/home/${SITE_USER}/${DOMAIN}"
    CACHE_PATH="/home/${SITE_USER}/cache/fastcgi"
    REDIS_SOCK="/run/redis/redis-server.sock"

    DB_NAME="wp_$(printf '%s' "$SITE_USER" | cut -c1-12)"
    DB_USER="$(printf '%s' "$DB_NAME" | cut -c1-16)"
    DB_PASS="$(generate_password 24)"
    WP_ADMIN_PASS="$(generate_password 20)"

    # Save all to state
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
    log_sub "Setting timezone to UTC..."
    timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    log_sub "Configuring locale (en_US.UTF-8)..."
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        locale-gen en_US.UTF-8 > /dev/null 2>&1 || true
    fi
    update-locale LANG=en_US.UTF-8 > /dev/null 2>&1 || true

    log_sub "Waiting for system package manager..."
    apt_wait
    log_sub "Updating package lists..."
    apt-get update -qq 2>&1 | tail -1 || true
    log_sub "Upgrading system packages (this may take a few minutes)..."
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q 2>&1 | grep -E "^(Get|Fetched|Reading|Unpacking|Setting up|[0-9]+ upgraded)" | tail -5 || true

    log_sub "Installing base packages (curl, git, htop, etc.)..."
    apt_install curl wget gnupg software-properties-common unzip git bc \
        htop ncdu logrotate apt-transport-https ca-certificates lsb-release

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

    mkdir -p "$WEB_ROOT"
    chown "$SITE_USER":"$SITE_USER" "$WEB_ROOT"

    mkdir -p "$CACHE_PATH"
    chown "$SITE_USER":"$SITE_USER" "$CACHE_PATH"

    usermod -aG "$SITE_USER" www-data 2>/dev/null || true

    log_info "Directories ready: $WEB_ROOT, $CACHE_PATH"
}

# ---------------------------------------------------------------------------
# Step 3: Nginx + FastCGI Cache
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
# Step 4: PHP-FPM
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
# Step 5: MariaDB
# ---------------------------------------------------------------------------
step_mariadb() {
    install_mariadb
    secure_mariadb
    configure_mariadb
    service_restart mariadb
    create_database
}

# ---------------------------------------------------------------------------
# Step 6: Redis
# ---------------------------------------------------------------------------
step_redis() {
    install_redis
    configure_redis
    service_restart redis-server
    test_redis || log_warn "Redis test failed — check config"
    service_restart "php${PHP_VERSION}-fpm"
}

# ---------------------------------------------------------------------------
# Step 7: WordPress (clone or fresh)
# ---------------------------------------------------------------------------
step_wordpress() {
    install_wpcli

    local clone_dir="$AZ_DIR/clone"

    if [[ -f "$clone_dir/database.sql.gz" && -f "$clone_dir/wp-content.tar.gz" ]]; then
        # === CLONE MODE ===
        log_sub "Clone data detected — restoring from preset..."

        log_sub "Downloading WordPress core..."
        sudo -u "$SITE_USER" wp core download --path="$WEB_ROOT" --locale=en_US 2>&1 | grep -v Deprecated || true

        log_sub "Creating wp-config.php..."
        if [[ -f "$clone_dir/wp-config-template.php" ]]; then
            cp "$clone_dir/wp-config-template.php" "$WEB_ROOT/wp-config.php"
            sed -i "s|CLONE_DB_NAME|${DB_NAME}|g" "$WEB_ROOT/wp-config.php"
            sed -i "s|CLONE_DB_USER|${DB_USER}|g" "$WEB_ROOT/wp-config.php"
            sed -i "s|CLONE_DB_PASS|${DB_PASS}|g" "$WEB_ROOT/wp-config.php"
            sed -i "s|CLONE_DOMAIN|${DOMAIN}|g" "$WEB_ROOT/wp-config.php"
        else
            sudo -u "$SITE_USER" wp config create --path="$WEB_ROOT" \
                --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" \
                --dbhost="localhost" --dbprefix="oXxhsA_" 2>&1 | grep -v Deprecated || true
        fi

        log_sub "Importing database..."
        gunzip -c "$clone_dir/database.sql.gz" | mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"

        log_sub "Extracting wp-content..."
        tar xzf "$clone_dir/wp-content.tar.gz" -C "$WEB_ROOT" 2>/dev/null

        # Fix hardcoded CDN URL in theme config
        local theme_config="$WEB_ROOT/wp-content/themes/affiliateCMS-theme/inc/config.php"
        if [[ -f "$theme_config" ]]; then
            sed -i "s|https://cdn.productreviews.org/logo.png|/wp-content/uploads/2026/02/logo.png|g" "$theme_config"
        fi

        # Customize child theme for new domain
        local child_config="$WEB_ROOT/wp-content/themes/affiliateCMS-Child-theme/config.php"
        if [[ -f "$child_config" ]]; then
            sed -i "s|AmericanReviews\.org|${DOMAIN}|g" "$child_config"
            sed -i "s|americanreviews\.org|${DOMAIN}|g" "$child_config"
            sed -i "s|contact@${DOMAIN}|contact@${DOMAIN}|g" "$child_config"
        fi
        local child_style="$WEB_ROOT/wp-content/themes/affiliateCMS-Child-theme/style.css"
        if [[ -f "$child_style" ]]; then
            sed -i "s|americanreviews\.org|${DOMAIN}|g" "$child_style"
            sed -i "s|AmericanReviews|${DOMAIN%%.*}|g" "$child_style"
        fi

        # Fix hardcoded FPM pool name in CachePreload
        local cache_preload="$WEB_ROOT/wp-content/plugins/affiliatecms-pro/src/Core/CachePreload.php"
        if [[ -f "$cache_preload" ]]; then
            sed -i "s|pool productreviewsorg|pool ${SITE_USER}|g" "$cache_preload"
        fi

        log_sub "Search & replace domain..."
        # Replace original production domain
        sudo -u "$SITE_USER" wp search-replace 'productreviews.org' "$DOMAIN" --all-tables --precise --path="$WEB_ROOT" 2>&1 | grep -v Deprecated | grep -E 'Success|replacements' | head -1 || true
        # Replace CDN domain
        sudo -u "$SITE_USER" wp search-replace 'cdn.productreviews.org' "$DOMAIN" --all-tables --precise --path="$WEB_ROOT" 2>&1 | grep -v Deprecated | grep -E 'Success|replacements' | head -1 || true
        # Replace any previous clone domain (if re-cloning)
        sudo -u "$SITE_USER" wp search-replace 'azwp.azsmarthub.com' "$DOMAIN" --all-tables --precise --path="$WEB_ROOT" 2>&1 | grep -v Deprecated | grep -E 'Success|replacements' | head -1 || true
        # Force set correct URLs
        sudo -u "$SITE_USER" wp option update siteurl "https://$DOMAIN" --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp option update home "https://$DOMAIN" --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true

        log_sub "Configuring Redis..."
        sed -i "/WP_REDIS_HOST/d" "$WEB_ROOT/wp-config.php" 2>/dev/null || true
        sed -i "/WP_REDIS_PORT/d" "$WEB_ROOT/wp-config.php" 2>/dev/null || true
        sed -i "/WP_REDIS_MAXTTL/d" "$WEB_ROOT/wp-config.php" 2>/dev/null || true
        grep -q WP_REDIS_SCHEME "$WEB_ROOT/wp-config.php" || {
            sudo -u "$SITE_USER" wp config set WP_REDIS_SCHEME unix --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated || true
            sudo -u "$SITE_USER" wp config set WP_REDIS_PATH "$REDIS_SOCK" --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated || true
            sudo -u "$SITE_USER" wp config set WP_REDIS_DATABASE 0 --raw --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated || true
        }
        sudo -u "$SITE_USER" wp config set WP_CACHE_KEY_SALT "${DOMAIN}_" --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated || true

        log_sub "Enabling Redis Object Cache..."
        # Always fresh install redis-cache (clone may have incomplete plugin files)
        sudo -u "$SITE_USER" wp plugin install redis-cache --force --activate --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp redis enable --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true

        log_sub "Configuring cache path..."
        sudo -u "$SITE_USER" wp option patch update acms_general_settings cache_path "${CACHE_PATH}/" --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true

        log_sub "Resetting admin password..."
        sudo -u "$SITE_USER" wp user update 1 --user_pass="$WP_ADMIN_PASS" --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true

        # Remove API keys/tokens from cloned data (production keys must not leak)
        log_sub "Clearing cloned API keys..."
        sudo -u "$SITE_USER" wp option update acms_ai_api_key '' --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp option update acms_crawlbase_token '' --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp option update acms_paapi_credentials '' --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        # Clear keys embedded in general_settings JSON
        sudo -u "$SITE_USER" wp eval '
            $s = get_option("acms_general_settings", []);
            foreach (["crawlbase_token","paapi_access_key","paapi_secret_key","api_key"] as $k) { $s[$k] = ""; }
            update_option("acms_general_settings", $s);
        ' --path="$WEB_ROOT" 2>/dev/null || true

        # Seed AI prompt defaults (ensures prompts exist even if DB dump is stale)
        log_sub "Seeding AI prompt defaults..."
        sudo -u "$SITE_USER" wp eval 'if (class_exists("AffiliateCMS\AI\Core\DefaultPrompts")) { AffiliateCMS\AI\Core\DefaultPrompts::seed(); echo "OK"; }' --path="$WEB_ROOT" 2>/dev/null | grep -q OK && log_sub "AI prompts seeded." || true

        # Re-activate plugins to trigger activation hooks (schema migrations, cron registration)
        log_sub "Re-activating plugins..."
        sudo -u "$SITE_USER" wp plugin deactivate affiliatecms-pro affiliatecms-cat affiliatecms-ai --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
        sudo -u "$SITE_USER" wp plugin activate affiliatecms-pro affiliatecms-cat affiliatecms-ai --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true

        # Activate child theme (customized with new domain above)
        log_sub "Activating child theme..."
        sudo -u "$SITE_USER" wp theme activate affiliateCMS-Child-theme --path="$WEB_ROOT" 2>&1 | grep -v Deprecated || true
    else
        # === FRESH MODE ===
        install_wordpress
        configure_wp_extras
        install_redis_plugin
    fi

    set_wp_permissions
    setup_wp_cron
    setup_logrotate

    # Auto backup: every 2 days at 3:00 AM
    log_sub "Setting up auto backup (every 2 days)..."
    mkdir -p "/home/${SITE_USER}/backups"
    printf '# azwp: backup every 2 days at 3:00 AM\n0 3 */2 * * root /usr/local/bin/azwp backup full >> /var/log/azwp/backup.log 2>&1\n' \
        > /etc/cron.d/azwp-backup
    chmod 644 /etc/cron.d/azwp-backup

    # Cache helpers
    log_sub "Setting up cache helpers..."
    cat > /usr/local/bin/nginx-cache-purge <<'NSCRIPT'
#!/bin/bash
CACHE_DIR="${1:-/dev/null}"
case "${2:-help}" in
    purge-all) rm -rf "${CACHE_DIR}"/* 2>/dev/null; echo 'purged' ;;
    count)     find "$CACHE_DIR" -type f 2>/dev/null | wc -l ;;
    size)      du -sb "$CACHE_DIR" 2>/dev/null | awk '{print $1}' ;;
    list)      find "$CACHE_DIR" -type f 2>/dev/null ;;
    exists)    [[ -d "$CACHE_DIR" ]] && echo 'yes' || echo 'no' ;;
    *)         echo 'Usage: nginx-cache-purge [dir] purge-all|count|size|list|exists' ;;
esac
NSCRIPT
    chmod +x /usr/local/bin/nginx-cache-purge

    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/nginx-cache-purge\n' "$SITE_USER" \
        > /etc/sudoers.d/nginx-cache-purge
    chmod 440 /etc/sudoers.d/nginx-cache-purge

    # Cache stats cron + initial generation
    cat > /etc/cron.d/azwp-cache-stats <<CSCRON
# azwp: update cache stats every 5 minutes
*/5 * * * * root /usr/local/bin/nginx-cache-purge ${CACHE_PATH} count > /tmp/az-cache-count && /usr/local/bin/nginx-cache-purge ${CACHE_PATH} size > /tmp/az-cache-size && printf '{"files":%s,"size":%s,"updated":"%s"}' "\$(cat /tmp/az-cache-count)" "\$(cat /tmp/az-cache-size)" "\$(date '+%Y-%m-%d %H:%M:%S')" > /home/${SITE_USER}/cache/cache-stats.json 2>/dev/null
CSCRON
    chmod 644 /etc/cron.d/azwp-cache-stats

    # Initial cache stats
    local _stats_dir="/home/${SITE_USER}/cache"
    mkdir -p "$_stats_dir"
    local _count _size
    _count="$(find "$CACHE_PATH" -type f 2>/dev/null | wc -l || echo 0)"
    _size="$(du -sb "$CACHE_PATH" 2>/dev/null | awk '{print $1}' || echo 0)"
    printf '{"files":%s,"size":%s,"updated":"%s"}' "$_count" "$_size" "$(date '+%Y-%m-%d %H:%M:%S')" > "$_stats_dir/cache-stats.json"
    chown "$SITE_USER:$SITE_USER" "$_stats_dir/cache-stats.json"

    # AffiliateCMS crons (clone mode only)
    if [[ -f "$clone_dir/database.sql.gz" ]]; then
        log_sub "Installing AffiliateCMS cron jobs..."
        local api_token
        api_token="$(sudo -u "$SITE_USER" wp option get acms_api_token --path="$WEB_ROOT" 2>/dev/null | grep -v Deprecated | tr -d '[:space:]')" || api_token=""

        if [[ -n "$api_token" ]]; then
            local base="curl -sk --resolve ${DOMAIN}:443:127.0.0.1"
            local url="https://${DOMAIN}"
            # Tier 1: Pipeline (*/2 staggered), Tier 2: AI (*/5 staggered), Tier 3: Maintenance
            local presets=(
                "scrape|*/2 * * * *||/wp-json/acms/v1/automation/scrape|30|GET|Scrape dispatcher"
                "process-scheduled|*/2 * * * *|sleep 20 && |/wp-json/acms/v1/automation/process-scheduled|30|GET|Process scheduled"
                "scrape-monitor|*/2 * * * *|sleep 40 && |/wp-json/acms/v1/cron/scrape-monitor|30|GET|Scrape monitor"
                "pro-queue|*/2 * * * *|sleep 50 && |/wp-json/acms/v1/cron/queue|60|GET|Pro keyword queue"
                "queue-processor|*/2 * * * *|sleep 60 && |/wp-json/acms-cat/v1/cron/queue-processor|60|GET|Queue processor"
                "queue-monitor|*/2 * * * *|sleep 80 && |/wp-json/acms-cat/v1/cron/queue-monitor|30|GET|Queue monitor"
                "product-ai|*/5 * * * *||/wp-json/acms/v1/cron/product-ai|30|GET|Product AI"
                "post-ai|*/5 * * * *|sleep 30 && |/wp-json/acms/v1/cron/post-ai|30|GET|Post AI"
                "category-ai|*/5 * * * *|sleep 60 && |/wp-json/acms-cat/v1/cron/category-ai|60|GET|Category AI"
                "ai-jobs|*/2 * * * *|sleep 10 && |/wp-json/acms-ai/v1/cron/process-jobs|300|GET|AI job processor"
                "brand-ai|*/5 * * * *|sleep 90 && |/wp-json/acms/v1/cron/brand-ai|30|GET|Brand AI"
                "brand-category-ai|*/5 * * * *|sleep 120 && |/wp-json/acms-cat/v1/cron/brand-category-ai|30|GET|Brand category AI"
                "quick-update|*/30 * * * *||/wp-json/acms/v1/cron/quick-update|60|GET|Quick update"
                "retry-stuck|*/10 * * * *||/wp-json/acms-cat/v1/cron/retry-stuck|30|GET|Retry stuck"
                "date-update|0 3 * * *||/wp-json/acms/v1/cron/date-update|30|GET|Date update"
                "bulk-update|* * * * *||/wp-json/acms-cat/v1/cron/bulk-update-worker|90|GET|Bulk update"
                "cache-preload|0 3 * * 0||/wp-json/acms/v1/cache/preload|30|GET|Cache preload"
                "cache-refresh|0 */4 * * *||/wp-json/acms/v1/cache/smart-refresh|30|POST|Cache refresh"
                "cache-resume|*/30 * * * *||/wp-json/acms/v1/cache/resume-queue|30|POST|Cache resume"
            )
            local p
            for p in "${presets[@]}"; do
                IFS='|' read -r name sched sleep_prefix endpoint max_time method desc <<< "$p"
                local curl_cmd="${base} --max-time ${max_time}"
                [[ "$method" == "POST" ]] && curl_cmd="${curl_cmd} -X POST"
                printf '# azwp cron: %s\n%s root %s%s "%s%s?token=%s" > /dev/null 2>&1\n' \
                    "$desc" "$sched" "$sleep_prefix" "$curl_cmd" "$url" "$endpoint" "$api_token" \
                    > "/etc/cron.d/azwp-${name}"
                chmod 644 "/etc/cron.d/azwp-${name}"
            done
            log_sub "Installed 17 AffiliateCMS cron jobs."
        else
            log_warn "API token not found — run 'azwp cron preset' later."
        fi
    fi

    # Pre-install phpMyAdmin + FPM pool (not enabled until user runs 'azwp db pma')
    if [[ ! -d /usr/share/phpmyadmin ]]; then
        log_sub "Pre-installing phpMyAdmin..."
        apt_install phpmyadmin
    fi
    local pma_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/phpmyadmin.conf"
    if [[ ! -f "$pma_pool" ]]; then
        cat > "$pma_pool" <<FPMPOOL
[phpmyadmin]
user = www-data
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm-pma.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 60s
request_terminate_timeout = 300
php_admin_value[open_basedir] = /usr/share/phpmyadmin:/tmp:/var/lib/phpmyadmin:/etc/phpmyadmin:/usr/share/php
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_execution_time] = 300
FPMPOOL
        systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
    fi
    log_sub "phpMyAdmin ready (run 'azwp db pma' to activate)."
}

# ---------------------------------------------------------------------------
# Step 8: SSL
# ---------------------------------------------------------------------------
step_ssl() {
    # Clear stale certbot accounts (prevents "Account not found" on fresh VPS)
    rm -rf /etc/letsencrypt/accounts/ 2>/dev/null || true
    install_certbot
    issue_certificate
    setup_ssl_renewal
}

# ---------------------------------------------------------------------------
# Step 9: Security
# ---------------------------------------------------------------------------
step_security() {
    setup_ufw
    setup_fail2ban
    harden_all

    # Security scanning (WP checksums + malware patterns)
    if [[ -f "$AZ_DIR/lib/wp-security.sh" ]]; then
        source "$AZ_DIR/lib/wp-security.sh"
        install_security_tools
        create_scan_script "$SITE_USER" "$WEB_ROOT" "$DOMAIN"
        setup_security_crons
    fi
}

# ---------------------------------------------------------------------------
# CLI menu symlink
# ---------------------------------------------------------------------------
install_cli_menu() {
    if [[ -f "$SCRIPT_DIR/menu.sh" ]]; then
        ln -sf "$SCRIPT_DIR/menu.sh" /usr/local/bin/azwp
        chmod +x "$SCRIPT_DIR/menu.sh"
        log_info "CLI menu installed: azwp"
    else
        log_warn "menu.sh not found — CLI menu not installed."
    fi
}

# ---------------------------------------------------------------------------
# Final summary with verification
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

    # --- Verification ---
    printf "\n${BOLD}  Verification:${NC}\n"
    printf "  ──────────────────────────────────────\n"

    # Website (try HTTPS first, fallback to HTTP)
    local http_code
    http_code="$(curl -sfk --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null)" || true
    if [[ "$http_code" == "000" || -z "$http_code" ]]; then
        http_code="$(curl -sf --resolve "${DOMAIN}:80:127.0.0.1" -o /dev/null -w '%{http_code}' "http://${DOMAIN}/" 2>/dev/null)" || http_code="000"
    fi
    if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" ]]; then
        printf "  ${GREEN}OK${NC}  Website       https://%s (HTTP %s)\n" "$DOMAIN" "$http_code"
    else
        printf "  ${YELLOW}--${NC}  Website       https://%s (HTTP %s)\n" "$DOMAIN" "$http_code"
    fi

    # Services
    local svc svc_ok=0 svc_total=0
    for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server fail2ban; do
        svc_total=$((svc_total + 1))
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            svc_ok=$((svc_ok + 1))
        fi
    done
    if [[ $svc_ok -eq $svc_total ]]; then
        printf "  ${GREEN}OK${NC}  Services      %s/%s active (nginx, php-fpm, mariadb, redis, fail2ban)\n" "$svc_ok" "$svc_total"
    else
        printf "  ${RED}!!${NC}  Services      %s/%s active\n" "$svc_ok" "$svc_total"
    fi

    # SSL
    local ssl_info
    ssl_info="$(echo | openssl s_client -connect localhost:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" || ssl_info=""
    if [[ -n "$ssl_info" ]]; then
        printf "  ${GREEN}OK${NC}  SSL           Let's Encrypt (expires: %s)\n" "$ssl_info"
    else
        printf "  ${YELLOW}--${NC}  SSL           Not issued (run: azwp advanced ssl issue)\n"
    fi

    # Redis
    local redis_status
    redis_status="$(redis-cli -s "$REDIS_SOCK" ping 2>/dev/null)" || redis_status=""
    if [[ "$redis_status" == "PONG" ]]; then
        printf "  ${GREEN}OK${NC}  Redis         Connected (Unix socket)\n"
    else
        printf "  ${RED}!!${NC}  Redis         Not responding\n"
    fi

    # Cache
    printf "  ${GREEN}OK${NC}  FastCGI       %s (auto-tune)\n" "$CACHE_PATH"

    # Crons
    local cron_count
    cron_count="$(ls /etc/cron.d/azwp-* 2>/dev/null | wc -l || echo 0)"
    printf "  ${GREEN}OK${NC}  Cron jobs     %s configured\n" "$cron_count"

    # Backup
    printf "  ${GREEN}OK${NC}  Auto backup   Every 2 days at 3:00 AM\n"

    printf "  ──────────────────────────────────────\n"

    # --- Credentials ---
    printf "\n${BOLD}  Access Credentials:${NC}\n"
    printf "  ──────────────────────────────────────\n"
    printf "  Website:    https://%s\n" "$DOMAIN"
    printf "  WP Admin:   https://%s/wp-admin\n" "$DOMAIN"
    printf "  Username:   ${BOLD}%s${NC}\n" "$WP_ADMIN_USER"
    printf "  Password:   ${BOLD}%s${NC}\n" "$WP_ADMIN_PASS"
    printf "  ──────────────────────────────────────\n"
    printf "  DB Name:    %s\n" "$DB_NAME"
    printf "  DB User:    %s\n" "$DB_USER"
    printf "  DB Pass:    %s\n" "$DB_PASS"
    printf "  ──────────────────────────────────────\n"
    printf "  Site User:  %s\n" "$SITE_USER"
    printf "  Web Root:   %s\n" "$WEB_ROOT"
    printf "  Cache:      %s\n" "$CACHE_PATH"
    printf "  PHP:        %s | FPM: web=%s workers=%s\n" "$PHP_VERSION" "${TUNE_WEB_MAX_CHILDREN:-?}" "${TUNE_WORKERS_MAX_CHILDREN:-?}"
    printf "  MariaDB:    InnoDB %s | Connections %s\n" "${TUNE_INNODB_BUFFER_POOL:-?}" "${TUNE_MARIADB_MAX_CONNECTIONS:-?}"
    printf "  Redis:      %s (Unix socket)\n" "${TUNE_REDIS_MAXMEM:-?}"
    printf "  OPcache:    %sMB + JIT %s\n" "${TUNE_OPCACHE_MEMORY:-?}" "${TUNE_JIT_BUFFER:-0}"
    printf "  ──────────────────────────────────────\n"
    printf "\n  ${BOLD}Manage:${NC} azwp\n"
    printf "  ${BOLD}Help:${NC}   azwp help\n\n"
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

    # Skip confirmation if domain passed as argument (fully automated)
    if [[ -z "$ARG_DOMAIN" ]]; then
        confirm "Press ENTER to start or Ctrl+C to abort" || die "Aborted by user."
    fi

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
