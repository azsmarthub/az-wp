#!/usr/bin/env bash
# security.sh — SSH hardening, unattended-upgrades, WP hardening
[[ -n "${_AZ_SECURITY_LOADED:-}" ]] && return 0
_AZ_SECURITY_LOADED=1

# ---------------------------------------------------------------------------
# SSH Hardening
# ---------------------------------------------------------------------------
harden_ssh() {
    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "${sshd_config}.bak" ]]; then
        cp "$sshd_config" "${sshd_config}.bak"
        log_sub "Backed up sshd_config"
    fi

    # Do NOT disable root login automatically — the site user has no
    # sudo access and no SSH password. Disabling root would lock out
    # the only way to manage the server. Users can disable root login
    # manually via 'azwp security' after setting up SSH keys.
    # sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$sshd_config"
    log_sub "PermitRootLogin: kept as-is (disable manually after setting up SSH keys)"

    sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 5/' "$sshd_config"
    sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$sshd_config"

    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

    log_sub "SSH hardened"
}

# ---------------------------------------------------------------------------
# Unattended Upgrades
# ---------------------------------------------------------------------------
setup_unattended_upgrades() {
    apt_install unattended-upgrades

    local conf="/etc/apt/apt.conf.d/20auto-upgrades"

    printf '%s\n' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' \
        > "$conf"

    log_sub "Unattended security upgrades enabled"
}

# ---------------------------------------------------------------------------
# System Limits
# ---------------------------------------------------------------------------
setup_system_limits() {
    local limits_file="/etc/security/limits.conf"
    local entry

    for entry in \
        "www-data soft nofile 65535" \
        "www-data hard nofile 65535" \
        "${SITE_USER} soft nofile 65535" \
        "${SITE_USER} hard nofile 65535"; do

        if ! grep -qF "$entry" "$limits_file" 2>/dev/null; then
            printf '%s\n' "$entry" >> "$limits_file"
        fi
    done

    log_sub "System limits configured"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------
harden_all() {
    harden_ssh
    setup_unattended_upgrades
    setup_system_limits
}
