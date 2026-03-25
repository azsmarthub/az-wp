#!/usr/bin/env bash
# backup.sh — Backup and restore for az-wp single site
# Adapted from proven vps-backup.sh patterns
[[ -n "${_AZ_BACKUP_LOADED:-}" ]] && return 0
_AZ_BACKUP_LOADED=1

# ---------------------------------------------------------------------------
# Globals (set by backup_init from state/config)
# ---------------------------------------------------------------------------
BACKUP_DIR=""
BACKUP_RETENTION_DAYS=""
_BACKUP_DATE=""
_BACKUP_TIMESTAMP=""

# ---------------------------------------------------------------------------
# Exclude patterns for file backup (same as vps-backup.sh)
# ---------------------------------------------------------------------------
_BACKUP_EXCLUDE_PATTERNS=(
    "wp-content/cache/*"
    "wp-content/updraft/*"
    "wp-content/upgrade/*"
    "wp-content/wflogs/*"
    "wp-content/ai1wm-backups/*"
    ".git"
    "node_modules"
    "*.log"
)

# ---------------------------------------------------------------------------
# backup_init — Read config, set up backup directory
# ---------------------------------------------------------------------------
backup_init() {
    local site_user
    site_user="$(state_get SITE_USER)" || die "SITE_USER not found in state"

    BACKUP_DIR="$(config_get BACKUP_DIR 2>/dev/null)" || BACKUP_DIR="/home/${site_user}/backups"
    BACKUP_RETENTION_DAYS="$(config_get BACKUP_RETENTION_DAYS 2>/dev/null)" || BACKUP_RETENTION_DAYS="14"

    mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory: $BACKUP_DIR"

    _BACKUP_DATE="$(date +%Y-%m-%d)"
    _BACKUP_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
}

# ---------------------------------------------------------------------------
# backup_db — Dump database to compressed file
# Returns: file path via stdout (last line)
# ---------------------------------------------------------------------------
backup_db() {
    local db_name db_user db_pass domain output_file

    db_name="$(state_get DB_NAME)" || die "DB_NAME not found in state"
    db_user="$(state_get DB_USER)" || die "DB_USER not found in state"
    db_pass="$(state_get DB_PASS)" || die "DB_PASS not found in state"
    domain="$(state_get DOMAIN)" || die "DOMAIN not found in state"

    output_file="${BACKUP_DIR}/${domain}-db-${_BACKUP_DATE}.sql.gz"

    log_info "Backing up database: ${db_name}"

    ionice -c3 nice -n 19 mysqldump \
        --single-transaction --quick --lock-tables=false \
        --routines --triggers \
        -u "$db_user" -p"$db_pass" "$db_name" \
        2>/dev/null | ionice -c3 nice -n 19 gzip > "$output_file"

    local dump_exit="${PIPESTATUS[0]}"

    if [[ "$dump_exit" -ne 0 ]] || [[ ! -s "$output_file" ]]; then
        rm -f "$output_file"
        die "Database backup failed (mysqldump exit code: ${dump_exit})"
    fi

    local file_size
    file_size="$(stat -c%s "$output_file" 2>/dev/null || echo 0)"
    log_success "DB backup OK: $(format_size "$file_size") -> $(basename "$output_file")"

    echo "$output_file"
}

# ---------------------------------------------------------------------------
# backup_files — Archive site files to compressed tarball
# Returns: file path via stdout (last line)
# ---------------------------------------------------------------------------
backup_files() {
    local web_root domain output_file

    web_root="$(state_get WEB_ROOT)" || die "WEB_ROOT not found in state"
    domain="$(state_get DOMAIN)" || die "DOMAIN not found in state"

    output_file="${BACKUP_DIR}/${domain}-files-${_BACKUP_DATE}.tar.gz"

    log_info "Backing up files: ${web_root}"

    ionice -c3 nice -n 19 tar czf "$output_file" \
        --exclude='wp-content/cache/*' \
        --exclude='wp-content/updraft/*' \
        --exclude='wp-content/upgrade/*' \
        --exclude='wp-content/wflogs/*' \
        --exclude='wp-content/ai1wm-backups/*' \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='*.log' \
        -C "$(dirname "$web_root")" "$(basename "$web_root")" 2>/dev/null

    local tar_exit=$?

    # tar exit 1 = "some files changed while being archived" — acceptable
    if [[ "$tar_exit" -gt 1 ]] || [[ ! -s "$output_file" ]]; then
        rm -f "$output_file"
        die "Files backup failed (tar exit code: ${tar_exit})"
    fi

    local file_size
    file_size="$(stat -c%s "$output_file" 2>/dev/null || echo 0)"
    log_success "Files backup OK: $(format_size "$file_size") -> $(basename "$output_file")"

    echo "$output_file"
}

# ---------------------------------------------------------------------------
# backup_full — Full backup: DB + files + cleanup
# ---------------------------------------------------------------------------
backup_full() {
    backup_init

    local domain
    domain="$(state_get DOMAIN)" || die "DOMAIN not found in state"

    log_info "========================================"
    log_info "Full backup: ${domain}"
    log_info "Backup dir: ${BACKUP_DIR}"
    log_info "Retention: ${BACKUP_RETENTION_DAYS} days"
    log_info "========================================"

    local start_time
    start_time="$(date +%s)"

    local db_file files_file
    db_file="$(backup_db)"
    files_file="$(backup_files)"

    local elapsed=$(( $(date +%s) - start_time ))
    local elapsed_str="${elapsed}s"
    [[ "$elapsed" -ge 60 ]] && elapsed_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"

    local db_size files_size total_size
    db_size="$(stat -c%s "$db_file" 2>/dev/null || echo 0)"
    files_size="$(stat -c%s "$files_file" 2>/dev/null || echo 0)"
    total_size=$(( db_size + files_size ))

    log_info "========================================"
    log_success "Backup complete in ${elapsed_str} — total: $(format_size "$total_size")"
    log_info "========================================"

    cleanup_old_backups
}

# ---------------------------------------------------------------------------
# backup_db_only — Database-only backup + cleanup
# ---------------------------------------------------------------------------
backup_db_only() {
    backup_init
    backup_db
    cleanup_old_backups
}

# ---------------------------------------------------------------------------
# restore_db — Restore database from dump file
# ---------------------------------------------------------------------------
restore_db() {
    local file="$1"

    [[ -z "$file" ]] && die "Usage: restore_db <file.sql.gz|file.sql>"
    [[ ! -f "$file" ]] && die "File not found: $file"

    local db_name db_user db_pass
    db_name="$(state_get DB_NAME)" || die "DB_NAME not found in state"
    db_user="$(state_get DB_USER)" || die "DB_USER not found in state"
    db_pass="$(state_get DB_PASS)" || die "DB_PASS not found in state"

    log_warn "This will OVERWRITE database '${db_name}' with data from: $(basename "$file")"

    if ! confirm "Are you sure you want to restore this database?"; then
        log_info "Restore cancelled"
        return 1
    fi

    log_info "Restoring database: ${db_name} from $(basename "$file")"

    if [[ "$file" == *.gz ]]; then
        gunzip -c "$file" | mysql -u "$db_user" -p"$db_pass" "$db_name"
    elif [[ "$file" == *.sql ]]; then
        mysql -u "$db_user" -p"$db_pass" "$db_name" < "$file"
    else
        die "Unsupported file format. Expected .sql.gz or .sql"
    fi

    log_success "Database restored successfully from: $(basename "$file")"
}

# ---------------------------------------------------------------------------
# restore_full — Restore files from tarball
# ---------------------------------------------------------------------------
restore_full() {
    local file="$1"

    [[ -z "$file" ]] && die "Usage: restore_full <file.tar.gz>"
    [[ ! -f "$file" ]] && die "File not found: $file"
    [[ "$file" != *.tar.gz ]] && die "Expected a .tar.gz file"

    local web_root site_user
    web_root="$(state_get WEB_ROOT)" || die "WEB_ROOT not found in state"
    site_user="$(state_get SITE_USER)" || die "SITE_USER not found in state"

    log_warn "This will OVERWRITE files in: ${web_root}"

    if ! confirm "Are you sure you want to restore these files?"; then
        log_info "Restore cancelled"
        return 1
    fi

    log_info "Restoring files to: ${web_root}"

    tar xzf "$file" -C "$(dirname "$web_root")"

    chown -R "${site_user}:${site_user}" "$web_root"

    log_success "Files restored successfully from: $(basename "$file")"
    log_info "Note: DB must be restored separately with 'az-wp db restore'"
}

# ---------------------------------------------------------------------------
# list_backups — Show available backups with sizes
# ---------------------------------------------------------------------------
list_backups() {
    backup_init

    local found=false

    local files
    files="$(ls -lhS "$BACKUP_DIR"/*.sql.gz "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" || true

    if [[ -n "$files" ]]; then
        found=true
        log_info "Available backups in ${BACKUP_DIR}:"
        echo "$files"
        echo ""
    fi

    if ! $found; then
        log_info "No backups found in ${BACKUP_DIR}"
        return 0
    fi

    local total_size
    total_size="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    log_info "Total backup size: ${total_size}"

    local disk_free
    disk_free="$(df -h / 2>/dev/null | tail -1 | awk '{print $4}')"
    log_info "Disk free: ${disk_free}"
}

# ---------------------------------------------------------------------------
# cleanup_old_backups — Delete backups older than retention period
# ---------------------------------------------------------------------------
cleanup_old_backups() {
    log_info "Cleaning up backups older than ${BACKUP_RETENTION_DAYS} days..."

    local deleted=0
    local freed=0

    while IFS= read -r -d '' file; do
        local size
        size="$(stat -c%s "$file" 2>/dev/null || echo 0)"
        log_info "  Deleted: $(basename "$file") ($(format_size "$size"))"
        rm -f "$file"
        deleted=$(( deleted + 1 ))
        freed=$(( freed + size ))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.gz" -type f -mtime +"$BACKUP_RETENTION_DAYS" -print0 2>/dev/null)

    if [[ "$deleted" -gt 0 ]]; then
        log_success "Removed ${deleted} old file(s), freed $(format_size "$freed")"
    else
        log_info "No old backups to clean up"
    fi
}

# ---------------------------------------------------------------------------
# schedule_backup — Set up cron job for automated backups
# ---------------------------------------------------------------------------
schedule_backup() {
    local frequency="${1:-daily}"
    local cron_file="/etc/cron.d/az-wp-backup"
    local cron_schedule

    case "$frequency" in
        daily)
            cron_schedule="0 3 * * *"
            ;;
        weekly)
            cron_schedule="0 3 * * 0"
            ;;
        *)
            die "Invalid frequency: ${frequency}. Use 'daily' or 'weekly'"
            ;;
    esac

    mkdir -p /var/log/az-wp

    cat > "$cron_file" <<EOF
# az-wp automated backup — ${frequency} at 3:00 AM
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${cron_schedule} root /usr/local/bin/az-wp backup full >> /var/log/az-wp/backup.log 2>&1
EOF

    chmod 644 "$cron_file"
    log_success "Backup scheduled: ${frequency} at 3:00 AM"
    log_info "Cron file: ${cron_file}"
    log_info "Log file: /var/log/az-wp/backup.log"
}
