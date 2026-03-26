#!/usr/bin/env bash
# common.sh — Shared library for azwp
# Colors, logging, state management, template rendering, helpers

# Prevent double-source
[[ -n "${_AZ_COMMON_LOADED:-}" ]] && return 0
_AZ_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
AZ_STATE_DIR="/etc/azwp"
AZ_STATE_FILE="$AZ_STATE_DIR/install.state"
AZ_CONFIG_FILE="$AZ_STATE_DIR/config"
AZ_LOG_DIR="/var/log/azwp"
AZ_LOG_FILE="$AZ_LOG_DIR/install.log"

# AZ_DIR and AZ_VERSION are set by the caller before sourcing.

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------
az_init() {
    [[ ! -d "$AZ_STATE_DIR" ]] && mkdir -p "$AZ_STATE_DIR"
    [[ ! -d "$AZ_LOG_DIR" ]]   && mkdir -p "$AZ_LOG_DIR"

    # Set AZ_VERSION from VERSION file if not already set
    if [[ -z "${AZ_VERSION:-}" && -n "${AZ_DIR:-}" && -f "$AZ_DIR/VERSION" ]]; then
        AZ_VERSION="$(tr -d '[:space:]' < "$AZ_DIR/VERSION")"
    fi
    AZ_VERSION="${AZ_VERSION:-0.0.0}"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_to_file() {
    local msg="$1"
    if [[ -w "$AZ_LOG_FILE" || -w "$AZ_LOG_DIR" ]]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$AZ_LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    local msg="$1"
    local ts
    ts="$(date '+%H:%M:%S')"
    printf '[%s] %s\n' "$ts" "$msg"
    _log_to_file "[INFO] $msg"
}

log_warn() {
    local msg="$1"
    local ts
    ts="$(date '+%H:%M:%S')"
    printf "${YELLOW}[%s] [WARN] %s${NC}\n" "$ts" "$msg"
    _log_to_file "[WARN] $msg"
}

log_error() {
    local msg="$1"
    local ts
    ts="$(date '+%H:%M:%S')"
    printf "${RED}[%s] [ERROR] %s${NC}\n" "$ts" "$msg" >&2
    _log_to_file "[ERROR] $msg"
}

log_success() {
    local msg="$1"
    local ts
    ts="$(date '+%H:%M:%S')"
    printf "${GREEN}[%s] ✓ %s${NC}\n" "$ts" "$msg"
    _log_to_file "[OK] $msg"
}

log_sub() {
    local msg="$1"
    printf "       ${DIM}→ %s${NC}\n" "$msg"
    _log_to_file "[SUB] $msg"
}

log_step() {
    local current="$1"
    local total="$2"
    local description="$3"
    local status="$4"
    local elapsed="${5:-}"

    local pad_current
    pad_current="$(printf '%2d' "$current")"

    local elapsed_str=""
    if [[ -n "$elapsed" ]]; then
        elapsed_str=" (${elapsed}s)"
    fi

    local color="$NC"
    case "$status" in
        OK)   color="$GREEN" ;;
        SKIP) color="$DIM"   ;;
        FAIL) color="$RED"   ;;
    esac

    printf "[%s/%s] %-40s ${color}%s${NC}%s\n" \
        "$pad_current" "$total" "$description" "$status" "$elapsed_str"
    _log_to_file "STEP ${current}/${total} ${description} → ${status}${elapsed_str}"
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
die() {
    log_error "$1"
    exit 1
}

trap_error() {
    local lineno="$1"
    local command="$2"
    log_error "Command failed at line ${lineno}: ${command}"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ---------------------------------------------------------------------------
# User interaction
# ---------------------------------------------------------------------------
confirm() {
    local prompt="${1:-Continue?}"
    local answer
    # Auto-accept if no terminal (non-interactive / SSH pipe)
    if [[ ! -t 0 ]]; then
        return 0
    fi
    printf "${BOLD}%s [y/N]: ${NC}" "$prompt"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Password generation
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-24}"
    openssl rand -base64 48 | tr -d '/+=' | cut -c1-"$length"
}

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------
state_get() {
    local key="$1"
    if [[ ! -f "$AZ_STATE_FILE" ]]; then
        return 1
    fi
    local line
    line="$(grep -m1 "^${key}=" "$AZ_STATE_FILE" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

state_set() {
    local key="$1"
    local value="$2"
    if [[ ! -f "$AZ_STATE_FILE" ]]; then
        mkdir -p "$(dirname "$AZ_STATE_FILE")"
        printf '%s=%s\n' "$key" "$value" > "$AZ_STATE_FILE"
        return 0
    fi
    if grep -q "^${key}=" "$AZ_STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$AZ_STATE_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$AZ_STATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Step tracking
# ---------------------------------------------------------------------------
step_done() {
    local step_name="$1"
    local val
    val="$(state_get "STEP_${step_name}")" || return 1
    [[ "$val" == "done" ]]
}

step_mark() {
    local step_name="$1"
    state_set "STEP_${step_name}" "done"
}

# ---------------------------------------------------------------------------
# Config file helpers
# ---------------------------------------------------------------------------
config_get() {
    local key="$1"
    if [[ ! -f "$AZ_CONFIG_FILE" ]]; then
        return 1
    fi
    local line
    line="$(grep -m1 "^${key}=" "$AZ_CONFIG_FILE" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

config_set() {
    local key="$1"
    local value="$2"
    if [[ ! -f "$AZ_CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$AZ_CONFIG_FILE")"
        printf '%s=%s\n' "$key" "$value" > "$AZ_CONFIG_FILE"
        return 0
    fi
    if grep -q "^${key}=" "$AZ_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$AZ_CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$AZ_CONFIG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Format helpers (pure bash — no bc)
# ---------------------------------------------------------------------------
format_size() {
    local bytes="${1:-0}"

    if [[ "$bytes" -ge 1073741824 ]]; then
        local gb_int=$(( bytes / 1073741824 ))
        local gb_frac=$(( (bytes % 1073741824) * 10 / 1073741824 ))
        printf '%d.%d GB' "$gb_int" "$gb_frac"
    elif [[ "$bytes" -ge 1048576 ]]; then
        local mb_int=$(( bytes / 1048576 ))
        local mb_frac=$(( (bytes % 1048576) * 10 / 1048576 ))
        printf '%d.%d MB' "$mb_int" "$mb_frac"
    elif [[ "$bytes" -ge 1024 ]]; then
        local kb_int=$(( bytes / 1024 ))
        local kb_frac=$(( (bytes % 1024) * 10 / 1024 ))
        printf '%d.%d KB' "$kb_int" "$kb_frac"
    else
        printf '%d B' "$bytes"
    fi
}

# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------
render_template() {
    local template_path="$1"
    local dest_path="$2"
    local var_list="$3"

    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        return 1
    fi

    # Build envsubst format string: "$VAR1 $VAR2 $VAR3"
    local format_str=""
    local var
    for var in $var_list; do
        format_str="${format_str}\${${var}} "
    done
    # Trim trailing space
    format_str="${format_str% }"

    envsubst "$format_str" < "$template_path" > "$dest_path"
    log_info "Rendered template: $(basename "$template_path") → $dest_path"
}

# ---------------------------------------------------------------------------
# Wait for apt lock (Ubuntu auto-updates may hold lock on fresh VPS)
# ---------------------------------------------------------------------------
apt_wait() {
    local max_wait=120
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [[ $waited -eq 0 ]]; then
            log_sub "Waiting for apt lock (another process is updating)..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            log_warn "apt lock timeout after ${max_wait}s — proceeding anyway"
            break
        fi
    done
}

# Wrapper: wait for lock then run apt-get
apt_install() {
    apt_wait
    NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------
service_reload() {
    local name="$1"
    if systemctl reload "$name" 2>/dev/null; then
        log_info "Reloaded service: $name"
    else
        log_error "Failed to reload service: $name"
        return 1
    fi
}

service_restart() {
    local name="$1"
    if systemctl restart "$name" 2>/dev/null; then
        log_info "Restarted service: $name"
    else
        log_error "Failed to restart service: $name"
        return 1
    fi
}
