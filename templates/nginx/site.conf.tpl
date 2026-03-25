server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    root ${WEB_ROOT};
    index index.php index.html;

    # ACME challenge
    location ^~ /.well-known/acme-challenge {
        allow all;
        root ${WEB_ROOT};
    }

    server_tokens off;
    client_max_body_size 256m;
    charset utf-8;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;

    # === FastCGI Cache Logic ===
    set $skip_cache 0;

    if ($request_method = POST) { set $skip_cache 1; }
    if ($query_string != "") { set $skip_cache 1; }
    if ($request_uri ~* "/wp-admin/|/wp-json/|/xmlrpc.php|wp-.*.php|/feed/") {
        set $skip_cache 1;
    }
    if ($http_cookie ~* "wordpress_logged_in|comment_author|woocommerce_") {
        set $skip_cache 1;
    }

    # Optional: header-based cache bypass for programmatic purge
    if ($http_x_purge_cache = "az-wp-purge-key") {
        set $skip_cache 1;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log /var/log/nginx/${DOMAIN}-error.log error;

    error_page 404 /index.php;

    # ==========================================================
    # WORKERS POOL ROUTING (only if dual pool enabled)
    # ==========================================================

    # Long-running worker endpoints → workers pool
    location ~ ^/wp-json/.+/v1/(cron|automation)/.*worker {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-workers.sock;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param HTTP_AUTHORIZATION $http_authorization;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_cache off;
    }

    # wp-cron → workers pool
    location = /wp-cron.php {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-workers.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    # Action Scheduler AJAX → workers pool
    location ~ ^/wp-admin/admin-ajax\.php$ {
        set $fpm_backend "unix:/run/php/php${PHP_VERSION}-fpm-web.sock";
        if ($arg_action ~* "action_scheduler|as_async_request") {
            set $fpm_backend "unix:/run/php/php${PHP_VERSION}-fpm-workers.sock";
        }
        include fastcgi_params;
        fastcgi_pass $fpm_backend;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_AUTHORIZATION $http_authorization;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # API dispatchers → web pool
    location /wp-json/ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param HTTP_AUTHORIZATION $http_authorization;
        fastcgi_read_timeout 60;
        fastcgi_cache off;
    }

    # FPM status pages (local only)
    location = /fpm-status {
        access_log off;
        allow 127.0.0.1;
        deny all;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    location = /fpm-workers-status {
        access_log off;
        allow 127.0.0.1;
        deny all;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-workers.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    # ==========================================================
    # MAIN PHP HANDLER
    # ==========================================================

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;

        # FastCGI Cache
        fastcgi_cache WPCACHE;
        fastcgi_cache_valid 200 301 302 1d;
        fastcgi_cache_valid 404 1m;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        fastcgi_cache_use_stale error timeout updating;
        fastcgi_cache_lock on;
        fastcgi_cache_lock_timeout 5s;
        add_header X-FastCGI-Cache $upstream_cache_status;
    }

    # Rate limit wp-login.php
    location = /wp-login.php {
        limit_req zone=wp_login burst=3 nodelay;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    # Block xmlrpc.php
    location = /xmlrpc.php {
        limit_req zone=wp_xmlrpc burst=2 nodelay;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }

    # Deny dotfiles except .well-known
    location ~ /\.(?!well-known).* {
        deny all;
    }

    # Static assets - browser cache 1 year
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|woff2|woff|ttf|eot|mp4|mp3|pdf)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
