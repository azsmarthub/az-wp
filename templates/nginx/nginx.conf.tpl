user www-data;
worker_processes ${TUNE_NGINX_WORKERS};
pid /run/nginx.pid;
worker_rlimit_nofile ${TUNE_NGINX_RLIMIT_NOFILE};
error_log /var/log/nginx/error.log crit;

events {
    worker_connections ${TUNE_NGINX_WORKER_CONNECTIONS};
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 256m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_http_version 1.1;
    gzip_types
        text/plain text/css text/javascript text/xml text/cache-manifest
        text/vcard text/vnd.rim.location.xloc text/vtt text/x-component
        text/x-cross-domain-policy
        application/javascript application/json application/ld+json
        application/xml application/xhtml+xml application/rss+xml
        application/atom+xml application/manifest+json
        application/vnd.geo+json application/vnd.ms-fontobject
        application/x-font-ttf application/x-web-app-manifest+json
        font/opentype
        image/bmp image/svg+xml image/x-icon;

    # FastCGI settings
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=wp_login:10m rate=5r/m;
    limit_req_zone $binary_remote_addr zone=wp_xmlrpc:10m rate=1r/m;

    # Include cache zone config
    include /etc/nginx/conf.d/*.conf;

    # Include site configs
    include /etc/nginx/sites-enabled/*;
}
