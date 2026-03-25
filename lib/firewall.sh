#!/usr/bin/env bash
# firewall.sh — UFW + Fail2Ban setup
[[ -n "${_AZ_FIREWALL_LOADED:-}" ]] && return 0
_AZ_FIREWALL_LOADED=1

# ---------------------------------------------------------------------------
# UFW Firewall
# ---------------------------------------------------------------------------
setup_ufw() {
    apt-get install -y -q ufw 2>&1 | grep -E "^(Setting up)" | tail -3 || true

    local ssh_port
    ssh_port="$(state_get SSH_PORT)" || ssh_port="22"

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable

    log_sub "UFW enabled (ports: SSH=${ssh_port}, 80, 443)"
}

# ---------------------------------------------------------------------------
# Fail2Ban
# ---------------------------------------------------------------------------
setup_fail2ban() {
    apt-get install -y -q fail2ban 2>&1 | grep -E "^(Setting up)" | tail -3 || true

    local ssh_port
    ssh_port="$(state_get SSH_PORT)" || ssh_port="22"

    export SSH_PORT="${ssh_port}"

    render_template \
        "${AZ_DIR}/templates/security/jail.local.tpl" \
        /etc/fail2ban/jail.local \
        "SSH_PORT"

    cp "${AZ_DIR}/templates/security/wordpress-filter.tpl" \
        /etc/fail2ban/filter.d/wordpress-login.conf

    systemctl enable fail2ban
    systemctl restart fail2ban

    log_sub "Fail2Ban configured"
}
