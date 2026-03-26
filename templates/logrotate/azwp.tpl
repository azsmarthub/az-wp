${AZ_LOG_DIR}/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
}

/var/log/php/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data www-data
    postrotate
        /usr/lib/php/php-fpm-socket-helper reopen /run/php/php${PHP_VERSION}-fpm-web.sock 2>/dev/null || true
    endscript
}
