#!/usr/bin/env bash
# php.sh — Install and configure PHP-FPM
[[ -n "${_AZ_PHP_LOADED:-}" ]] && return 0
_AZ_PHP_LOADED=1

# ---------------------------------------------------------------------------
# Install PHP-FPM + extensions
# ---------------------------------------------------------------------------
install_php() {
    log_sub "Adding Ondrej PHP PPA..."
    add-apt-repository ppa:ondrej/php -y 2>&1 | grep -E "^(Adding|More info)" | head -2
    apt-get update -qq 2>/dev/null

    log_sub "Installing PHP ${PHP_VERSION} + 16 extensions (this may take 1-2 minutes)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-fileinfo" \
        "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-mysqli" \
        "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-intl" \
        "php${PHP_VERSION}-imagick" \
        "php${PHP_VERSION}-exif" \
        "php${PHP_VERSION}-iconv" \
        "php${PHP_VERSION}-soap" \
        "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-redis" \
        "php${PHP_VERSION}-igbinary" \
        > /dev/null 2>&1

    systemctl enable "php${PHP_VERSION}-fpm" 2>/dev/null

    mkdir -p /var/log/php
    chown www-data:www-data /var/log/php

    log_sub "PHP $(php -v 2>/dev/null | head -1 | grep -oP 'PHP \K[0-9.]+') installed with all extensions"
}

# ---------------------------------------------------------------------------
# Configure php.ini overrides
# ---------------------------------------------------------------------------
configure_php_ini() {
    log_sub "Configuring PHP ini settings..."

    export TUNE_PHP_MEMORY_LIMIT WEB_ROOT

    render_template \
        "${AZ_DIR}/templates/php/php.ini.tpl" \
        "/etc/php/${PHP_VERSION}/fpm/conf.d/99-az-wp.ini" \
        "TUNE_PHP_MEMORY_LIMIT WEB_ROOT"

    log_sub "PHP ini configured (memory_limit=${TUNE_PHP_MEMORY_LIMIT})"
}

# ---------------------------------------------------------------------------
# Configure OPcache + JIT
# ---------------------------------------------------------------------------
configure_opcache() {
    log_sub "Configuring OPcache..."

    export TUNE_OPCACHE_MEMORY TUNE_JIT_BUFFER

    render_template \
        "${AZ_DIR}/templates/php/opcache.ini.tpl" \
        "/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache-az.ini" \
        "TUNE_OPCACHE_MEMORY TUNE_JIT_BUFFER"

    log_sub "OPcache configured (memory=${TUNE_OPCACHE_MEMORY}MB, JIT=${TUNE_JIT_BUFFER})"
}

# ---------------------------------------------------------------------------
# Configure FPM pools (web + optional workers)
# ---------------------------------------------------------------------------
configure_fpm_pools() {
    log_sub "Configuring PHP-FPM pools..."

    # Remove default pool
    rm -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

    # Export web pool variables
    export SITE_USER PHP_VERSION
    export TUNE_PHP_PM TUNE_WEB_MAX_CHILDREN TUNE_WEB_START_SERVERS
    export TUNE_WEB_MIN_SPARE TUNE_WEB_MAX_SPARE TUNE_WEB_PROCESS_IDLE_TIMEOUT

    render_template \
        "${AZ_DIR}/templates/php/pool-web.conf.tpl" \
        "/etc/php/${PHP_VERSION}/fpm/pool.d/web.conf" \
        "SITE_USER PHP_VERSION TUNE_PHP_PM TUNE_WEB_MAX_CHILDREN TUNE_WEB_START_SERVERS TUNE_WEB_MIN_SPARE TUNE_WEB_MAX_SPARE TUNE_WEB_PROCESS_IDLE_TIMEOUT"

    log_success "Web pool configured (pm=${TUNE_PHP_PM}, max_children=${TUNE_WEB_MAX_CHILDREN})"

    # Workers pool (optional)
    if [[ "$TUNE_WORKERS_ENABLED" == "true" ]]; then
        export TUNE_WORKERS_MAX_CHILDREN TUNE_WORKERS_START_SERVERS
        export TUNE_WORKERS_MIN_SPARE TUNE_WORKERS_MAX_SPARE TUNE_WORKERS_PROCESS_IDLE_TIMEOUT

        render_template \
            "${AZ_DIR}/templates/php/pool-workers.conf.tpl" \
            "/etc/php/${PHP_VERSION}/fpm/pool.d/workers.conf" \
            "SITE_USER PHP_VERSION TUNE_PHP_PM TUNE_WORKERS_MAX_CHILDREN TUNE_WORKERS_START_SERVERS TUNE_WORKERS_MIN_SPARE TUNE_WORKERS_MAX_SPARE TUNE_WORKERS_PROCESS_IDLE_TIMEOUT"

        log_success "Workers pool configured (max_children=${TUNE_WORKERS_MAX_CHILDREN})"
    else
        # Remove workers pool config if it exists from a previous run
        rm -f "/etc/php/${PHP_VERSION}/fpm/pool.d/workers.conf"
        log_info "Workers pool disabled — single pool mode"
    fi

    # CLI config: no restrictions
    echo -e "[PHP]\ndisable_functions =\nopen_basedir =" \
        > "/etc/php/${PHP_VERSION}/cli/conf.d/99-az-wp-cli.ini"

    log_info "CLI config: no disable_functions, no open_basedir"
}

# ---------------------------------------------------------------------------
# Test PHP-FPM configuration
# ---------------------------------------------------------------------------
test_php_fpm() {
    "php-fpm${PHP_VERSION}" -t 2>&1
    return $?
}
