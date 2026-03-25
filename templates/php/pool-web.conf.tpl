[web]
user = ${SITE_USER}
group = ${SITE_USER}

listen = /run/php/php${PHP_VERSION}-fpm-web.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ${TUNE_PHP_PM}
pm.max_children = ${TUNE_WEB_MAX_CHILDREN}
pm.start_servers = ${TUNE_WEB_START_SERVERS}
pm.min_spare_servers = ${TUNE_WEB_MIN_SPARE}
pm.max_spare_servers = ${TUNE_WEB_MAX_SPARE}
pm.max_requests = 1000
pm.process_idle_timeout = ${TUNE_WEB_PROCESS_IDLE_TIMEOUT}
request_terminate_timeout = 60

pm.status_path = /fpm-status
