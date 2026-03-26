; azwp OPcache configuration

[opcache]
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${TUNE_OPCACHE_MEMORY}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.save_comments = 1
opcache.max_wasted_percentage = 10
opcache.huge_code_pages = 0

; JIT (PHP 8.1+)
; Buffer size 0 = JIT disabled
opcache.jit = tracing
opcache.jit_buffer_size = ${TUNE_JIT_BUFFER}
