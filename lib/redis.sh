#!/usr/bin/env bash
# redis.sh — Install and configure Redis
[[ -n "${_AZ_REDIS_LOADED:-}" ]] && return 0
_AZ_REDIS_LOADED=1

# ---------------------------------------------------------------------------
# Install Redis
# ---------------------------------------------------------------------------
install_redis() {
    log_sub "Installing Redis..."

    apt-get install -y -q redis-server 2>&1 | grep -E "^(Setting up)" | tail -3

    systemctl enable redis-server

    log_sub "Redis installed"
}

# ---------------------------------------------------------------------------
# Configure Redis (unix socket, no persistence, memory limit)
# ---------------------------------------------------------------------------
configure_redis() {
    log_sub "Configuring Redis..."

    export TUNE_REDIS_MAXMEM REDIS_SOCK

    render_template \
        "${AZ_DIR}/templates/redis/redis.conf.tpl" \
        /etc/redis/redis.conf \
        "TUNE_REDIS_MAXMEM REDIS_SOCK"

    # Allow site user and www-data to access the socket
    usermod -aG redis "$SITE_USER"
    usermod -aG redis www-data

    # Ensure socket directory exists with correct permissions
    local sock_dir
    sock_dir="$(dirname "$REDIS_SOCK")"
    mkdir -p "$sock_dir"
    chown redis:redis "$sock_dir"
    chmod 755 "$sock_dir"

    log_sub "Redis configured (maxmemory=${TUNE_REDIS_MAXMEM}, socket=${REDIS_SOCK})"
}

# ---------------------------------------------------------------------------
# Test Redis connectivity via unix socket
# ---------------------------------------------------------------------------
test_redis() {
    local response
    response="$(redis-cli -s "$REDIS_SOCK" ping 2>&1)"

    if [[ "$response" == "PONG" ]]; then
        log_success "Redis is responding on ${REDIS_SOCK}"
        return 0
    else
        log_error "Redis ping failed: ${response}"
        return 1
    fi
}
