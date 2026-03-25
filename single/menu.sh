#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths (follow symlink to real location)
# ---------------------------------------------------------------------------
_SELF="${BASH_SOURCE[0]}"
while [[ -L "$_SELF" ]]; do
    _DIR="$(cd "$(dirname "$_SELF")" && pwd)"
    _SELF="$(readlink "$_SELF")"
    [[ "$_SELF" != /* ]] && _SELF="$_DIR/$_SELF"
done
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
AZ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export AZ_DIR

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
source "$AZ_DIR/lib/common.sh"
az_init

for _lib in detect tuning nginx php mariadb redis wordpress ssl firewall security cron backup; do
    [[ -f "$AZ_DIR/lib/${_lib}.sh" ]] && source "$AZ_DIR/lib/${_lib}.sh"
done

trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Load state
# ---------------------------------------------------------------------------
load_state() {
    [[ ! -f "$AZ_STATE_FILE" ]] && die "az-wp not installed. Run install.sh first."
    DOMAIN="$(state_get DOMAIN)" || die "DOMAIN not found in state."
    PHP_VERSION="$(state_get PHP_VERSION 2>/dev/null)" || PHP_VERSION="8.5"
    SITE_USER="$(state_get SITE_USER 2>/dev/null)"     || SITE_USER=""
    WEB_ROOT="$(state_get WEB_ROOT 2>/dev/null)"       || WEB_ROOT=""
    CACHE_PATH="$(state_get CACHE_PATH 2>/dev/null)"   || CACHE_PATH=""
    REDIS_SOCK="$(state_get REDIS_SOCK 2>/dev/null)"   || REDIS_SOCK="/run/redis/redis-server.sock"
    DB_NAME="$(state_get DB_NAME 2>/dev/null)"         || DB_NAME=""
    DB_USER="$(state_get DB_USER 2>/dev/null)"         || DB_USER=""
    DB_PASS="$(state_get DB_PASS 2>/dev/null)"         || DB_PASS=""
}

# ---------------------------------------------------------------------------
# WP-CLI helper (suppresses PHP 8.5 deprecation noise)
# ---------------------------------------------------------------------------
wp_run() {
    sudo -u "$SITE_USER" wp "$@" --path="$WEB_ROOT" 2>&1 | grep -v "^Deprecated:" || true
}

# ---------------------------------------------------------------------------
# Section header helper
# ---------------------------------------------------------------------------
_header() { printf "\n${BOLD}  %s${NC}\n  ──────────────────────────────────────\n" "$1"; }

# ===========================================================================
# MAIN MENU
# ===========================================================================
show_menu() {
    printf "\n${CYAN}===================================================${NC}\n"
    printf "${BOLD}  az-wp — WordPress Management v%s${NC}\n" "$AZ_VERSION"
    printf "  Site: ${GREEN}%s${NC}\n" "$DOMAIN"
    printf "${CYAN}===================================================${NC}\n\n"
    printf "  1) Status        System + services overview\n"
    printf "  2) WordPress     Update, plugins, debug, maintenance\n"
    printf "  3) Database      phpMyAdmin, backup, restore\n"
    printf "  4) Cache         Purge FastCGI + Redis\n"
    printf "  5) Backup        Full backup, restore, schedule\n"
    printf "  6) Cron          Manage cron jobs\n"
    printf "  7) Domain        Change domain\n"
    printf "  8) Advanced      SSL, security, performance, workers\n"
    printf "  9) Help          Version, update, usage\n"
    printf "\n  0) Exit\n"
}

show_usage() {
    cat <<'EOF'
Usage: az-wp [command] [subcommand]

Commands:
  status              System dashboard
  wp [sub]            WordPress: update, plugins, debug, maintenance, admin-pass, cli
  db [sub]            Database: pma, backup, restore, optimize, cli
  cache [sub]         Cache: purge, purge-fcgi, purge-redis, stats
  backup [sub]        Backup: full, list, schedule
  cron [sub]          Cron: list, add, remove
  domain change       Change site domain
  advanced [sub]      SSL, security, performance, services, workers, pma-config
  help                Version + usage

Examples:
  az-wp status
  az-wp wp update
  az-wp cache purge
  az-wp db pma
  az-wp cron list
  az-wp domain change
  az-wp backup full
EOF
}

# ===========================================================================
# 1) STATUS
# ===========================================================================
menu_status() {
    _header "System Status"

    local up; up="$(uptime -p 2>/dev/null | sed 's/^up //')" || up="unknown"
    printf "  Uptime:     %s\n" "$up"

    local load; load="$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)" || load="unknown"
    printf "  Load:       %s\n" "$load"

    local ram_total ram_used ram_pct
    ram_total="$(free -m | awk '/^Mem:/ {print $2}')"
    ram_used="$(free -m | awk '/^Mem:/ {print $3}')"
    ram_pct=$(( ram_total > 0 ? ram_used * 100 / ram_total : 0 ))
    printf "  RAM:        %sMB / %sMB (%s%%)\n" "$ram_used" "$ram_total" "$ram_pct"

    local disk_info; disk_info="$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')" || disk_info="unknown"
    printf "  Disk:       %s\n" "$disk_info"

    printf "\n  ${BOLD}Services:${NC}\n"
    local svc svc_status
    for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server fail2ban; do
        svc_status="$(systemctl is-active "$svc" 2>/dev/null)" || svc_status="not found"
        local color="$RED"; [[ "$svc_status" == "active" ]] && color="$GREEN"
        printf "    %-18s ${color}%s${NC}\n" "${svc}:" "$svc_status"
    done

    local redis_mem; redis_mem="$(redis-cli -s "$REDIS_SOCK" info memory 2>/dev/null | grep -m1 'used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')" || redis_mem="n/a"
    printf "\n  Redis mem:  %s\n" "$redis_mem"

    local ssl_expiry; ssl_expiry="$(echo | openssl s_client -connect localhost:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" || ssl_expiry="n/a"
    printf "  SSL:        %s\n" "$ssl_expiry"

    local cache_size; cache_size="$(du -sh "$CACHE_PATH" 2>/dev/null | awk '{print $1}')" || cache_size="n/a"
    printf "  FastCGI:    %s cached\n" "$cache_size"
}

# ===========================================================================
# 2) WORDPRESS
# ===========================================================================
menu_wordpress() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "WordPress Tools"
        printf "  1) Update all (core + plugins + themes)\n"
        printf "  2) List plugins\n"
        printf "  3) Debug mode on/off\n"
        printf "  4) Maintenance mode on/off\n"
        printf "  5) Reset admin password\n"
        printf "  6) Search & replace\n"
        printf "  7) WP-CLI (pass-through)\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="update" ;; 2) sub="plugins" ;; 3) sub="debug" ;;
            4) sub="maintenance" ;; 5) sub="admin-pass" ;; 6) sub="search-replace" ;;
            7) sub="cli" ;; *) return 0 ;;
        esac
    fi

    case "$sub" in
        update)
            log_info "Updating WordPress core, plugins, and themes..."
            wp_run core update
            wp_run plugin update --all
            wp_run theme update --all
            log_success "WordPress updated."
            ;;
        plugins)
            wp_run plugin list
            ;;
        debug)
            local current; current="$(wp_run config get WP_DEBUG --raw 2>/dev/null | tr -d '[:space:]')"
            local debug_arg="${2:-}"
            # Show current status
            if [[ "$current" == "1" || "$current" == "true" ]]; then
                printf "  Debug mode: ${YELLOW}ON${NC}\n"
            else
                printf "  Debug mode: ${GREEN}OFF${NC}\n"
            fi
            # Toggle or set explicitly
            if [[ "$debug_arg" == "on" ]] || { [[ -z "$debug_arg" ]] && [[ "$current" != "1" && "$current" != "true" ]]; }; then
                wp_run config set WP_DEBUG true --raw > /dev/null
                wp_run config set WP_DEBUG_LOG true --raw > /dev/null
                log_success "Debug mode → ON. Logs: $WEB_ROOT/wp-content/debug.log"
            elif [[ "$debug_arg" == "off" ]] || { [[ -z "$debug_arg" ]] && [[ "$current" == "1" || "$current" == "true" ]]; }; then
                wp_run config set WP_DEBUG false --raw > /dev/null
                wp_run config set WP_DEBUG_LOG false --raw > /dev/null
                log_success "Debug mode → OFF."
            fi
            ;;
        maintenance)
            local mfile="$WEB_ROOT/.maintenance"
            if [[ -f "$mfile" ]]; then
                rm -f "$mfile"
                log_success "Maintenance mode OFF."
            else
                printf '<?php $upgrading = time(); ?>' > "$mfile"
                chown "$SITE_USER:$SITE_USER" "$mfile"
                log_success "Maintenance mode ON."
            fi
            ;;
        admin-pass)
            local new_pass; new_pass="$(generate_password 20)"
            wp_run user update "$(state_get WP_ADMIN_USER 2>/dev/null || echo admin)" --user_pass="$new_pass"
            log_success "Admin password changed: $new_pass"
            ;;
        search-replace)
            local old_str new_str
            read -rp "  Old string: " old_str
            read -rp "  New string: " new_str
            [[ -z "$old_str" || -z "$new_str" ]] && { log_warn "Empty input."; return; }
            log_info "Dry run..."
            wp_run search-replace "$old_str" "$new_str" --dry-run
            confirm "Apply changes?" || return 0
            wp_run search-replace "$old_str" "$new_str"
            log_success "Search & replace complete."
            ;;
        cli)
            printf "  Entering WP-CLI (type 'exit' to return):\n"
            sudo -u "$SITE_USER" wp shell --path="$WEB_ROOT" 2>/dev/null || \
                sudo -u "$SITE_USER" bash -c "cd $WEB_ROOT && exec bash"
            ;;
        *) log_warn "Unknown: $sub" ;;
    esac
}

# ===========================================================================
# 3) DATABASE
# ===========================================================================
menu_database() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "Database Tools"
        printf "  1) phpMyAdmin (open login URL)\n"
        printf "  2) Database info (credentials, paths)\n"
        printf "  3) Optimize tables\n"
        printf "  4) MySQL CLI\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="pma" ;; 2) sub="info" ;;
            3) sub="optimize" ;; 4) sub="cli" ;; *) return 0 ;;
        esac
    fi

    case "$sub" in
        pma)
            local pma_path; pma_path="$(state_get PMA_PATH 2>/dev/null)" || pma_path=""
            if [[ -z "$pma_path" || ! -f /etc/nginx/az-wp-pma.conf ]]; then
                _pma_enable
            else
                printf "\n  ${BOLD}phpMyAdmin:${NC} https://%s%s/\n\n" "$DOMAIN" "$pma_path"
            fi
            ;;
        optimize)
            log_info "Optimizing tables..."
            mysqlcheck --optimize -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null
            log_success "Tables optimized."
            ;;
        cli)
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"
            ;;
        info)
            _header "Database Info"
            printf "  DB Name:  %s\n" "$DB_NAME"
            printf "  DB User:  %s\n" "$DB_USER"
            printf "  DB Pass:  %s\n" "$DB_PASS"
            printf "  Backups:  /home/%s/backups/\n" "$SITE_USER"
            local pma_path; pma_path="$(state_get PMA_PATH 2>/dev/null)" || pma_path=""
            [[ -n "$pma_path" ]] && printf "  PMA URL:  https://%s%s/\n" "$DOMAIN" "$pma_path"
            ;;
        *) log_warn "Unknown: $sub" ;;
    esac
}

# ===========================================================================
# 4) CACHE
# ===========================================================================
menu_cache() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "Cache Management"
        printf "  1) Purge all (FastCGI + Redis)\n"
        printf "  2) Purge FastCGI only\n"
        printf "  3) Purge Redis only\n"
        printf "  4) Cache stats\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="purge" ;; 2) sub="purge-fcgi" ;; 3) sub="purge-redis" ;;
            4) sub="stats" ;; *) return 0 ;;
        esac
    fi

    case "$sub" in
        purge)
            rm -rf "${CACHE_PATH:?}"/* 2>/dev/null || true
            redis-cli -s "$REDIS_SOCK" FLUSHDB > /dev/null 2>&1 || true
            log_success "FastCGI + Redis cache purged."
            ;;
        purge-fcgi)
            rm -rf "${CACHE_PATH:?}"/* 2>/dev/null || true
            log_success "FastCGI cache purged."
            ;;
        purge-redis)
            redis-cli -s "$REDIS_SOCK" FLUSHDB > /dev/null 2>&1 || true
            log_success "Redis cache purged."
            ;;
        stats)
            local fcgi_size; fcgi_size="$(du -sh "$CACHE_PATH" 2>/dev/null | awk '{print $1}')" || fcgi_size="0"
            local fcgi_count; fcgi_count="$(find "$CACHE_PATH" -type f 2>/dev/null | wc -l)" || fcgi_count="0"
            local redis_mem; redis_mem="$(redis-cli -s "$REDIS_SOCK" info memory 2>/dev/null | grep -m1 'used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')" || redis_mem="n/a"
            local redis_keys; redis_keys="$(redis-cli -s "$REDIS_SOCK" dbsize 2>/dev/null | grep -oP '\d+')" || redis_keys="0"
            _header "Cache Stats"
            printf "  FastCGI:  %s (%s files)\n" "$fcgi_size" "$fcgi_count"
            printf "  Redis:    %s (%s keys)\n" "$redis_mem" "$redis_keys"
            ;;
        *) log_warn "Unknown: $sub" ;;
    esac
}

# ===========================================================================
# 5) BACKUP
# ===========================================================================
menu_backup() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "Backup & Restore"
        printf "  1) Full backup (files + DB)\n"
        printf "  2) List backups\n"
        printf "  3) Restore from backup\n"
        printf "  4) Schedule daily backup\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="full" ;; 2) sub="list" ;; 3) sub="restore" ;;
            4) sub="schedule" ;; *) return 0 ;;
        esac
    fi

    local backup_dir="/home/${SITE_USER}/backups"
    mkdir -p "$backup_dir"

    case "$sub" in
        full)
            local ts; ts="$(date +%Y%m%d-%H%M%S)"
            local start_ts; start_ts="$(date +%s)"
            log_info "Starting full backup..."

            # DB
            local db_file="$backup_dir/${DOMAIN}-db-${ts}.sql.gz"
            log_sub "Backing up database..."
            ionice -c3 nice -n 19 mysqldump --single-transaction --quick --lock-tables=false \
                --routines --triggers -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null \
                | gzip > "$db_file"

            # Files
            local files_file="$backup_dir/${DOMAIN}-files-${ts}.tar.gz"
            log_sub "Backing up files..."
            ionice -c3 nice -n 19 tar czf "$files_file" \
                --exclude='wp-content/cache/*' --exclude='wp-content/updraft/*' \
                --exclude='wp-content/upgrade/*' --exclude='.git' \
                --exclude='node_modules' --exclude='*.log' \
                -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")" 2>/dev/null || true

            local elapsed=$(( $(date +%s) - start_ts ))
            local db_size; db_size="$(stat -c%s "$db_file" 2>/dev/null || echo 0)"
            local files_size; files_size="$(stat -c%s "$files_file" 2>/dev/null || echo 0)"
            log_success "Backup complete (${elapsed}s)"
            printf "  DB:    %s (%s)\n" "$db_file" "$(format_size "$db_size")"
            printf "  Files: %s (%s)\n" "$files_file" "$(format_size "$files_size")"
            ;;
        list)
            _header "Available Backups"
            ls -lhS "$backup_dir"/*.gz 2>/dev/null || log_info "No backups found."
            printf "\n  Total: %s\n" "$(du -sh "$backup_dir" 2>/dev/null | awk '{print $1}')"
            ;;
        restore)
            local file="${2:-}"
            [[ -z "$file" ]] && { read -rp "  Backup file path: " file; }
            [[ ! -f "$file" ]] && { log_error "File not found: $file"; return 1; }
            confirm "This will OVERWRITE current data. Continue?" || return 0
            if [[ "$file" == *-db-*.sql.gz ]]; then
                gunzip -c "$file" | mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"
                log_success "Database restored."
            elif [[ "$file" == *-files-*.tar.gz ]]; then
                tar xzf "$file" -C "$(dirname "$WEB_ROOT")"
                chown -R "$SITE_USER:$SITE_USER" "$WEB_ROOT"
                log_success "Files restored."
            else
                log_warn "Unrecognized backup format. Use -db- or -files- in filename."
            fi
            ;;
        schedule)
            local sched="${2:-daily}"
            local cron_file="/etc/cron.d/az-wp-backup"
            if [[ "$sched" == "daily" ]]; then
                printf '# az-wp: daily backup at 3:00 AM\n0 3 * * * root /usr/local/bin/az-wp backup full >> /var/log/az-wp/backup.log 2>&1\n' > "$cron_file"
            elif [[ "$sched" == "weekly" ]]; then
                printf '# az-wp: weekly backup Sunday 3:00 AM\n0 3 * * 0 root /usr/local/bin/az-wp backup full >> /var/log/az-wp/backup.log 2>&1\n' > "$cron_file"
            fi
            chmod 644 "$cron_file"
            log_success "Backup scheduled: $sched"
            ;;
        *) log_warn "Unknown: $sub" ;;
    esac
}

# ===========================================================================
# 6) CRON
# ===========================================================================
menu_cron() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "Cron Management"
        _cron_show_all
        printf "\n  1) Add cron job (paste full cron line)\n"
        printf "  2) Install AffiliateCMS preset crons\n"
        printf "  3) Remove cron job\n"
        printf "  4) Remove all custom crons\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="add" ;; 2) sub="preset" ;; 3) sub="remove" ;;
            4) sub="remove-all" ;; *) return 0 ;;
        esac
    fi

    case "$sub" in
        list) _cron_show_all ;;

        add)
            printf "\n  Paste a full cron line (schedule + command):\n"
            printf "  ${DIM}Example: */5 * * * * curl -s \"https://example.com/wp-json/...\"${NC}\n\n"
            local cron_line
            read -rp "  > " cron_line
            [[ -z "$cron_line" ]] && { log_warn "Empty input."; return; }

            # Auto-generate name from URL path or command
            local cron_name
            cron_name="$(printf '%s' "$cron_line" | grep -oP '/v1/[^?]+' | sed 's|/v1/||;s|/|-|g' | head -1)"
            [[ -z "$cron_name" ]] && cron_name="custom-$(openssl rand -hex 3)"

            # Extract schedule (first 5 fields) and command (rest)
            local sched cmd
            sched="$(printf '%s' "$cron_line" | awk '{print $1,$2,$3,$4,$5}')"
            cmd="$(printf '%s' "$cron_line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}')"

            # Auto-add --resolve and --max-time if curl and not present
            if [[ "$cmd" == *curl* && "$cmd" != *--resolve* ]]; then
                cmd="$(printf '%s' "$cmd" | sed "s|curl |curl -sk --resolve ${DOMAIN}:443:127.0.0.1 --max-time 30 |")"
            fi

            # Strip trailing redirect if already present
            cmd="$(printf '%s' "$cmd" | sed 's|>[/dev/null ]*2>&1||;s|[[:space:]]*$//')"

            local cron_file="/etc/cron.d/az-wp-${cron_name}"
            printf '# az-wp cron: %s\n%s root %s > /dev/null 2>&1\n' \
                "$cron_name" "$sched" "$cmd" > "$cron_file"
            chmod 644 "$cron_file"
            log_success "Created: $cron_file"
            ;;

        preset)
            _cron_install_preset
            ;;

        remove)
            local name="${2:-}"
            if [[ -z "$name" ]]; then
                printf "\n  Existing cron jobs:\n"
                for f in /etc/cron.d/az-wp-*; do
                    [[ -f "$f" ]] && printf "    %s\n" "$(basename "$f")"
                done
                read -rp "  Name to remove: " name
            fi
            [[ -z "$name" ]] && return
            [[ "$name" != az-wp-* ]] && name="az-wp-${name}"
            local target="/etc/cron.d/${name}"
            if [[ -f "$target" ]]; then
                confirm "Remove $target?" || return 0
                rm -f "$target"
                log_success "Removed $target"
            else
                log_warn "Not found: $target"
            fi
            ;;

        remove-all)
            confirm "Remove ALL custom az-wp cron jobs (except wp-cron)?" || return 0
            local count=0
            for f in /etc/cron.d/az-wp-*; do
                [[ ! -f "$f" ]] && continue
                [[ "$(basename "$f")" == "az-wp-cron" ]] && continue
                [[ "$(basename "$f")" == "az-wp-backup" ]] && continue
                rm -f "$f"
                count=$((count + 1))
            done
            log_success "Removed $count cron jobs."
            ;;

        *) log_warn "Unknown: $sub" ;;
    esac
}

# ---------------------------------------------------------------------------
# Cron helpers
# ---------------------------------------------------------------------------
_cron_show_all() {
    printf "\n  ${BOLD}Active cron jobs:${NC}\n"
    local found=0
    for f in /etc/cron.d/az-wp-*; do
        [[ ! -f "$f" ]] && continue
        found=1
        local name; name="$(basename "$f")"
        local desc; desc="$(head -1 "$f" | sed 's/^# az-wp[: ]*//')"
        local sched; sched="$(grep -v '^#' "$f" | grep -v '^$' | head -1 | awk '{print $1,$2,$3,$4,$5}')"
        printf "    ${GREEN}%-30s${NC} %-12s %s\n" "$name" "$sched" "$desc"
    done
    [[ "$found" -eq 0 ]] && printf "    (none)\n"
}

_cron_install_preset() {
    _header "AffiliateCMS Cron Preset"

    # Need API token from WP
    local api_token
    api_token="$(wp_run option get acms_api_token 2>/dev/null | tr -d '[:space:]')" || api_token=""

    if [[ -z "$api_token" ]]; then
        printf "  AffiliateCMS API token not found in WordPress.\n"
        read -rp "  Enter API token (or press ENTER to skip): " api_token
        [[ -z "$api_token" ]] && { log_warn "Skipped."; return; }
    fi

    local base="curl -sk --resolve ${DOMAIN}:443:127.0.0.1 --max-time 30"
    local url="https://${DOMAIN}"

    # Define all preset crons: name|schedule|endpoint|description
    local presets=(
        "scrape|*/5 * * * *|/wp-json/acms/v1/automation/scrape|Scrape dispatcher"
        "scrape-monitor|*/5 * * * *|/wp-json/acms/v1/cron/scrape-monitor|Scrape monitor"
        "queue-processor|*/5 * * * *|/wp-json/acms-cat/v1/cron/queue-processor|Category queue processor"
        "queue-monitor|*/5 * * * *|/wp-json/acms-cat/v1/cron/queue-monitor|Category queue monitor"
        "product-ai|*/10 * * * *|/wp-json/acms/v1/cron/product-ai|Product AI generation"
        "post-ai|*/10 * * * *|/wp-json/acms/v1/cron/post-ai|Post AI generation"
        "category-ai|*/10 * * * *|/wp-json/acms-cat/v1/cron/process-category-ai|Category AI"
        "brand-ai|*/10 * * * *|/wp-json/acms/v1/cron/brand-ai|Brand AI generation"
        "brand-category-ai|*/10 * * * *|/wp-json/acms-cat/v1/cron/brand-category-ai|Brand category AI"
        "quick-update|*/30 * * * *|/wp-json/acms/v1/cron/quick-update|Quick price update"
        "retry-stuck|*/10 * * * *|/wp-json/acms-cat/v1/cron/retry-stuck|Retry stuck jobs"
        "bulk-update|* * * * *|/wp-json/acms-cat/v1/cron/bulk-update-worker|Bulk update worker"
        "cache-preload|0 3 * * 0|/wp-json/acms/v1/cache/preload|Weekly cache preload"
        "cache-refresh|0 */4 * * *|/wp-json/acms/v1/cache/smart-refresh|Smart cache refresh"
        "cache-resume|*/30 * * * *|/wp-json/acms/v1/cache/resume-queue|Resume cache queue"
    )

    printf "  Will create %d cron jobs for AffiliateCMS:\n\n" "${#presets[@]}"
    local p
    for p in "${presets[@]}"; do
        IFS='|' read -r name sched endpoint desc <<< "$p"
        printf "    %-12s %-25s %s\n" "$sched" "$desc" "$endpoint"
    done

    printf "\n"
    confirm "Install all ${#presets[@]} cron jobs?" || return 0

    local count=0
    for p in "${presets[@]}"; do
        IFS='|' read -r name sched endpoint desc <<< "$p"
        local cron_file="/etc/cron.d/az-wp-${name}"
        printf '# az-wp cron: %s\n%s root %s "%s%s?token=%s" > /dev/null 2>&1\n' \
            "$desc" "$sched" "$base" "$url" "$endpoint" "$api_token" > "$cron_file"
        chmod 644 "$cron_file"
        count=$((count + 1))
    done

    log_success "Installed $count AffiliateCMS cron jobs."
    printf "  ${DIM}View: az-wp cron list${NC}\n"
}

# ===========================================================================
# 7) DOMAIN CHANGE
# ===========================================================================
menu_domain() {
    local sub="${1:-change}"

    _header "Domain Management"
    printf "  Current domain: ${GREEN}%s${NC}\n\n" "$DOMAIN"

    local new_domain
    read -rp "  New domain: " new_domain
    [[ -z "$new_domain" ]] && { log_warn "No domain entered."; return; }
    [[ "$new_domain" == "$DOMAIN" ]] && { log_warn "Same as current domain."; return; }

    printf "\n  ${BOLD}This will:${NC}\n"
    printf "    1. Search & replace '%s' → '%s' in database\n" "$DOMAIN" "$new_domain"
    printf "    2. Update WordPress URLs\n"
    printf "    3. Update Nginx configuration\n"
    printf "    4. Issue new SSL certificate\n"
    printf "    5. Update cron jobs\n"
    printf "    6. Update state file\n\n"

    confirm "Proceed with domain change?" || return 0

    local old_domain="$DOMAIN"

    # 1. Database search & replace
    log_sub "Replacing in database: $old_domain → $new_domain ..."
    wp_run search-replace "$old_domain" "$new_domain" --all-tables --precise > /dev/null
    wp_run search-replace "http://$old_domain" "https://$new_domain" --all-tables --precise > /dev/null
    wp_run search-replace "https://$old_domain" "https://$new_domain" --all-tables --precise > /dev/null

    # 2. Update WordPress URLs
    log_sub "Updating WordPress site URL..."
    wp_run option update siteurl "https://$new_domain" > /dev/null
    wp_run option update home "https://$new_domain" > /dev/null

    # 3. Update Nginx config
    log_sub "Updating Nginx configuration..."
    local old_conf="/etc/nginx/sites-available/${old_domain}.conf"
    local new_conf="/etc/nginx/sites-available/${new_domain}.conf"

    if [[ -f "$old_conf" ]]; then
        sed -i "s/${old_domain}/${new_domain}/g" "$old_conf"
        if [[ "$old_conf" != "$new_conf" ]]; then
            mv "$old_conf" "$new_conf"
            rm -f "/etc/nginx/sites-enabled/${old_domain}.conf"
            ln -sf "$new_conf" "/etc/nginx/sites-enabled/${new_domain}.conf"
        fi
    fi

    # Update error log path in nginx config
    sed -i "s|${old_domain}-error.log|${new_domain}-error.log|g" "$new_conf" 2>/dev/null || true

    # 4. SSL — remove old, issue new
    log_sub "Updating SSL certificate..."
    # Detect public IP for SSL
    PUBLIC_IP="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)" || PUBLIC_IP=""
    DOMAIN="$new_domain"
    issue_certificate 2>/dev/null || log_warn "SSL issue failed. Run 'az-wp advanced' → SSL later."

    # 5. Update cron jobs
    log_sub "Updating cron jobs..."
    for f in /etc/cron.d/az-wp-*; do
        [[ -f "$f" ]] && sed -i "s/${old_domain}/${new_domain}/g" "$f"
    done

    # 6. Update state file
    log_sub "Updating state file..."
    state_set "DOMAIN" "$new_domain"
    DOMAIN="$new_domain"

    # 7. Update WP cache salt
    wp_run config set WP_CACHE_KEY_SALT "${new_domain}_" > /dev/null
    redis-cli -s "$REDIS_SOCK" FLUSHDB > /dev/null 2>&1 || true

    # Reload
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        log_warn "Nginx config error. Check: nginx -t"
    fi

    printf "\n"
    log_success "Domain changed: $old_domain → $new_domain"
    printf "  Website: https://%s\n" "$new_domain"
    printf "  Admin:   https://%s/wp-admin\n\n" "$new_domain"
}

# ===========================================================================
# 8) ADVANCED
# ===========================================================================
menu_advanced() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]; then
        _header "Advanced Settings"
        printf "  1) SSL Management\n"
        printf "  2) Security (Fail2Ban, UFW)\n"
        printf "  3) Performance (retune, TTFB, FPM, OPcache)\n"
        printf "  4) Services (restart, reload)\n"
        printf "  5) Workers (FPM pools)\n"
        printf "  6) phpMyAdmin config\n"
        printf "  0) Back\n\n"
        read -rp "  Choose: " sub
        case "$sub" in
            1) sub="ssl" ;; 2) sub="security" ;; 3) sub="perf" ;;
            4) sub="services" ;; 5) sub="workers" ;; 6) sub="pma-config" ;;
            *) return 0 ;;
        esac
    fi

    case "$sub" in
        # --- SSL ---
        ssl)
            local ssl_sub="${2:-}"
            if [[ -z "$ssl_sub" ]]; then
                _header "SSL Management"
                printf "  1) Issue/renew certificate\n"
                printf "  2) Certificate info\n"
                printf "  0) Back\n\n"
                read -rp "  Choose: " ssl_sub
                case "$ssl_sub" in 1) ssl_sub="issue" ;; 2) ssl_sub="info" ;; *) return 0 ;; esac
            fi
            case "$ssl_sub" in
                issue|renew)
                    PUBLIC_IP="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)" || PUBLIC_IP=""
                    issue_certificate
                    ;;
                info)
                    echo | openssl s_client -connect localhost:443 -servername "$DOMAIN" 2>/dev/null \
                        | openssl x509 -noout -subject -issuer -dates 2>/dev/null || log_warn "No SSL cert found."
                    ;;
            esac
            ;;

        # --- Security ---
        security)
            local sec_sub="${2:-}"
            if [[ -z "$sec_sub" ]]; then
                _header "Security"
                printf "  1) Fail2Ban status\n"
                printf "  2) Unban IP\n"
                printf "  3) UFW status\n"
                printf "  0) Back\n\n"
                read -rp "  Choose: " sec_sub
                case "$sec_sub" in 1) sec_sub="f2b-status" ;; 2) sec_sub="unban" ;; 3) sec_sub="ufw" ;; *) return 0 ;; esac
            fi
            case "$sec_sub" in
                f2b-status) fail2ban-client status 2>/dev/null; for jail in $(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g'); do printf "\n"; fail2ban-client status "$jail" 2>/dev/null; done ;;
                unban) local ip; read -rp "  IP to unban: " ip; [[ -n "$ip" ]] && fail2ban-client unban "$ip" 2>/dev/null && log_success "Unbanned $ip" ;;
                ufw) ufw status verbose 2>/dev/null ;;
            esac
            ;;

        # --- Performance ---
        perf)
            local perf_sub="${2:-}"
            if [[ -z "$perf_sub" ]]; then
                _header "Performance"
                printf "  1) Re-tune (after VPS resize)\n"
                printf "  2) Test TTFB\n"
                printf "  3) FPM status\n"
                printf "  4) OPcache status\n"
                printf "  5) Reload PHP-FPM\n"
                printf "  0) Back\n\n"
                read -rp "  Choose: " perf_sub
                case "$perf_sub" in 1) perf_sub="retune" ;; 2) perf_sub="ttfb" ;; 3) perf_sub="fpm" ;; 4) perf_sub="opcache" ;; 5) perf_sub="reload-fpm" ;; *) return 0 ;; esac
            fi
            case "$perf_sub" in
                retune)
                    detect_hardware; calculate_tune; print_tune_summary
                    confirm "Apply new tuning?" || return 0
                    # Re-render configs
                    configure_nginx; configure_fastcgi_cache; configure_site
                    configure_php_ini; configure_opcache; configure_fpm_pools
                    configure_mariadb; configure_redis
                    systemctl restart nginx "php${PHP_VERSION}-fpm" mariadb redis-server
                    log_success "All configs re-tuned and services restarted."
                    ;;
                ttfb)
                    printf "  Testing TTFB for https://%s ...\n" "$DOMAIN"
                    curl -sk --resolve "${DOMAIN}:443:127.0.0.1" -o /dev/null \
                        -w "  TTFB:  %{time_starttransfer}s\n  Total: %{time_total}s\n" \
                        "https://${DOMAIN}/"
                    ;;
                fpm)
                    printf "\n  ${BOLD}Web pool:${NC}\n"
                    curl -s http://127.0.0.1/fpm-status 2>/dev/null || printf "  (status page not accessible)\n"
                    printf "\n  ${BOLD}Workers pool:${NC}\n"
                    curl -s http://127.0.0.1/fpm-workers-status 2>/dev/null || printf "  (status page not accessible)\n"
                    ;;
                opcache)
                    php -r 'print_r(opcache_get_status(false));' 2>/dev/null || printf "  OPcache not available on CLI.\n"
                    ;;
                reload-fpm)
                    service_restart "php${PHP_VERSION}-fpm"
                    log_success "PHP-FPM restarted (OPcache cleared)."
                    ;;
            esac
            ;;

        # --- Services ---
        services)
            local svc_sub="${2:-}"
            if [[ -z "$svc_sub" ]]; then
                _header "Services Control"
                printf "  1) Restart all\n"
                printf "  2) Restart Nginx\n"
                printf "  3) Restart PHP-FPM\n"
                printf "  4) Restart MariaDB\n"
                printf "  5) Restart Redis\n"
                printf "  0) Back\n\n"
                read -rp "  Choose: " svc_sub
                case "$svc_sub" in 1) svc_sub="all" ;; 2) svc_sub="nginx" ;; 3) svc_sub="fpm" ;; 4) svc_sub="mariadb" ;; 5) svc_sub="redis" ;; *) return 0 ;; esac
            fi
            case "$svc_sub" in
                all) for s in nginx "php${PHP_VERSION}-fpm" mariadb redis-server; do service_restart "$s"; done ;;
                nginx) service_restart nginx ;;
                fpm) service_restart "php${PHP_VERSION}-fpm" ;;
                mariadb) service_restart mariadb ;;
                redis) service_restart redis-server ;;
            esac
            ;;

        # --- Workers ---
        workers)
            local w_sub="${2:-}"
            if [[ -z "$w_sub" ]]; then
                _header "Workers Management"
                local web_active web_max wrk_active wrk_max
                web_active="$(curl -s http://127.0.0.1/fpm-status 2>/dev/null | grep 'active processes:' | head -1 | awk '{print $NF}')" || web_active="?"
                web_max="$(grep 'pm.max_children' /etc/php/${PHP_VERSION}/fpm/pool.d/web.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')" || web_max="?"
                wrk_active="$(curl -s http://127.0.0.1/fpm-workers-status 2>/dev/null | grep 'active processes:' | head -1 | awk '{print $NF}')" || wrk_active="?"
                wrk_max="$(grep 'pm.max_children' /etc/php/${PHP_VERSION}/fpm/pool.d/workers.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')" || wrk_max="?"
                printf "  Web pool:     %s / %s active\n" "$web_active" "$web_max"
                printf "  Workers pool: %s / %s active\n" "$wrk_active" "$wrk_max"
                printf "\n  Long-running (>30s):\n"
                ps -eo pid,etimes,pcpu,pmem,comm 2>/dev/null | grep php-fpm | awk '$2>30 {printf "    PID %-8s %ss  CPU:%s%%  MEM:%s%%\n", $1, $2, $3, $4}' || printf "    (none)\n"
                printf "\n  1) Kill stuck processes (>300s)\n  0) Back\n\n"
                read -rp "  Choose: " w_sub
                case "$w_sub" in 1) w_sub="kill-stuck" ;; *) return 0 ;; esac
            fi
            case "$w_sub" in
                kill-stuck)
                    local pids; pids="$(ps -eo pid,etimes,comm 2>/dev/null | grep php-fpm | awk '$2>300 {print $1}')"
                    if [[ -z "$pids" ]]; then log_info "No stuck processes."; return; fi
                    printf "  Will kill: %s\n" "$pids"
                    confirm "Kill these processes?" || return 0
                    echo "$pids" | xargs kill -9 2>/dev/null || true
                    log_success "Killed stuck processes."
                    ;;
            esac
            ;;

        # --- phpMyAdmin config ---
        pma-config)
            local pma_sub="${2:-}"
            if [[ -z "$pma_sub" ]]; then
                _header "phpMyAdmin Config"
                local pma_path; pma_path="$(state_get PMA_PATH 2>/dev/null)" || pma_path=""
                if [[ -n "$pma_path" && -f /etc/nginx/az-wp-pma.conf ]]; then
                    printf "  Status: ${GREEN}enabled${NC}\n"
                    printf "  URL:    https://%s%s/\n" "$DOMAIN" "$pma_path"
                else
                    printf "  Status: ${RED}disabled${NC}\n"
                fi
                printf "\n  1) Enable\n  2) Disable\n  3) Regenerate URL\n  0) Back\n\n"
                read -rp "  Choose: " pma_sub
                case "$pma_sub" in 1) pma_sub="enable" ;; 2) pma_sub="disable" ;; 3) pma_sub="regenerate" ;; *) return 0 ;; esac
            fi
            case "$pma_sub" in
                enable) _pma_enable ;;
                disable)
                    rm -f /etc/nginx/az-wp-pma.conf /etc/phpmyadmin/conf.d/az-wp-autologin.php /usr/share/phpmyadmin/az-wp-gate.php 2>/dev/null
                    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
                    sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
                    service_reload nginx
                    log_success "phpMyAdmin disabled."
                    ;;
                regenerate)
                    rm -f /etc/nginx/az-wp-pma.conf
                    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"
                    sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
                    _pma_enable
                    ;;
            esac
            ;;

        *) log_warn "Unknown advanced command: $sub" ;;
    esac
}

# ===========================================================================
# phpMyAdmin enable helper
# ===========================================================================
_pma_enable() {
    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    # Install if missing
    if [[ ! -d /usr/share/phpmyadmin ]]; then
        log_info "Installing phpMyAdmin..."
        NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin > /dev/null 2>&1 \
            || die "Failed to install phpMyAdmin."
        log_success "phpMyAdmin installed."
    fi

    local pma_path="/pma-$(openssl rand -hex 8)"

    # FPM pool
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
        systemctl restart "php${PHP_VERSION}-fpm"
    fi

    # Nginx snippet
    cat > /etc/nginx/az-wp-pma.conf <<PMACONF
    # phpMyAdmin — managed by az-wp
    location ^~ ${pma_path}/ {
        alias /usr/share/phpmyadmin/;
        index index.php;
        location ~ \.php\$ {
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-pma.sock;
        }
    }
    # end phpMyAdmin
PMACONF

    sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
    if ! grep -q "az-wp-pma.conf" "$nginx_conf"; then
        sed -i '/^}$/i \    include /etc/nginx/az-wp-pma.conf;' "$nginx_conf"
    fi

    # Auto-login config
    mkdir -p /etc/phpmyadmin/conf.d
    local db_user db_pass
    db_user="$(state_get DB_USER)" || db_user=""
    db_pass="$(state_get DB_PASS)" || db_pass=""
    cat > /etc/phpmyadmin/conf.d/az-wp-autologin.php <<PHPCFG
<?php
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['Servers'][1]['user'] = '${db_user}';
\$cfg['Servers'][1]['password'] = '${db_pass}';
\$cfg['Servers'][1]['AllowNoPassword'] = false;
PHPCFG

    if nginx -t 2>/dev/null; then
        service_reload nginx
    else
        log_error "Nginx config test failed."
        rm -f /etc/nginx/az-wp-pma.conf
        sed -i '/az-wp-pma.conf/d' "$nginx_conf"
        return 1
    fi

    state_set "PMA_PATH" "$pma_path"
    log_success "phpMyAdmin enabled."
    printf "\n  ${BOLD}URL:${NC} https://%s%s/\n\n" "$DOMAIN" "$pma_path"
}

# ===========================================================================
# 9) HELP
# ===========================================================================
menu_help() {
    printf "\n  ${BOLD}az-wp${NC} v%s\n" "$AZ_VERSION"
    printf "  WordPress management CLI for single-site VPS.\n\n"
    show_usage
}

# ===========================================================================
# MAIN DISPATCHER
# ===========================================================================
main() {
    load_state

    if [[ $# -gt 0 ]]; then
        case "$1" in
            status)   menu_status ;;
            wp)       menu_wordpress "${2:-}" ;;
            db)       menu_database "${2:-}" "${3:-}" ;;
            cache)    menu_cache "${2:-}" ;;
            backup)   menu_backup "${2:-}" "${3:-}" ;;
            cron)     menu_cron "${2:-}" "${3:-}" ;;
            domain)   menu_domain "${2:-}" ;;
            advanced) menu_advanced "${2:-}" "${3:-}" ;;
            help|-h|--help) menu_help ;;
            # Shortcuts
            pma)      menu_database pma ;;
            retune)   menu_advanced perf retune ;;
            ssl)      menu_advanced ssl "${2:-}" ;;
            *)        printf "Unknown: %s\n" "$1"; show_usage ;;
        esac
    else
        while true; do
            show_menu
            printf "\n"
            read -rp "  Choose [0-9]: " choice
            case "$choice" in
                1) menu_status ;; 2) menu_wordpress ;; 3) menu_database ;;
                4) menu_cache ;; 5) menu_backup ;; 6) menu_cron ;;
                7) menu_domain ;; 8) menu_advanced ;; 9) menu_help ;;
                0) printf "  Goodbye!\n"; exit 0 ;;
                *) printf "  Invalid choice.\n" ;;
            esac
            printf "\n"
            read -rp "  Press ENTER to continue..." _
        done
    fi
}

main "$@"
