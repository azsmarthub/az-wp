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
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

    # Block sensitive files
    location = /wp-config.php { deny all; }
    location ~ /\.(env|git|svn|htaccess|htpasswd) { deny all; }
    location ~ /readme\.(html|txt)$ { deny all; }
    location ~ /license\.txt$ { deny all; }

    # Block user enumeration via REST API
    location ~ ^/wp-json/wp/v2/users {
        if ($arg_context != "edit") { return 403; }
        # Allow only authenticated edit context (WP admin needs this)
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
    }

    # Block author enumeration (?author=N)
    if ($args ~* "author=\d+") { return 403; }

    # === FastCGI Cache Logic ===
    set $skip_cache 0;

    if ($request_method = POST) { set $skip_cache 1; }
    if ($query_string != "") { set $skip_cache 1; }
    if ($request_uri ~* "/wp-admin/|/wp-json/|/xmlrpc.php|wp-.*.php|/feed/|/sitemap.*\.xml") {
        set $skip_cache 1;
    }
    if ($http_cookie ~* "wordpress_logged_in|comment_author|woocommerce_") {
        set $skip_cache 1;
    }

    # Optional: header-based cache bypass for programmatic purge
    if ($http_x_purge_cache = "azwp-purge-key") {
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
        fastcgi_cache off;
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
        fastcgi_cache off;
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
        fastcgi_param SCRIPT_FILENAME /fpm-status;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-web.sock;
    }

    location = /fpm-workers-status {
        access_log off;
        allow 127.0.0.1;
        deny all;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /fpm-workers-status;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-workers.sock;
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
        add_header X-FastCGI-Cache $upstream_cache_status always;

        # Browser + CDN caching for HTML pages
        # s-maxage=86400: Cloudflare edge caches 24h
        # max-age=600: browser caches 10min then revalidates
        add_header Cache-Control "public, s-maxage=86400, max-age=600" always;
        add_header X-Cache-Enabled "true" always;
        add_header Vary "Accept-Encoding" always;
        etag on;
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

    # Static assets - browser cache 1 year (CSS, JS, fonts, images)
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|avif|woff2|woff|ttf|eot|mp4|mp3|pdf)$ {
        expires 365d;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header Vary "Accept-Encoding" always;
        access_log off;
        etag on;

        # Enable gzip for text-based assets
        gzip_static on;
    }

    # WordPress uploaded media — cache but allow re-validation
    location ~* /wp-content/uploads/ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000" always;
        access_log off;
        etag on;
    }
}
