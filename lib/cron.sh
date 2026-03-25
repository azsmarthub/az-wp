#!/usr/bin/env bash
# cron.sh — System cron setup for WordPress
[[ -n "${_AZ_CRON_LOADED:-}" ]] && return 0
_AZ_CRON_LOADED=1

# ---------------------------------------------------------------------------
# Setup WordPress cron (every 30 seconds via CLI)
# ---------------------------------------------------------------------------
setup_wp_cron() {
    log_sub "Setting up WordPress system cron..."

    cat > /etc/cron.d/az-wp-cron <<CRON
# WordPress cron (every 30 seconds via CLI)
* * * * * ${SITE_USER} php ${WEB_ROOT}/wp-cron.php > /dev/null 2>&1
* * * * * ${SITE_USER} sleep 30 && php ${WEB_ROOT}/wp-cron.php > /dev/null 2>&1
CRON

    chmod 644 /etc/cron.d/az-wp-cron

    log_sub "WordPress cron configured (runs every 30s)."
}

# ---------------------------------------------------------------------------
# Setup logrotate
# ---------------------------------------------------------------------------
setup_logrotate() {
    log_sub "Setting up logrotate..."

    export AZ_LOG_DIR
    export PHP_VERSION

    render_template \
        "${AZ_DIR}/templates/logrotate/az-wp.tpl" \
        /etc/logrotate.d/az-wp \
        "AZ_LOG_DIR PHP_VERSION"

    chmod 644 /etc/logrotate.d/az-wp

    log_sub "Logrotate configured."
}
