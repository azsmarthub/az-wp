[mysqld]
# === Buffer Pool ===
innodb_buffer_pool_size = ${TUNE_INNODB_BUFFER_POOL}
innodb_log_file_size = ${TUNE_INNODB_LOG_FILE_SIZE}
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT

# === Connections ===
max_connections = ${TUNE_MARIADB_MAX_CONNECTIONS}
max_allowed_packet = 256M
thread_cache_size = 50
wait_timeout = 300
interactive_timeout = 300

# === Performance ===
skip-name-resolve
innodb_io_capacity = 1000
innodb_io_capacity_max = 2000
innodb_read_io_threads = 4
innodb_write_io_threads = 4

# === Temp tables ===
tmp_table_size = 64M
max_heap_table_size = 64M
table_open_cache = 2000
table_definition_cache = 1000

# === Character set ===
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# === Logging ===
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# === Socket ===
socket = /run/mysqld/mysqld.sock
