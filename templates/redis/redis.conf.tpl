# azwp Redis configuration
# Pure cache mode — no persistence

# Network
bind 127.0.0.1
port 0

# Unix socket (faster than TCP for local)
unixsocket ${REDIS_SOCK}
unixsocketperm 770

# Memory
maxmemory ${TUNE_REDIS_MAXMEM}
maxmemory-policy allkeys-lru

# Disable persistence (pure cache)
save ""
appendonly no

# Logging
loglevel notice
logfile /var/log/redis/redis-server.log

# Security
protected-mode yes
