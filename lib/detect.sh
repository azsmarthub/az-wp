#!/usr/bin/env bash
# detect.sh — OS, hardware detection, pre-flight checks
[[ -n "${_AZ_DETECT_LOADED:-}" ]] && return 0
_AZ_DETECT_LOADED=1

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-unknown}"

    if [[ "$OS_ID" != "ubuntu" ]]; then
        die "Unsupported OS: $OS_ID. Only Ubuntu is supported."
    fi

    if [[ "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
        die "Unsupported Ubuntu version: $OS_VERSION. Supported: 22.04, 24.04."
    fi
}

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------
detect_hardware() {
    TOTAL_RAM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
    CPU_CORES="$(nproc)"
    DISK_FREE_GB="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"

    # Determine RAM tier
    if [[ "$TOTAL_RAM_MB" -le 768 ]]; then
        RAM_TIER="512m"
    elif [[ "$TOTAL_RAM_MB" -le 1536 ]]; then
        RAM_TIER="1g"
    elif [[ "$TOTAL_RAM_MB" -le 3072 ]]; then
        RAM_TIER="2g"
    elif [[ "$TOTAL_RAM_MB" -le 6144 ]]; then
        RAM_TIER="4g"
    elif [[ "$TOTAL_RAM_MB" -le 12288 ]]; then
        RAM_TIER="8g"
    elif [[ "$TOTAL_RAM_MB" -le 24576 ]]; then
        RAM_TIER="16g"
    else
        RAM_TIER="32g"
    fi
}

# ---------------------------------------------------------------------------
# Public IP detection
# ---------------------------------------------------------------------------
detect_ip() {
    PUBLIC_IP=""

    # Try multiple sources
    PUBLIC_IP="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null)" && [[ -n "$PUBLIC_IP" ]] && return 0
    PUBLIC_IP="$(curl -sf --max-time 5 https://icanhazip.com 2>/dev/null)" && [[ -n "$PUBLIC_IP" ]] && return 0
    PUBLIC_IP="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null)" && [[ -n "$PUBLIC_IP" ]] && return 0

    # Fallback: default route source IP
    PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)" || true

    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "Could not detect public IP address."
        PUBLIC_IP="UNKNOWN"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    local failed=0

    # --- Root ---
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Running as root"
    else
        printf "  ${RED}%-6s${NC} %s\n" "FAIL" "Not running as root"
        failed=1
    fi

    # --- OS ---
    detect_os
    printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Ubuntu ${OS_VERSION} LTS (${OS_CODENAME})"

    # --- Hardware ---
    detect_hardware

    # RAM check
    if [[ "$TOTAL_RAM_MB" -ge 512 ]]; then
        printf "  ${GREEN}%-6s${NC} %s\n" "OK" "RAM: ${TOTAL_RAM_MB} MB"
    else
        printf "  ${RED}%-6s${NC} %s\n" "FAIL" "RAM: ${TOTAL_RAM_MB} MB (minimum 512 MB)"
        failed=1
    fi

    # Disk check
    if [[ "$DISK_FREE_GB" -ge 10 ]]; then
        printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Disk free: ${DISK_FREE_GB} GB"
    else
        printf "  ${RED}%-6s${NC} %s\n" "FAIL" "Disk free: ${DISK_FREE_GB} GB (minimum 10 GB)"
        failed=1
    fi

    # --- Clean VPS + Ports (skip when resuming a previous install) ---
    local is_resume=0
    [[ -f "$AZ_STATE_FILE" ]] && state_get DOMAIN &>/dev/null && is_resume=1

    if [[ "$is_resume" -eq 1 ]]; then
        printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Resuming previous install (skip clean/port checks)"
    else
        local svc
        local clean=1
        for svc in nginx apache2 mysql mariadb; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf "  ${RED}%-6s${NC} %s\n" "FAIL" "Service '$svc' is already active"
                clean=0
                failed=1
            fi
        done
        if [[ "$clean" -eq 1 ]]; then
            printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Clean VPS (no existing web/db services)"
        fi

        local port
        local ports_ok=1
        for port in 80 443; do
            if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
                printf "  ${RED}%-6s${NC} %s\n" "FAIL" "Port ${port} already in use"
                ports_ok=0
                failed=1
            fi
        done
        if [[ "$ports_ok" -eq 1 ]]; then
            printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Ports 80/443 available"
        fi
    fi

    # --- Internet ---
    if curl -sf --max-time 5 https://www.google.com > /dev/null 2>&1; then
        printf "  ${GREEN}%-6s${NC} %s\n" "OK" "Internet connectivity"
    else
        printf "  ${RED}%-6s${NC} %s\n" "FAIL" "No internet connectivity"
        failed=1
    fi

    return "$failed"
}
