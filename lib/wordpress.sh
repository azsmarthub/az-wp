#!/usr/bin/env bash
# wordpress.sh — Install and configure WordPress via WP-CLI
[[ -n "${_AZ_WORDPRESS_LOADED:-}" ]] && return 0
_AZ_WORDPRESS_LOADED=1

# ---------------------------------------------------------------------------
# Helper: run WP-CLI as site user
# ---------------------------------------------------------------------------
wp_run() {
    sudo -u "$SITE_USER" wp "$@" --path="$WEB_ROOT"
}

# ---------------------------------------------------------------------------
# Install WP-CLI
# ---------------------------------------------------------------------------
install_wpcli() {
    log_sub "Installing WP-CLI..."

    curl -sfo /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        || die "Failed to download WP-CLI."

    chmod +x /tmp/wp-cli.phar
    mv /tmp/wp-cli.phar /usr/local/bin/wp

    # Verify (run as root, suppress errors)
    if wp --info >/dev/null 2>&1; then
        log_sub "WP-CLI installed: $(wp --version 2>/dev/null)"
    else
        die "WP-CLI verification failed."
    fi
}

# ---------------------------------------------------------------------------
# Install WordPress core
# ---------------------------------------------------------------------------
install_wordpress() {
    local db_name db_user db_pass wp_admin_user wp_admin_email wp_admin_pass
    local table_prefix

    db_name="$(state_get DB_NAME)"       || die "DB_NAME not found in state."
    db_user="$(state_get DB_USER)"       || die "DB_USER not found in state."
    db_pass="$(state_get DB_PASS)"       || die "DB_PASS not found in state."
    wp_admin_user="$(state_get WP_ADMIN_USER)"   || die "WP_ADMIN_USER not found in state."
    wp_admin_email="$(state_get WP_ADMIN_EMAIL)" || die "WP_ADMIN_EMAIL not found in state."
    wp_admin_pass="$(state_get WP_ADMIN_PASS)"   || die "WP_ADMIN_PASS not found in state."

    # Generate random table prefix
    table_prefix="wp_$(openssl rand -hex 3)_"
    state_set "TABLE_PREFIX" "$table_prefix"

    log_sub "Installing WordPress to $WEB_ROOT ..."

    # Download WordPress core
    log_sub "Downloading WordPress core..."
    sudo -u "$SITE_USER" wp core download \
        --path="$WEB_ROOT" \
        --locale=en_US \
        || die "Failed to download WordPress."

    # Create wp-config.php
    log_sub "Creating wp-config.php..."
    sudo -u "$SITE_USER" wp config create \
        --path="$WEB_ROOT" \
        --dbname="$db_name" \
        --dbuser="$db_user" \
        --dbpass="$db_pass" \
        --dbhost="localhost" \
        --dbprefix="$table_prefix" \
        --extra-php <<'EXTRAPHP'
/** Security: disable file editing in admin */
define('DISALLOW_FILE_EDIT', true);
EXTRAPHP
    [[ $? -ne 0 ]] && die "Failed to create wp-config.php."

    # Install WordPress
    log_sub "Running WordPress install..."
    sudo -u "$SITE_USER" wp core install \
        --path="$WEB_ROOT" \
        --url="http://${DOMAIN}" \
        --title="$DOMAIN" \
        --admin_user="$wp_admin_user" \
        --admin_password="$wp_admin_pass" \
        --admin_email="$wp_admin_email" \
        --skip-email \
        || die "WordPress core install failed."

    log_sub "WordPress installed at $WEB_ROOT"
}

# ---------------------------------------------------------------------------
# Configure WordPress extras (constants, Redis settings)
# ---------------------------------------------------------------------------
configure_wp_extras() {
    log_sub "Configuring WordPress constants..."

    # Core constants
    wp_run config set DISABLE_WP_CRON true --raw
    wp_run config set DISALLOW_FILE_EDIT true --raw
    wp_run config set WP_AUTO_UPDATE_CORE "'minor'"
    wp_run config set WP_DEBUG false --raw
    wp_run config set WP_DEBUG_LOG false --raw
    wp_run config set WP_DEBUG_DISPLAY false --raw

    # Redis Object Cache constants
    log_sub "Configuring Redis object cache constants..."
    wp_run config set WP_REDIS_SCHEME "'unix'"
    wp_run config set WP_REDIS_PATH "'${REDIS_SOCK}'"
    wp_run config set WP_REDIS_DATABASE 0 --raw
    wp_run config set WP_CACHE_KEY_SALT "'${DOMAIN}_'"

    log_sub "WordPress constants configured."
}

# ---------------------------------------------------------------------------
# Install and activate Redis Object Cache plugin
# ---------------------------------------------------------------------------
install_redis_plugin() {
    log_sub "Installing Redis Object Cache plugin..."

    wp_run plugin install redis-cache --activate \
        || die "Failed to install Redis Object Cache plugin."

    wp_run redis enable \
        || log_warn "Redis enable command failed. You may need to enable it manually."

    log_sub "Redis Object Cache enabled."
}

# ---------------------------------------------------------------------------
# Set correct file permissions
# ---------------------------------------------------------------------------
set_wp_permissions() {
    log_sub "Setting WordPress file permissions..."

    find "$WEB_ROOT" -type d -exec chmod 755 {} \;
    log_sub "Directories set to 755."

    find "$WEB_ROOT" -type f -exec chmod 644 {} \;
    log_sub "Files set to 644."

    chmod 640 "$WEB_ROOT/wp-config.php"
    log_sub "wp-config.php set to 640."

    chown -R "${SITE_USER}:${SITE_USER}" "$WEB_ROOT"
    log_sub "Ownership set to ${SITE_USER}:${SITE_USER}."

    log_sub "WordPress permissions configured."
}
