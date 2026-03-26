#!/usr/bin/env bash
# mariadb.sh — Install and configure MariaDB
[[ -n "${_AZ_MARIADB_LOADED:-}" ]] && return 0
_AZ_MARIADB_LOADED=1

# ---------------------------------------------------------------------------
# Install MariaDB 10.11 LTS from official repo
# ---------------------------------------------------------------------------
install_mariadb() {
    log_sub "Adding MariaDB 10.11 official repo..."
    curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp \
        | gpg --dearmor --yes -o /usr/share/keyrings/mariadb-keyring.gpg 2>/dev/null

    local codename
    codename="$(lsb_release -cs)"
    printf 'deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/10.11/repo/ubuntu %s main\n' \
        "$codename" > /etc/apt/sources.list.d/mariadb.list

    log_sub "Installing MariaDB server + client..."
    apt_wait; apt-get update -qq 2>/dev/null
    apt_install mariadb-server mariadb-client

    systemctl enable mariadb 2>/dev/null

    log_sub "MariaDB $(mysql --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1) installed"
}

# ---------------------------------------------------------------------------
# Secure MariaDB (equivalent to mysql_secure_installation)
# ---------------------------------------------------------------------------
secure_mariadb() {
    log_sub "Securing MariaDB..."

    # Remove anonymous users
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    # Remove remote root
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    # Remove test database
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    # Apply
    mysql -e "FLUSH PRIVILEGES;"

    log_sub "MariaDB secured"
}

# ---------------------------------------------------------------------------
# Configure MariaDB server settings
# ---------------------------------------------------------------------------
configure_mariadb() {
    log_sub "Configuring MariaDB..."

    export TUNE_INNODB_BUFFER_POOL TUNE_INNODB_LOG_FILE_SIZE TUNE_MARIADB_MAX_CONNECTIONS
    export TUNE_INNODB_POOL_INSTANCES TUNE_INNODB_LOG_BUFFER
    export TUNE_INNODB_IO_CAPACITY TUNE_INNODB_IO_CAPACITY_MAX TUNE_INNODB_IO_THREADS
    export TUNE_MARIADB_THREAD_CACHE TUNE_MARIADB_TMP_TABLE
    export TUNE_MARIADB_TABLE_CACHE TUNE_MARIADB_TABLE_DEF_CACHE

    render_template \
        "${AZ_DIR}/templates/mariadb/50-server.cnf.tpl" \
        /etc/mysql/mariadb.conf.d/50-server.cnf \
        "TUNE_INNODB_BUFFER_POOL TUNE_INNODB_POOL_INSTANCES TUNE_INNODB_LOG_FILE_SIZE TUNE_INNODB_LOG_BUFFER TUNE_MARIADB_MAX_CONNECTIONS TUNE_MARIADB_THREAD_CACHE TUNE_INNODB_IO_CAPACITY TUNE_INNODB_IO_CAPACITY_MAX TUNE_INNODB_IO_THREADS TUNE_MARIADB_TMP_TABLE TUNE_MARIADB_TABLE_CACHE TUNE_MARIADB_TABLE_DEF_CACHE"

    log_sub "MariaDB configured (InnoDB=${TUNE_INNODB_BUFFER_POOL}, pool=${TUNE_INNODB_POOL_INSTANCES}, io=${TUNE_INNODB_IO_CAPACITY}, tmp=${TUNE_MARIADB_TMP_TABLE})"
}

# ---------------------------------------------------------------------------
# Create WordPress database and user
# ---------------------------------------------------------------------------
create_database() {
    local db_name db_user db_pass

    db_name="$(state_get DB_NAME)" || die "DB_NAME not found in state file"
    db_user="$(state_get DB_USER)" || die "DB_USER not found in state file"
    db_pass="$(state_get DB_PASS)" || die "DB_PASS not found in state file"

    log_sub "Creating database '${db_name}' and user '${db_user}'..."

    mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    log_sub "Database '${db_name}' ready — user '${db_user}' granted all privileges"
}
