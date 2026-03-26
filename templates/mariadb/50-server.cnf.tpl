[mysqld]
# === Buffer Pool ===
innodb_buffer_pool_size = ${TUNE_INNODB_BUFFER_POOL}
innodb_buffer_pool_instances = ${TUNE_INNODB_POOL_INSTANCES}
innodb_log_file_size = ${TUNE_INNODB_LOG_FILE_SIZE}
innodb_log_buffer_size = ${TUNE_INNODB_LOG_BUFFER}
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT

# === Connections ===
max_connections = ${TUNE_MARIADB_MAX_CONNECTIONS}
max_allowed_packet = 256M
thread_cache_size = ${TUNE_MARIADB_THREAD_CACHE}
wait_timeout = 300
interactive_timeout = 300

# === Performance ===
skip-name-resolve
innodb_io_capacity = ${TUNE_INNODB_IO_CAPACITY}
innodb_io_capacity_max = ${TUNE_INNODB_IO_CAPACITY_MAX}
innodb_read_io_threads = ${TUNE_INNODB_IO_THREADS}
innodb_write_io_threads = ${TUNE_INNODB_IO_THREADS}

# === Temp tables ===
tmp_table_size = ${TUNE_MARIADB_TMP_TABLE}
max_heap_table_size = ${TUNE_MARIADB_TMP_TABLE}
table_open_cache = ${TUNE_MARIADB_TABLE_CACHE}
table_definition_cache = ${TUNE_MARIADB_TABLE_DEF_CACHE}

# === Character set ===
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# === Logging ===
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# === Socket ===
socket = /run/mysqld/mysqld.sock
