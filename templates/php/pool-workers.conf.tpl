[workers]
user = ${SITE_USER}
group = ${SITE_USER}

listen = /run/php/php${PHP_VERSION}-fpm-workers.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ${TUNE_PHP_PM}
pm.max_children = ${TUNE_WORKERS_MAX_CHILDREN}
pm.start_servers = ${TUNE_WORKERS_START_SERVERS}
pm.min_spare_servers = ${TUNE_WORKERS_MIN_SPARE}
pm.max_spare_servers = ${TUNE_WORKERS_MAX_SPARE}
pm.max_requests = 500
pm.process_idle_timeout = ${TUNE_WORKERS_PROCESS_IDLE_TIMEOUT}
request_terminate_timeout = 300

pm.status_path = /fpm-workers-status
