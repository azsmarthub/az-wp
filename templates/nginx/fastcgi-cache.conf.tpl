# FastCGI Cache Zone
fastcgi_cache_path ${CACHE_PATH}
    levels=1:2
    keys_zone=WPCACHE:${TUNE_CACHE_KEYS_ZONE}
    max_size=${TUNE_CACHE_MAX_SIZE}
    inactive=365d
    use_temp_path=off;

fastcgi_cache_key "$scheme$request_method$host$request_uri";
