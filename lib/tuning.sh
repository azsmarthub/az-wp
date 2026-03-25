#!/usr/bin/env bash
# tuning.sh — Auto-tune all configs based on RAM
[[ -n "${_AZ_TUNING_LOADED:-}" ]] && return 0
_AZ_TUNING_LOADED=1

# ---------------------------------------------------------------------------
# Helper: max of two integers
# ---------------------------------------------------------------------------
_az_max() {
    local a="$1"
    local b="$2"
    if [[ "$a" -gt "$b" ]]; then
        printf '%d' "$a"
    else
        printf '%d' "$b"
    fi
}

# ---------------------------------------------------------------------------
# Main tuning calculation
# ---------------------------------------------------------------------------
calculate_tune() {
    # Requires globals: TOTAL_RAM_MB, CPU_CORES, DISK_FREE_GB, RAM_TIER

    case "$RAM_TIER" in
        512m)
            TUNE_SWAP_SIZE=1024
            TUNE_PHP_PM="ondemand"
            TUNE_WEB_MAX_CHILDREN=3
            TUNE_WORKERS_ENABLED="false"
            TUNE_WORKERS_MAX_CHILDREN=0
            TUNE_PHP_MEMORY_LIMIT="128M"
            TUNE_OPCACHE_MEMORY=64
            TUNE_JIT_BUFFER=0
            TUNE_INNODB_BUFFER_POOL="128M"
            TUNE_INNODB_LOG_FILE_SIZE="32M"
            TUNE_REDIS_MAXMEM="32mb"
            TUNE_NGINX_WORKERS=1
            TUNE_NGINX_RLIMIT_NOFILE=8192
            TUNE_NGINX_WORKER_CONNECTIONS=1024
            TUNE_MARIADB_MAX_CONNECTIONS=50
            ;;
        1g)
            TUNE_SWAP_SIZE=1024
            TUNE_PHP_PM="ondemand"
            TUNE_WEB_MAX_CHILDREN=4
            TUNE_WORKERS_ENABLED="true"
            TUNE_WORKERS_MAX_CHILDREN=2
            TUNE_PHP_MEMORY_LIMIT="192M"
            TUNE_OPCACHE_MEMORY=96
            TUNE_JIT_BUFFER=0
            TUNE_INNODB_BUFFER_POOL="320M"
            TUNE_INNODB_LOG_FILE_SIZE="80M"
            TUNE_REDIS_MAXMEM="64mb"
            TUNE_NGINX_WORKERS=1
            TUNE_NGINX_RLIMIT_NOFILE=8192
            TUNE_NGINX_WORKER_CONNECTIONS=1024
            TUNE_MARIADB_MAX_CONNECTIONS=75
            ;;
        2g)
            TUNE_SWAP_SIZE=1024
            TUNE_PHP_PM="dynamic"
            TUNE_WEB_MAX_CHILDREN=8
            TUNE_WORKERS_ENABLED="true"
            TUNE_WORKERS_MAX_CHILDREN=4
            TUNE_PHP_MEMORY_LIMIT="256M"
            TUNE_OPCACHE_MEMORY=128
            TUNE_JIT_BUFFER="32M"
            TUNE_INNODB_BUFFER_POOL="768M"
            TUNE_INNODB_LOG_FILE_SIZE="192M"
            TUNE_REDIS_MAXMEM="128mb"
            TUNE_NGINX_WORKERS=2
            TUNE_NGINX_RLIMIT_NOFILE=16384
            TUNE_NGINX_WORKER_CONNECTIONS=2048
            TUNE_MARIADB_MAX_CONNECTIONS=100
            ;;
        4g)
            TUNE_SWAP_SIZE=2048
            TUNE_PHP_PM="dynamic"
            TUNE_WEB_MAX_CHILDREN=18
            TUNE_WORKERS_ENABLED="true"
            TUNE_WORKERS_MAX_CHILDREN=7
            TUNE_PHP_MEMORY_LIMIT="512M"
            TUNE_OPCACHE_MEMORY=192
            TUNE_JIT_BUFFER="64M"
            TUNE_INNODB_BUFFER_POOL="1536M"
            TUNE_INNODB_LOG_FILE_SIZE="384M"
            TUNE_REDIS_MAXMEM="256mb"
            TUNE_NGINX_WORKERS="auto"
            TUNE_NGINX_RLIMIT_NOFILE=32768
            TUNE_NGINX_WORKER_CONNECTIONS=4096
            TUNE_MARIADB_MAX_CONNECTIONS=150
            ;;
        8g|*)
            TUNE_SWAP_SIZE=2048
            TUNE_PHP_PM="dynamic"
            TUNE_WEB_MAX_CHILDREN=35
            TUNE_WORKERS_ENABLED="true"
            TUNE_WORKERS_MAX_CHILDREN=15
            TUNE_PHP_MEMORY_LIMIT="512M"
            TUNE_OPCACHE_MEMORY=256
            TUNE_JIT_BUFFER="128M"
            TUNE_INNODB_BUFFER_POOL="3072M"
            TUNE_INNODB_LOG_FILE_SIZE="768M"
            TUNE_REDIS_MAXMEM="512mb"
            TUNE_NGINX_WORKERS="auto"
            TUNE_NGINX_RLIMIT_NOFILE=65535
            TUNE_NGINX_WORKER_CONNECTIONS=4096
            TUNE_MARIADB_MAX_CONNECTIONS=200
            ;;
    esac

    # Derived values for dynamic PM
    if [[ "$TUNE_PHP_PM" == "dynamic" ]]; then
        TUNE_WEB_START_SERVERS="$(_az_max 1 $(( TUNE_WEB_MAX_CHILDREN / 4 )))"
        TUNE_WEB_MIN_SPARE="$(_az_max 1 $(( TUNE_WEB_MAX_CHILDREN / 4 )))"
        TUNE_WEB_MAX_SPARE="$(_az_max 2 $(( TUNE_WEB_MAX_CHILDREN / 2 )))"
        TUNE_WEB_PROCESS_IDLE_TIMEOUT="10s"
    else
        # ondemand mode — still set values for template compatibility
        TUNE_WEB_START_SERVERS=1
        TUNE_WEB_MIN_SPARE=1
        TUNE_WEB_MAX_SPARE=2
        TUNE_WEB_PROCESS_IDLE_TIMEOUT="10s"
    fi

    # Worker pool derived values
    if [[ "$TUNE_WORKERS_ENABLED" == "true" ]]; then
        TUNE_WORKERS_START_SERVERS="$(_az_max 1 $(( TUNE_WORKERS_MAX_CHILDREN / 4 )))"
        TUNE_WORKERS_MIN_SPARE=1
        TUNE_WORKERS_MAX_SPARE="$(_az_max 1 $(( TUNE_WORKERS_MAX_CHILDREN / 2 )))"
        TUNE_WORKERS_PROCESS_IDLE_TIMEOUT="30s"
    else
        TUNE_WORKERS_START_SERVERS=0
        TUNE_WORKERS_MIN_SPARE=0
        TUNE_WORKERS_MAX_SPARE=0
        TUNE_WORKERS_PROCESS_IDLE_TIMEOUT="30s"
    fi

    # FastCGI cache sizing based on disk
    local disk="${DISK_FREE_GB:-20}"
    if [[ "$disk" -lt 20 ]]; then
        TUNE_CACHE_KEYS_ZONE="64m"
        TUNE_CACHE_MAX_SIZE="2g"
    elif [[ "$disk" -lt 50 ]]; then
        TUNE_CACHE_KEYS_ZONE="128m"
        TUNE_CACHE_MAX_SIZE="5g"
    elif [[ "$disk" -lt 100 ]]; then
        TUNE_CACHE_KEYS_ZONE="256m"
        TUNE_CACHE_MAX_SIZE="10g"
    else
        TUNE_CACHE_KEYS_ZONE="256m"
        TUNE_CACHE_MAX_SIZE="20g"
    fi

    # Export all TUNE_* variables
    export TUNE_SWAP_SIZE TUNE_PHP_PM
    export TUNE_WEB_MAX_CHILDREN TUNE_WEB_START_SERVERS TUNE_WEB_MIN_SPARE
    export TUNE_WEB_MAX_SPARE TUNE_WEB_PROCESS_IDLE_TIMEOUT
    export TUNE_WORKERS_ENABLED TUNE_WORKERS_MAX_CHILDREN
    export TUNE_WORKERS_START_SERVERS TUNE_WORKERS_MIN_SPARE
    export TUNE_WORKERS_MAX_SPARE TUNE_WORKERS_PROCESS_IDLE_TIMEOUT
    export TUNE_PHP_MEMORY_LIMIT TUNE_OPCACHE_MEMORY TUNE_JIT_BUFFER
    export TUNE_INNODB_BUFFER_POOL TUNE_INNODB_LOG_FILE_SIZE
    export TUNE_REDIS_MAXMEM
    export TUNE_NGINX_WORKERS TUNE_NGINX_RLIMIT_NOFILE TUNE_NGINX_WORKER_CONNECTIONS
    export TUNE_MARIADB_MAX_CONNECTIONS
    export TUNE_CACHE_KEYS_ZONE TUNE_CACHE_MAX_SIZE
}

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------
print_tune_summary() {
    local jit_str
    if [[ "$TUNE_JIT_BUFFER" == "0" ]]; then
        jit_str="off"
    else
        jit_str="${TUNE_JIT_BUFFER}"
    fi

    local workers_str
    if [[ "$TUNE_WORKERS_ENABLED" == "true" ]]; then
        workers_str="${TUNE_WORKERS_MAX_CHILDREN}"
    else
        workers_str="off"
    fi

    printf "\n"
    printf "  ${CYAN}PHP %s${NC} | ${BOLD}%s tier${NC} | Web %s + Workers %s FPM slots\n" \
        "${PHP_VERSION:-8.4}" "$RAM_TIER" "$TUNE_WEB_MAX_CHILDREN" "$workers_str"
    printf "  InnoDB %s | Redis %s | OPcache %sMB | JIT %s\n" \
        "$TUNE_INNODB_BUFFER_POOL" "$TUNE_REDIS_MAXMEM" "$TUNE_OPCACHE_MEMORY" "$jit_str"
    printf "  Nginx workers %s | Cache zone %s / max %s\n" \
        "$TUNE_NGINX_WORKERS" "$TUNE_CACHE_KEYS_ZONE" "$TUNE_CACHE_MAX_SIZE"
    printf "\n"
}
