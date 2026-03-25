#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths (follow symlink to real location)
# ---------------------------------------------------------------------------
_SELF="${BASH_SOURCE[0]}"
# Resolve symlink chain to get the real script path
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
# shellcheck source=lib/common.sh
source "$AZ_DIR/lib/common.sh"

az_init

# Source optional libraries
[[ -f "$AZ_DIR/lib/detect.sh" ]]    && source "$AZ_DIR/lib/detect.sh"
[[ -f "$AZ_DIR/lib/tuning.sh" ]]    && source "$AZ_DIR/lib/tuning.sh"
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
# Error trap (non-fatal in menu context)
# ---------------------------------------------------------------------------
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Load state from install.state into globals
# ---------------------------------------------------------------------------
load_state() {
    if [[ ! -f "$AZ_STATE_FILE" ]]; then
        die "az-wp not installed. Run install.sh first."
    fi

    DOMAIN="$(state_get DOMAIN 2>/dev/null)" || true
    if [[ -z "${DOMAIN:-}" ]]; then
        die "az-wp not installed. Run install.sh first."
    fi

    PHP_VERSION="$(state_get PHP_VERSION 2>/dev/null)"   || PHP_VERSION="8.4"
    SITE_USER="$(state_get SITE_USER 2>/dev/null)"       || SITE_USER=""
    WEB_ROOT="$(state_get WEB_ROOT 2>/dev/null)"         || WEB_ROOT=""
    CACHE_PATH="$(state_get CACHE_PATH 2>/dev/null)"     || CACHE_PATH=""
    REDIS_SOCK="$(state_get REDIS_SOCK 2>/dev/null)"     || REDIS_SOCK="/run/redis/redis-server.sock"
    DB_NAME="$(state_get DB_NAME 2>/dev/null)"           || DB_NAME=""
    DB_USER="$(state_get DB_USER 2>/dev/null)"           || DB_USER=""
    DB_PASS="$(state_get DB_PASS 2>/dev/null)"           || DB_PASS=""
    SSL_ISSUED="$(state_get SSL_ISSUED 2>/dev/null)"     || SSL_ISSUED="false"
}

# ---------------------------------------------------------------------------
# WP-CLI helper
# ---------------------------------------------------------------------------
wp_run() {
    sudo -u "$SITE_USER" wp "$@" --path="$WEB_ROOT" 2>&1
}

# ---------------------------------------------------------------------------
# Show interactive menu
# ---------------------------------------------------------------------------
show_menu() {
    printf "\n"
    printf "${CYAN}===================================================${NC}\n"
    printf "${BOLD}  az-wp -- WordPress Management CLI v%s${NC}\n" "$AZ_VERSION"
    printf "  Site: ${GREEN}%s${NC}\n" "$DOMAIN"
    printf "${CYAN}===================================================${NC}\n"
    printf "\n"
    printf "   1) System Status\n"
    printf "   2) Cache Management\n"
    printf "   3) Database Tools\n"
    printf "   4) Backup & Restore\n"
    printf "   5) SSL Management\n"
    printf "   6) Performance Tuning\n"
    printf "   7) Security & Firewall\n"
    printf "   8) Services Control\n"
    printf "   9) WordPress Tools\n"
    printf "  10) Logs Viewer\n"
    printf "  11) Workers Management\n"
    printf "  12) phpMyAdmin\n"
    printf "  13) Script Management\n"
    printf "\n"
    printf "   0) Exit\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
show_usage() {
    printf "Usage: az-wp [command] [subcommand]\n\n"
    printf "Commands:\n"
    printf "  status     System status dashboard\n"
    printf "  cache      Cache management (purge, stats)\n"
    printf "  db         Database tools (backup, restore, optimize)\n"
    printf "  backup     Backup & restore\n"
    printf "  ssl        SSL certificate management\n"
    printf "  perf       Performance tuning\n"
    printf "  security   Security & firewall\n"
    printf "  service    Services control\n"
    printf "  wp         WordPress tools (update, debug, etc.)\n"
    printf "  logs       Log viewer\n"
    printf "  workers    PHP-FPM workers management\n"
    printf "  pma        phpMyAdmin management\n"
    printf "  self       Script management & updates\n"
    printf "  retune     Re-tune configs for current RAM\n"
    printf "\n"
    printf "Run without arguments for interactive menu.\n"
}

# ===========================================================================
# 1) System Status
# ===========================================================================
menu_status() {
    printf "\n${BOLD}  System Status${NC}\n"
    printf "  ─────────────────────────────────────────────\n"

    # Uptime
    local up
    up="$(uptime -p 2>/dev/null | sed 's/^up //')" || up="unknown"
    printf "  Uptime:     %s\n" "$up"

    # Load
    local load
    load="$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)" || load="unknown"
    printf "  Load:       %s\n" "$load"

    # RAM
    local ram_total ram_used ram_pct
    ram_total="$(free -m | awk '/^Mem:/ {print $2}')"
    ram_used="$(free -m | awk '/^Mem:/ {print $3}')"
    if [[ "$ram_total" -gt 0 ]]; then
        ram_pct=$(( ram_used * 100 / ram_total ))
    else
        ram_pct=0
    fi
    printf "  RAM:        %sMB / %sMB (%s%%)\n" "$ram_used" "$ram_total" "$ram_pct"

    # Disk
    local disk_info
    disk_info="$(df -h / | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')" || disk_info="unknown"
    printf "  Disk:       %s\n" "$disk_info"

    printf "\n  ${BOLD}Services:${NC}\n"

    # Service statuses
    local svc svc_status
    for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server fail2ban; do
        svc_status="$(systemctl is-active "$svc" 2>/dev/null)" || svc_status="not found"
        local color="$RED"
        [[ "$svc_status" == "active" ]] && color="$GREEN"
        printf "    %-18s ${color}%s${NC}\n" "${svc}:" "$svc_status"
    done

    # Redis memory
    local redis_mem
    redis_mem="$(redis-cli -s "$REDIS_SOCK" info memory 2>/dev/null | grep -m1 'used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')" || redis_mem="n/a"
    printf "\n  Redis mem:  %s\n" "$redis_mem"

    # SSL expiry
    local ssl_expiry
    ssl_expiry="$(echo | openssl s_client -connect localhost:443 -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" || ssl_expiry="n/a"
    printf "  SSL:        %s\n" "$ssl_expiry"

    # FastCGI cache size
    local cache_size
    cache_size="$(du -sh "$CACHE_PATH" 2>/dev/null | awk '{print $1}')" || cache_size="n/a"
    printf "  FastCGI:    %s cached\n" "$cache_size"
}

# ===========================================================================
# 2) Cache Management
# ===========================================================================
menu_cache() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Cache Management${NC}\n"
        printf "  1) Purge FastCGI cache\n"
        printf "  2) Purge Redis cache\n"
        printf "  3) Purge all caches\n"
        printf "  4) Cache stats\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="purge-fcgi" ;;
            2) sub="purge-redis" ;;
            3) sub="purge-all" ;;
            4) sub="stats" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        purge-fcgi)
            confirm "Purge FastCGI cache?" || return 0
            rm -rf "${CACHE_PATH:?}"/*
            log_success "FastCGI cache purged."
            ;;
        purge-redis)
            confirm "Purge Redis cache?" || return 0
            redis-cli -s "$REDIS_SOCK" FLUSHDB 2>/dev/null
            log_success "Redis cache purged."
            ;;
        purge-all)
            confirm "Purge ALL caches (FastCGI + Redis)?" || return 0
            rm -rf "${CACHE_PATH:?}"/*
            redis-cli -s "$REDIS_SOCK" FLUSHDB 2>/dev/null
            log_success "All caches purged."
            ;;
        stats)
            printf "\n${BOLD}  Cache Stats${NC}\n"
            local fcgi_size
            fcgi_size="$(du -sh "$CACHE_PATH" 2>/dev/null | awk '{print $1}')" || fcgi_size="n/a"
            printf "  FastCGI size:  %s\n" "$fcgi_size"

            local redis_mem redis_keys
            redis_mem="$(redis-cli -s "$REDIS_SOCK" info memory 2>/dev/null | grep -m1 'used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')" || redis_mem="n/a"
            redis_keys="$(redis-cli -s "$REDIS_SOCK" dbsize 2>/dev/null | awk '{print $NF}')" || redis_keys="n/a"
            printf "  Redis memory:  %s\n" "$redis_mem"
            printf "  Redis keys:    %s\n" "$redis_keys"
            ;;
        *)
            log_warn "Unknown cache command: $sub"
            ;;
    esac
}

# ===========================================================================
# 3) Database Tools
# ===========================================================================
menu_database() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Database Tools${NC}\n"
        printf "  1) Backup database\n"
        printf "  2) Restore database\n"
        printf "  3) Optimize tables\n"
        printf "  4) MySQL CLI\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="backup" ;;
            2) sub="restore" ;;
            3) sub="optimize" ;;
            4) sub="cli" ;;
            0|*) return 0 ;;
        esac
    fi

    local backup_dir="/home/${SITE_USER}/backups"
    mkdir -p "$backup_dir"

    case "$sub" in
        backup)
            local stamp
            stamp="$(date '+%Y%m%d-%H%M%S')"
            local outfile="${backup_dir}/db-${stamp}.sql.gz"
            log_info "Backing up database ${DB_NAME}..."
            ionice -c3 nice -n19 mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
                --single-transaction --quick --routines --triggers \
                2>/dev/null | gzip > "$outfile"
            local size
            size="$(du -sh "$outfile" | awk '{print $1}')"
            log_success "Backup saved: ${outfile} (${size})"
            ;;
        restore)
            local file="${2:-}"
            if [[ -z "$file" ]]; then
                printf "  Available backups:\n"
                ls -lh "${backup_dir}"/db-*.sql.gz 2>/dev/null || { log_warn "No backups found."; return 0; }
                printf "\n"
                read -rp "  Enter backup file path: " file
            fi
            if [[ ! -f "$file" ]]; then
                log_error "File not found: $file"
                return 1
            fi
            confirm "Restore database from ${file}? This will OVERWRITE current data!" || return 0
            log_info "Restoring database..."
            if [[ "$file" == *.gz ]]; then
                gunzip -c "$file" | mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null
            else
                mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$file" 2>/dev/null
            fi
            log_success "Database restored from ${file}."
            ;;
        optimize)
            confirm "Optimize all tables in ${DB_NAME}?" || return 0
            log_info "Optimizing tables..."
            mysqlcheck --optimize -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null
            log_success "Optimization complete."
            ;;
        cli)
            log_info "Entering MySQL CLI (type 'exit' to return)..."
            mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>/dev/null
            ;;
        *)
            log_warn "Unknown db command: $sub"
            ;;
    esac
}

# ===========================================================================
# 4) Backup & Restore
# ===========================================================================
menu_backup() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Backup & Restore${NC}\n"
        printf "  1) Full backup (files + DB)\n"
        printf "  2) Database only\n"
        printf "  3) List backups\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-3]: " sub
        case "$sub" in
            1) sub="full" ;;
            2) sub="db" ;;
            3) sub="list" ;;
            0|*) return 0 ;;
        esac
    fi

    local backup_dir="/home/${SITE_USER}/backups"
    mkdir -p "$backup_dir"

    case "$sub" in
        full)
            confirm "Create full backup (files + database)?" || return 0
            local stamp
            stamp="$(date '+%Y%m%d-%H%M%S')"

            # DB backup
            local db_file="${backup_dir}/db-${stamp}.sql.gz"
            log_info "Dumping database..."
            ionice -c3 nice -n19 mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
                --single-transaction --quick --routines --triggers \
                2>/dev/null | gzip > "$db_file"

            # Files backup
            local files_file="${backup_dir}/files-${stamp}.tar.gz"
            log_info "Archiving web root..."
            ionice -c3 nice -n19 tar czf "$files_file" \
                --exclude='wp-content/cache' \
                --exclude='wp-content/uploads/acms-preload-queue.txt' \
                -C "$(dirname "$WEB_ROOT")" "$(basename "$WEB_ROOT")" 2>/dev/null

            local db_size files_size
            db_size="$(du -sh "$db_file" | awk '{print $1}')"
            files_size="$(du -sh "$files_file" | awk '{print $1}')"
            log_success "Full backup complete:"
            printf "    DB:    %s (%s)\n" "$db_file" "$db_size"
            printf "    Files: %s (%s)\n" "$files_file" "$files_size"
            ;;
        db)
            menu_database backup
            ;;
        list)
            printf "\n${BOLD}  Backups in %s:${NC}\n" "$backup_dir"
            if ls -lh "${backup_dir}"/*.{sql.gz,tar.gz} 2>/dev/null; then
                true
            else
                log_warn "No backups found."
            fi
            ;;
        *)
            log_warn "Unknown backup command: $sub"
            ;;
    esac
}

# ===========================================================================
# 5) SSL Management
# ===========================================================================
menu_ssl() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  SSL Management${NC}\n"
        printf "  1) Issue certificate\n"
        printf "  2) Renew certificate\n"
        printf "  3) Certificate info\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-3]: " sub
        case "$sub" in
            1) sub="issue" ;;
            2) sub="renew" ;;
            3) sub="info" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        issue)
            if type -t issue_certificate &>/dev/null; then
                issue_certificate
            else
                log_info "Issuing SSL via Certbot..."
                certbot --nginx -d "$DOMAIN" -d "www.${DOMAIN}" --non-interactive --agree-tos --redirect 2>&1
                log_success "SSL certificate issued."
                state_set "SSL_ISSUED" "true"
            fi
            ;;
        renew)
            log_info "Renewing SSL certificates..."
            certbot renew --nginx 2>&1
            log_success "SSL renewal complete."
            ;;
        info)
            printf "\n${BOLD}  SSL Certificate Info${NC}\n"
            echo | openssl s_client -connect localhost:443 -servername "$DOMAIN" 2>/dev/null \
                | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null \
                || log_warn "Could not retrieve SSL info."
            ;;
        *)
            log_warn "Unknown ssl command: $sub"
            ;;
    esac
}

# ===========================================================================
# 6) Performance Tuning
# ===========================================================================
menu_performance() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Performance Tuning${NC}\n"
        printf "  1) Re-tune configs\n"
        printf "  2) Test TTFB\n"
        printf "  3) FPM status\n"
        printf "  4) OPcache status\n"
        printf "  5) Reload PHP-FPM\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-5]: " sub
        case "$sub" in
            1) sub="retune" ;;
            2) sub="ttfb" ;;
            3) sub="fpm-status" ;;
            4) sub="opcache" ;;
            5) sub="reload-fpm" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        retune)
            do_retune
            ;;
        ttfb)
            printf "\n${BOLD}  TTFB Test: %s${NC}\n" "$DOMAIN"
            curl -o /dev/null -s -w \
                "  DNS:      %{time_namelookup}s\n  Connect:  %{time_connect}s\n  TLS:      %{time_appconnect}s\n  TTFB:     %{time_starttransfer}s\n  Total:    %{time_total}s\n" \
                "https://${DOMAIN}"
            ;;
        fpm-status)
            printf "\n${BOLD}  PHP-FPM Status${NC}\n"
            curl -s "http://127.0.0.1/fpm-status" 2>/dev/null || log_warn "FPM status page not available. Check nginx config for /fpm-status."
            printf "\n"
            # Try workers pool
            curl -s "http://127.0.0.1/fpm-workers-status" 2>/dev/null || true
            ;;
        opcache)
            printf "\n${BOLD}  OPcache Status${NC}\n"
            php -r '
                $s = opcache_get_status(false);
                if (!$s) { echo "OPcache not available.\n"; exit; }
                $m = $s["memory_usage"];
                printf("  Used:     %.1f MB\n", $m["used_memory"]/1048576);
                printf("  Free:     %.1f MB\n", $m["free_memory"]/1048576);
                printf("  Wasted:   %.1f MB (%.1f%%)\n", $m["wasted_memory"]/1048576, $m["current_wasted_percentage"]);
                $st = $s["opcache_statistics"];
                printf("  Scripts:  %d cached\n", $st["num_cached_scripts"]);
                printf("  Hit rate: %.1f%%\n", $st["opcache_hit_rate"]);
            ' 2>/dev/null || log_warn "Could not read OPcache status."
            ;;
        reload-fpm)
            service_restart "php${PHP_VERSION}-fpm"
            log_success "PHP-FPM restarted (OPcache cleared)."
            ;;
        *)
            log_warn "Unknown perf command: $sub"
            ;;
    esac
}

# ===========================================================================
# 7) Security & Firewall
# ===========================================================================
menu_security() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Security & Firewall${NC}\n"
        printf "  1) Banned IPs (Fail2Ban)\n"
        printf "  2) Unban IP\n"
        printf "  3) Check file permissions\n"
        printf "  4) Fix file permissions\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="banned" ;;
            2) sub="unban" ;;
            3) sub="permissions" ;;
            4) sub="fix-perms" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        banned)
            printf "\n${BOLD}  Fail2Ban Status${NC}\n"
            local jails
            jails="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*:\s*//' | tr ',' '\n' | tr -d '[:space:]')" || true
            if [[ -z "$jails" ]]; then
                log_warn "Fail2Ban not running or no jails configured."
                return 0
            fi
            local jail
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                printf "\n  ${CYAN}Jail: %s${NC}\n" "$jail"
                fail2ban-client status "$jail" 2>/dev/null | sed 's/^/    /'
            done <<< "$jails"
            ;;
        unban)
            local ip="${2:-}"
            if [[ -z "$ip" ]]; then
                read -rp "  IP to unban: " ip
            fi
            [[ -z "$ip" ]] && return 0
            printf "  Unbanning %s from all jails...\n" "$ip"
            local jails
            jails="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*:\s*//' | tr ',' '\n' | tr -d '[:space:]')" || true
            local jail
            while IFS= read -r jail; do
                [[ -z "$jail" ]] && continue
                fail2ban-client set "$jail" unbanip "$ip" 2>/dev/null && \
                    printf "    Unbanned from %s\n" "$jail" || true
            done <<< "$jails"
            log_success "Unban complete for $ip."
            ;;
        permissions)
            printf "\n${BOLD}  File Permission Check${NC}\n"
            local bad_dirs bad_files
            bad_dirs="$(find "$WEB_ROOT" -type d ! -perm 755 2>/dev/null | head -20)" || true
            bad_files="$(find "$WEB_ROOT" -type f ! -perm 644 -a ! -name 'wp-config.php' 2>/dev/null | head -20)" || true

            if [[ -z "$bad_dirs" && -z "$bad_files" ]]; then
                log_success "All permissions look correct (dirs=755, files=644)."
            else
                if [[ -n "$bad_dirs" ]]; then
                    printf "  ${YELLOW}Directories not 755:${NC}\n"
                    printf "%s\n" "$bad_dirs" | sed 's/^/    /'
                fi
                if [[ -n "$bad_files" ]]; then
                    printf "  ${YELLOW}Files not 644:${NC}\n"
                    printf "%s\n" "$bad_files" | sed 's/^/    /'
                fi
                printf "\n  Use 'az-wp security fix-perms' to fix.\n"
            fi

            # wp-config check
            local wpc_perm
            wpc_perm="$(stat -c '%a' "${WEB_ROOT}/wp-config.php" 2>/dev/null)" || wpc_perm="n/a"
            if [[ "$wpc_perm" == "640" ]]; then
                printf "  wp-config.php: ${GREEN}%s (OK)${NC}\n" "$wpc_perm"
            else
                printf "  wp-config.php: ${YELLOW}%s (should be 640)${NC}\n" "$wpc_perm"
            fi
            ;;
        fix-perms)
            confirm "Fix file permissions in ${WEB_ROOT}?" || return 0
            log_info "Fixing permissions..."
            find "$WEB_ROOT" -type d -exec chmod 755 {} \;
            find "$WEB_ROOT" -type f -exec chmod 644 {} \;
            chmod 640 "${WEB_ROOT}/wp-config.php" 2>/dev/null || true
            chown -R "${SITE_USER}:${SITE_USER}" "$WEB_ROOT"
            log_success "Permissions fixed."
            ;;
        *)
            log_warn "Unknown security command: $sub"
            ;;
    esac
}

# ===========================================================================
# 8) Services Control
# ===========================================================================
menu_services() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Services Control${NC}\n"
        printf "  1) Status all\n"
        printf "  2) Restart service\n"
        printf "  3) Restart all\n"
        printf "  4) Reload service\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="status" ;;
            2) sub="restart" ;;
            3) sub="restart-all" ;;
            4) sub="reload" ;;
            0|*) return 0 ;;
        esac
    fi

    local all_services=("nginx" "php${PHP_VERSION}-fpm" "mariadb" "redis-server" "fail2ban")

    case "$sub" in
        status)
            printf "\n${BOLD}  Service Status${NC}\n"
            local svc svc_status
            for svc in "${all_services[@]}"; do
                svc_status="$(systemctl is-active "$svc" 2>/dev/null)" || svc_status="not found"
                local color="$RED"
                [[ "$svc_status" == "active" ]] && color="$GREEN"
                printf "    %-22s ${color}%s${NC}\n" "$svc" "$svc_status"
            done
            ;;
        restart)
            local svc_name="${2:-}"
            if [[ -z "$svc_name" ]]; then
                printf "  Available: %s\n" "${all_services[*]}"
                read -rp "  Service to restart: " svc_name
            fi
            [[ -z "$svc_name" ]] && return 0
            service_restart "$svc_name"
            ;;
        restart-all)
            confirm "Restart all services?" || return 0
            local svc
            for svc in "${all_services[@]}"; do
                service_restart "$svc" || true
            done
            log_success "All services restarted."
            ;;
        reload)
            local svc_name="${2:-}"
            if [[ -z "$svc_name" ]]; then
                printf "  Available: nginx php${PHP_VERSION}-fpm\n"
                read -rp "  Service to reload: " svc_name
            fi
            [[ -z "$svc_name" ]] && return 0
            service_reload "$svc_name"
            ;;
        *)
            log_warn "Unknown service command: $sub"
            ;;
    esac
}

# ===========================================================================
# 9) WordPress Tools
# ===========================================================================
menu_wordpress() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  WordPress Tools${NC}\n"
        printf "  1) Update core + plugins + themes\n"
        printf "  2) List plugins\n"
        printf "  3) Reset admin password\n"
        printf "  4) Maintenance mode on/off\n"
        printf "  5) Debug mode on/off\n"
        printf "  6) Search & Replace\n"
        printf "  7) WP-CLI\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-7]: " sub
        case "$sub" in
            1) sub="update" ;;
            2) sub="plugins" ;;
            3) sub="admin-pass" ;;
            4) sub="maintenance" ;;
            5) sub="debug" ;;
            6) sub="search-replace" ;;
            7) sub="cli" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        update)
            confirm "Update WordPress core, plugins, and themes?" || return 0
            log_info "Updating WordPress core..."
            wp_run core update || true
            log_info "Updating plugins..."
            wp_run plugin update --all || true
            log_info "Updating themes..."
            wp_run theme update --all || true
            log_success "WordPress updates complete."
            ;;
        plugins)
            printf "\n${BOLD}  Installed Plugins${NC}\n"
            wp_run plugin list --format=table
            ;;
        admin-pass)
            local new_pass
            new_pass="$(generate_password 20)"
            local admin_user="${2:-admin}"
            confirm "Reset password for user '${admin_user}'?" || return 0
            wp_run user update "$admin_user" --user_pass="$new_pass"
            log_success "Password reset for '${admin_user}'."
            printf "  New password: ${BOLD}%s${NC}\n" "$new_pass"
            ;;
        maintenance)
            local mode="${2:-}"
            if [[ -z "$mode" ]]; then
                read -rp "  Maintenance mode (on/off): " mode
            fi
            case "$mode" in
                on)
                    wp_run maintenance-mode activate 2>/dev/null || \
                        printf "<?php \$upgrading = %d; ?>" "$(date +%s)" > "${WEB_ROOT}/.maintenance"
                    log_success "Maintenance mode enabled."
                    ;;
                off)
                    wp_run maintenance-mode deactivate 2>/dev/null || \
                        rm -f "${WEB_ROOT}/.maintenance"
                    log_success "Maintenance mode disabled."
                    ;;
                *)
                    log_warn "Usage: maintenance on|off"
                    ;;
            esac
            ;;
        debug)
            local mode="${2:-}"
            if [[ -z "$mode" ]]; then
                read -rp "  Debug mode (on/off): " mode
            fi
            case "$mode" in
                on)
                    wp_run config set WP_DEBUG true --raw
                    wp_run config set WP_DEBUG_LOG true --raw
                    log_success "Debug mode enabled. Log: wp-content/debug.log"
                    ;;
                off)
                    wp_run config set WP_DEBUG false --raw
                    wp_run config set WP_DEBUG_LOG false --raw
                    log_success "Debug mode disabled."
                    ;;
                *)
                    log_warn "Usage: debug on|off"
                    ;;
            esac
            ;;
        search-replace)
            local old="${2:-}" new="${3:-}"
            if [[ -z "$old" || -z "$new" ]]; then
                read -rp "  Search for: " old
                read -rp "  Replace with: " new
            fi
            [[ -z "$old" || -z "$new" ]] && { log_warn "Both values required."; return 0; }

            printf "\n${BOLD}  Dry run:${NC}\n"
            wp_run search-replace "$old" "$new" --dry-run
            printf "\n"
            confirm "Apply search-replace?" || return 0
            wp_run search-replace "$old" "$new"
            log_success "Search-replace complete."
            ;;
        cli)
            shift 2>/dev/null || true
            if [[ $# -gt 0 ]]; then
                wp_run "$@"
            else
                log_info "Entering WP-CLI (run wp commands as ${SITE_USER})..."
                sudo -u "$SITE_USER" -i bash -c "cd '$WEB_ROOT' && exec bash --rcfile <(echo 'PS1=\"[wp-cli] \w\$ \"')"
            fi
            ;;
        *)
            log_warn "Unknown wp command: $sub"
            ;;
    esac
}

# ===========================================================================
# 10) Logs Viewer
# ===========================================================================
menu_logs() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Logs Viewer${NC}\n"
        printf "  1) Nginx error log\n"
        printf "  2) PHP error log\n"
        printf "  3) MariaDB slow log\n"
        printf "  4) Fail2Ban log\n"
        printf "  5) WordPress debug log\n"
        printf "  6) Top IPs (access log)\n"
        printf "  7) Top 404s (access log)\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-7]: " sub
        case "$sub" in
            1) sub="nginx" ;;
            2) sub="php" ;;
            3) sub="mariadb" ;;
            4) sub="fail2ban" ;;
            5) sub="wp-debug" ;;
            6) sub="top-ips" ;;
            7) sub="top-404" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        nginx)
            local logfile="/var/log/nginx/${DOMAIN}-error.log"
            if [[ -f "$logfile" ]]; then
                printf "  ${DIM}(Ctrl+C to stop)${NC}\n"
                tail -f "$logfile"
            else
                log_warn "Log not found: $logfile"
                # Try default
                tail -f /var/log/nginx/error.log 2>/dev/null || log_warn "No nginx error log found."
            fi
            ;;
        php)
            local logfile="/var/log/php/error.log"
            [[ ! -f "$logfile" ]] && logfile="/var/log/php${PHP_VERSION}-fpm.log"
            if [[ -f "$logfile" ]]; then
                printf "  ${DIM}(Ctrl+C to stop)${NC}\n"
                tail -f "$logfile"
            else
                log_warn "PHP error log not found."
            fi
            ;;
        mariadb)
            local logfile="/var/log/mysql/slow.log"
            [[ ! -f "$logfile" ]] && logfile="/var/log/mysql/mariadb-slow.log"
            if [[ -f "$logfile" ]]; then
                printf "  ${DIM}(Ctrl+C to stop)${NC}\n"
                tail -f "$logfile"
            else
                log_warn "MariaDB slow log not found."
            fi
            ;;
        fail2ban)
            printf "  ${DIM}(Ctrl+C to stop)${NC}\n"
            tail -f /var/log/fail2ban.log 2>/dev/null || log_warn "Fail2Ban log not found."
            ;;
        wp-debug)
            local logfile="${WEB_ROOT}/wp-content/debug.log"
            if [[ -f "$logfile" ]]; then
                printf "  ${DIM}(Ctrl+C to stop)${NC}\n"
                tail -f "$logfile"
            else
                log_warn "WordPress debug log not found. Enable with: az-wp wp debug on"
            fi
            ;;
        top-ips)
            local access_log="/var/log/nginx/${DOMAIN}-access.log"
            [[ ! -f "$access_log" ]] && access_log="/var/log/nginx/access.log"
            if [[ -f "$access_log" ]]; then
                printf "\n${BOLD}  Top 20 IPs${NC}\n"
                awk '{print $1}' "$access_log" | sort | uniq -c | sort -rn | head -20 | \
                    awk '{printf "    %-8s %s\n", $1, $2}'
            else
                log_warn "Access log not found."
            fi
            ;;
        top-404)
            local access_log="/var/log/nginx/${DOMAIN}-access.log"
            [[ ! -f "$access_log" ]] && access_log="/var/log/nginx/access.log"
            if [[ -f "$access_log" ]]; then
                printf "\n${BOLD}  Top 20 404 URLs${NC}\n"
                awk '$9 == 404 {print $7}' "$access_log" | sort | uniq -c | sort -rn | head -20 | \
                    awk '{printf "    %-8s %s\n", $1, $2}'
            else
                log_warn "Access log not found."
            fi
            ;;
        *)
            log_warn "Unknown logs command: $sub"
            ;;
    esac
}

# ===========================================================================
# 11) Workers Management
# ===========================================================================
menu_workers() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Workers Management${NC}\n"
        printf "  1) FPM pool status\n"
        printf "  2) Adjust pool sizes\n"
        printf "  3) Long-running processes\n"
        printf "  4) Kill stuck processes\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="status" ;;
            2) sub="adjust" ;;
            3) sub="long-running" ;;
            4) sub="kill-stuck" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        status)
            printf "\n${BOLD}  PHP-FPM Pool Status${NC}\n"
            printf "\n  ${CYAN}Web Pool:${NC}\n"
            curl -s "http://127.0.0.1/fpm-status?full" 2>/dev/null | head -20 || log_warn "Web pool status not available."
            printf "\n  ${CYAN}Workers Pool:${NC}\n"
            curl -s "http://127.0.0.1/fpm-workers-status?full" 2>/dev/null | head -20 || log_warn "Workers pool status not available."

            printf "\n  ${CYAN}Process counts:${NC}\n"
            local web_count worker_count
            web_count="$(pgrep -c -f 'pool web' 2>/dev/null)" || web_count=0
            worker_count="$(pgrep -c -f 'pool workers' 2>/dev/null)" || worker_count=0
            printf "    Web pool:     %s processes\n" "$web_count"
            printf "    Workers pool: %s processes\n" "$worker_count"
            ;;
        adjust)
            local web_max="${2:-}" worker_max="${3:-}"
            if [[ -z "$web_max" ]]; then
                read -rp "  Web pool max_children (current: check fpm-status): " web_max
                read -rp "  Workers pool max_children: " worker_max
            fi
            [[ -z "$web_max" || -z "$worker_max" ]] && { log_warn "Both values required."; return 0; }

            confirm "Set web=${web_max}, workers=${worker_max}?" || return 0

            local web_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/web.conf"
            local workers_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/workers.conf"

            if [[ -f "$web_pool" ]]; then
                sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${web_max}/" "$web_pool"
                log_info "Updated web pool: max_children=${web_max}"
            else
                log_warn "Web pool config not found: $web_pool"
            fi

            if [[ -f "$workers_pool" ]]; then
                sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${worker_max}/" "$workers_pool"
                log_info "Updated workers pool: max_children=${worker_max}"
            else
                log_warn "Workers pool config not found: $workers_pool"
            fi

            service_reload "php${PHP_VERSION}-fpm"
            log_success "FPM pools adjusted and reloaded."
            ;;
        long-running)
            printf "\n${BOLD}  Long-running PHP-FPM processes (>30s)${NC}\n"
            printf "  %-8s %-10s %-6s %-6s %-10s %s\n" "PID" "ELAPSED" "CPU%" "MEM%" "RSS(KB)" "CMD"
            ps -eo pid,etimes,pcpu,pmem,rss,comm --no-headers 2>/dev/null \
                | grep 'php-fpm' \
                | awk '$2 > 30 {printf "  %-8s %-10s %-6s %-6s %-10s %s\n", $1, $2"s", $3, $4, $5, $6}' \
                || printf "  (none)\n"
            ;;
        kill-stuck)
            printf "\n${BOLD}  Stuck PHP-FPM processes (>300s)${NC}\n"
            local pids
            pids="$(ps -eo pid,etimes,comm --no-headers 2>/dev/null \
                | awk '/php-fpm/ && $2 > 300 {print $1}')" || true
            if [[ -z "$pids" ]]; then
                log_info "No stuck processes found."
                return 0
            fi
            printf "  PIDs: %s\n" "$pids"
            confirm "Kill these processes?" || return 0
            local pid
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null && printf "  Killed PID %s\n" "$pid" || true
            done
            log_success "Stuck processes killed."
            ;;
        *)
            log_warn "Unknown workers command: $sub"
            ;;
    esac
}

# ===========================================================================
# 12) phpMyAdmin
# ===========================================================================
menu_phpmyadmin() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  phpMyAdmin Management${NC}\n"
        printf "  1) Enable (install + auto-login)\n"
        printf "  2) Disable\n"
        printf "  3) Get login URL\n"
        printf "  4) Regenerate URL + token\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-4]: " sub
        case "$sub" in
            1) sub="enable" ;;
            2) sub="disable" ;;
            3) sub="info" ;;
            4) sub="regenerate" ;;
            0|*) return 0 ;;
        esac
    fi

    local nginx_conf="/etc/nginx/sites-available/${DOMAIN}.conf"

    case "$sub" in
        enable)
            # Install phpMyAdmin if not present
            if [[ ! -d /usr/share/phpmyadmin ]]; then
                log_info "Installing phpMyAdmin..."
                NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin > /dev/null 2>&1 \
                    || die "Failed to install phpMyAdmin."
                log_success "phpMyAdmin installed."
            fi

            # Generate random URL path (security through obscurity + token)
            local pma_path="/pma-$(openssl rand -hex 8)"
            local pma_token
            pma_token="$(openssl rand -hex 32)"

            # Create dedicated FPM pool for phpMyAdmin (runs as www-data)
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
                log_sub "phpMyAdmin FPM pool created."
            fi

            # Create nginx snippet — token-based access
            # Use ^~ to override regex static file matching
            local pma_snippet="/etc/nginx/az-wp-pma.conf"
            cat > "$pma_snippet" <<PMACONF
    # phpMyAdmin — managed by az-wp (token-based access + cookie session)
    location ^~ ${pma_path}/ {
        alias /usr/share/phpmyadmin/;
        index index.php;

        # Set cookie when token is in URL (first visit)
        if (\$arg_token = "${pma_token}") {
            add_header Set-Cookie "pma_auth=${pma_token}; Path=${pma_path}/; HttpOnly; Secure; SameSite=Lax" always;
        }

        location ~ \.php\$ {
            # Allow if: token in URL OR valid cookie
            set \$pma_allow 0;
            if (\$arg_token = "${pma_token}") { set \$pma_allow 1; }
            if (\$cookie_pma_auth = "${pma_token}") { set \$pma_allow 1; }
            if (\$pma_allow = 0) { return 403; }

            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-pma.sock;
        }
    }
    # end phpMyAdmin
PMACONF

            # Inject include before closing } of server block
            sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
            if ! grep -q "az-wp-pma.conf" "$nginx_conf"; then
                sed -i '/^}$/i \    include /etc/nginx/az-wp-pma.conf;' "$nginx_conf"
            fi

            # Create auto-login config for phpMyAdmin
            local pma_config_dir="/etc/phpmyadmin/conf.d"
            mkdir -p "$pma_config_dir"
            local db_user db_pass
            db_user="$(state_get DB_USER)" || db_user=""
            db_pass="$(state_get DB_PASS)" || db_pass=""

            cat > "$pma_config_dir/az-wp-autologin.php" <<PHPCFG
<?php
// Auto-login — managed by az-wp
\$cfg['Servers'][1]['auth_type'] = 'config';
\$cfg['Servers'][1]['user'] = '${db_user}';
\$cfg['Servers'][1]['password'] = '${db_pass}';
\$cfg['Servers'][1]['AllowNoPassword'] = false;
PHPCFG

            if nginx -t 2>/dev/null; then
                service_reload nginx
            else
                log_error "Nginx config test failed."
                rm -f "$pma_snippet"
                sed -i '/az-wp-pma.conf/d' "$nginx_conf"
                return 1
            fi

            # Save to state
            state_set "PMA_PATH" "$pma_path"
            state_set "PMA_TOKEN" "$pma_token"

            local login_url="https://${DOMAIN}${pma_path}/?token=${pma_token}"
            log_success "phpMyAdmin enabled."
            printf "\n  ${BOLD}Login URL (click to auto-login):${NC}\n"
            printf "  %s\n\n" "$login_url"
            printf "  ${DIM}Token expires: never (regenerate with 'az-wp pma regenerate')${NC}\n"
            ;;
        disable)
            confirm "Disable phpMyAdmin?" || return 0
            rm -f /etc/nginx/az-wp-pma.conf
            rm -f /etc/phpmyadmin/conf.d/az-wp-autologin.php 2>/dev/null
            sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
            service_reload nginx
            log_success "phpMyAdmin disabled."
            ;;
        info|login)
            local pma_path pma_token
            pma_path="$(state_get PMA_PATH 2>/dev/null)" || true
            pma_token="$(state_get PMA_TOKEN 2>/dev/null)" || true
            if [[ -z "$pma_path" || -z "$pma_token" ]]; then
                log_warn "phpMyAdmin not configured. Run 'az-wp pma enable' first."
                return 0
            fi
            local login_url="https://${DOMAIN}${pma_path}/?token=${pma_token}"
            printf "\n${BOLD}  phpMyAdmin Login URL:${NC}\n"
            printf "  %s\n\n" "$login_url"
            printf "  ${DIM}Click the URL above — auto-login, no password needed.${NC}\n"
            printf "  ${DIM}Regenerate: az-wp pma regenerate${NC}\n"
            ;;
        regenerate)
            confirm "Regenerate phpMyAdmin URL and token?" || return 0
            rm -f /etc/nginx/az-wp-pma.conf
            rm -f /etc/phpmyadmin/conf.d/az-wp-autologin.php 2>/dev/null
            sed -i '/az-wp-pma.conf/d' "$nginx_conf" 2>/dev/null || true
            menu_phpmyadmin enable
            ;;
        *)
            log_warn "Unknown pma command: $sub"
            ;;
    esac
}

# ===========================================================================
# 13) Script Management
# ===========================================================================
menu_self() {
    local sub="${1:-}"

    if [[ -z "$sub" ]]; then
        printf "\n${BOLD}  Script Management${NC}\n"
        printf "  1) Version\n"
        printf "  2) Update (check for updates)\n"
        printf "  3) Help\n"
        printf "  0) Back\n\n"
        read -rp "  Choose [0-3]: " sub
        case "$sub" in
            1) sub="version" ;;
            2) sub="update" ;;
            3) sub="help" ;;
            0|*) return 0 ;;
        esac
    fi

    case "$sub" in
        version)
            printf "  az-wp v%s\n" "$AZ_VERSION"
            printf "  Install dir: %s\n" "$AZ_DIR"
            printf "  State file:  %s\n" "$AZ_STATE_FILE"
            ;;
        update)
            log_warn "Auto-update not yet implemented."
            printf "  Current version: %s\n" "$AZ_VERSION"
            printf "  To update manually, pull latest files into %s\n" "$AZ_DIR"
            ;;
        help)
            show_usage
            ;;
        *)
            log_warn "Unknown self command: $sub"
            ;;
    esac
}

# ===========================================================================
# Re-tune
# ===========================================================================
do_retune() {
    if ! type -t detect_hardware &>/dev/null || ! type -t calculate_tune &>/dev/null; then
        die "detect.sh and tuning.sh are required for retune."
    fi

    detect_hardware
    calculate_tune

    printf "\n${BOLD}  Current hardware: %s RAM, %s CPU cores${NC}\n" "${TOTAL_RAM_MB}MB" "$CPU_CORES"
    print_tune_summary

    confirm "Apply new tuning and restart all services?" || return 0

    # Re-render templates if render function exists
    local templates_applied=0

    # PHP-FPM pools
    local web_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/web.conf"
    local workers_pool="/etc/php/${PHP_VERSION}/fpm/pool.d/workers.conf"

    if [[ -f "$AZ_DIR/templates/php-fpm-web.conf" && -f "$web_pool" ]]; then
        export SITE_USER PHP_VERSION REDIS_SOCK WEB_ROOT
        render_template "$AZ_DIR/templates/php-fpm-web.conf" "$web_pool" \
            "SITE_USER PHP_VERSION REDIS_SOCK WEB_ROOT TUNE_PHP_PM TUNE_WEB_MAX_CHILDREN TUNE_WEB_START_SERVERS TUNE_WEB_MIN_SPARE TUNE_WEB_MAX_SPARE TUNE_WEB_PROCESS_IDLE_TIMEOUT TUNE_PHP_MEMORY_LIMIT TUNE_OPCACHE_MEMORY TUNE_JIT_BUFFER"
        templates_applied=1
    fi

    if [[ -f "$AZ_DIR/templates/php-fpm-workers.conf" && -f "$workers_pool" && "$TUNE_WORKERS_ENABLED" == "true" ]]; then
        render_template "$AZ_DIR/templates/php-fpm-workers.conf" "$workers_pool" \
            "SITE_USER PHP_VERSION REDIS_SOCK WEB_ROOT TUNE_WORKERS_MAX_CHILDREN TUNE_WORKERS_START_SERVERS TUNE_WORKERS_MIN_SPARE TUNE_WORKERS_MAX_SPARE TUNE_WORKERS_PROCESS_IDLE_TIMEOUT TUNE_PHP_MEMORY_LIMIT"
        templates_applied=1
    fi

    # Nginx
    if [[ -f "$AZ_DIR/templates/nginx.conf" ]]; then
        render_template "$AZ_DIR/templates/nginx.conf" "/etc/nginx/nginx.conf" \
            "TUNE_NGINX_WORKERS TUNE_NGINX_RLIMIT_NOFILE TUNE_NGINX_WORKER_CONNECTIONS"
        templates_applied=1
    fi

    # MariaDB
    if [[ -f "$AZ_DIR/templates/mariadb-server.cnf" ]]; then
        render_template "$AZ_DIR/templates/mariadb-server.cnf" "/etc/mysql/mariadb.conf.d/50-server.cnf" \
            "TUNE_INNODB_BUFFER_POOL TUNE_INNODB_LOG_FILE_SIZE TUNE_MARIADB_MAX_CONNECTIONS"
        templates_applied=1
    fi

    # Redis
    if [[ -f "$AZ_DIR/templates/redis.conf" ]]; then
        render_template "$AZ_DIR/templates/redis.conf" "/etc/redis/redis.conf" \
            "TUNE_REDIS_MAXMEM REDIS_SOCK"
        templates_applied=1
    fi

    if [[ "$templates_applied" -eq 0 ]]; then
        log_warn "No templates found. Applying tuning values directly to pool configs..."
        # Direct sed fallback for FPM
        if [[ -f "$web_pool" ]]; then
            sed -i "s/^pm\s*=.*/pm = ${TUNE_PHP_PM}/" "$web_pool"
            sed -i "s/^pm\.max_children\s*=.*/pm.max_children = ${TUNE_WEB_MAX_CHILDREN}/" "$web_pool"
        fi
    fi

    # Restart all services
    log_info "Restarting services..."
    service_restart nginx || true
    service_restart "php${PHP_VERSION}-fpm" || true
    service_restart mariadb || true
    service_restart redis-server || true

    log_success "Retune complete."
}

# ===========================================================================
# Main dispatch
# ===========================================================================
main() {
    require_root
    load_state

    if [[ $# -gt 0 ]]; then
        # Direct subcommand mode
        case "$1" in
            status)   menu_status ;;
            cache)    menu_cache "${@:2}" ;;
            db)       menu_database "${@:2}" ;;
            backup)   menu_backup "${@:2}" ;;
            ssl)      menu_ssl "${@:2}" ;;
            perf)     menu_performance "${@:2}" ;;
            security) menu_security "${@:2}" ;;
            service)  menu_services "${@:2}" ;;
            wp)       menu_wordpress "${@:2}" ;;
            logs)     menu_logs "${@:2}" ;;
            workers)  menu_workers "${@:2}" ;;
            pma)      menu_phpmyadmin "${@:2}" ;;
            self)     menu_self "${@:2}" ;;
            retune)   do_retune ;;
            help)     show_usage ;;
            *)        log_error "Unknown command: $1"; show_usage; exit 1 ;;
        esac
    else
        # Interactive menu loop
        while true; do
            show_menu
            read -rp "  Choose [0-13]: " choice
            case "$choice" in
                1)  menu_status ;;
                2)  menu_cache ;;
                3)  menu_database ;;
                4)  menu_backup ;;
                5)  menu_ssl ;;
                6)  menu_performance ;;
                7)  menu_security ;;
                8)  menu_services ;;
                9)  menu_wordpress ;;
                10) menu_logs ;;
                11) menu_workers ;;
                12) menu_phpmyadmin ;;
                13) menu_self ;;
                0)  printf "Goodbye!\n"; exit 0 ;;
                *)  log_warn "Invalid choice." ;;
            esac
            printf "\n"
            read -rp "  Press ENTER to continue..." _
        done
    fi
}

main "$@"
