azwp-multi — Multisite WordPress Hosting Scripts
Nhân bản dự án azwp-single thành azwp-multi — hệ thống quản lý nhiều website WordPress trên cùng một VPS. Tách biệt hoàn toàn với bản single, không can thiệp code cũ.

User Review Required
IMPORTANT

Tách biệt hoàn toàn: Bản multi sẽ nằm trong thư mục multi/ song song với single/, dùng chung lib/ và templates/ nhưng có các lib mới riêng. CLI command sẽ là azwpm (thay vì azwp).

WARNING

Multi PHP: Cài đặt nhiều phiên bản PHP đồng thời (8.1→8.5) sẽ tốn thêm ~200-500MB RAM. Mỗi site sẽ chạy riêng một PHP-FPM pool, nên cần tối thiểu 2GB RAM cho multisite.

IMPORTANT

Resource Limits (cgroups v2): Yêu cầu Ubuntu 22.04+ với systemd. Chức năng này sẽ dùng systemd slice thay vì thao tác trực tiếp /sys/fs/cgroup.

IMPORTANT

GeoIP: Cần tài khoản MaxMind (miễn phí) để tải database GeoLite2. Bạn có sẵn MaxMind Account ID và License Key chưa?

Kiến trúc tổng thể
azwp Repository
single/ (giữ nguyên)
multi/ (MỚI)
lib/ (shared + multi libs)
templates/ (shared + multi templates)
install.sh — First-time server setup
menu.sh — CLI 'azwpm' command
site.sh — Site CRUD operations
lib/common.sh (shared)
lib/multi-common.sh (NEW)
lib/multi-site.sh (NEW)
lib/multi-php.sh (NEW)
lib/multi-nginx.sh (NEW)
lib/multi-tuning.sh (NEW)
lib/multi-isolation.sh (NEW)
lib/multi-geoip.sh (NEW)
lib/multi-dns.sh (NEW)
lib/multi-resource.sh (NEW)
lib/multi-backup.sh (NEW)
Proposed Changes
Phase 1 — Foundation + Core Infrastructure
Mục tiêu: Có thể cài đặt server lần đầu và thêm/xóa site cơ bản

[NEW]
multi-common.sh
Thư viện chia sẻ cho multisite, mở rộng từ common.sh:

Site registry: File-based registry tại /etc/azwp-multi/sites/ — mỗi site một file .conf
/etc/azwp-multi/sites/example.com.conf
├── DOMAIN=example.com
├── SITE_USER=example_com
├── PHP_VERSION=8.5
├── WEB_ROOT=/home/example_com/example.com
├── DB_NAME=wp_example_co
├── DB_USER=wp_example_co
├── DB_PASS=...
├── CACHE_PATH=/home/example_com/cache/fastcgi
├── REDIS_DB=0
├── STATUS=active
├── CREATED_AT=2026-03-30
├── RESOURCE_PLAN=default
└── GEOIP_ENABLED=false
Helper functions: site_list(), site_get(), site_exists(), site_count(), load_site_config()
Redis DB allocation: auto-assign DB index (0-15) per site, tránh conflict
[NEW]
multi-site.sh
Core CRUD operations cho mỗi site:

site_create(domain) — Tạo site mới:

Validate domain (format + not duplicate)
Tạo isolated Linux user (useradd --create-home --shell /usr/sbin/nologin)
Setup directory structure:
/home/{user}/
├── {domain}/          ← WEB_ROOT (WordPress)
├── cache/fastcgi/     ← FastCGI cache per site
├── backups/           ← Site backups
├── logs/              ← Access/error logs
└── tmp/               ← Per-user temp dir
Tạo PHP-FPM pool riêng (web + optional workers)
Tạo database + user MariaDB riêng
Tạo Nginx server block riêng
Cài WordPress (fresh hoặc clone)
Issue SSL (Let's Encrypt)
Register site vào registry
Setup WP cron + logrotate per site
site_delete(domain) — Xóa site:

Confirm (double check)
Backup trước khi xóa (optional)
Xóa Nginx config + reload
Xóa PHP-FPM pool + restart
Xóa database + user MariaDB
Xóa Linux user + home dir
Xóa cron jobs
Xóa SSL cert
Xóa khỏi registry
site_disable(domain) / site_enable(domain) — Tạm tắt/bật site

site_info(domain) — Hiển thị chi tiết site

[NEW]
multi-php.sh
Multi PHP version management:

php_install_version(version) — Cài thêm PHP version (8.1/8.2/8.3/8.4/8.5) + extensions
php_list_versions() — Liệt kê các PHP version đã cài
php_switch_site(domain, new_version) — Chuyển PHP version cho 1 site
Tạo lại FPM pool với PHP version mới
Cập nhật Nginx config (fastcgi_pass socket path)
Restart services
php_create_pool(domain, user, php_version) — Tạo FPM pool isolate per site
Pool name = slug của domain
Socket: /run/php/php{VER}-fpm-{user}.sock
open_basedir giới hạn chỉ home dir + /tmp
disable_functions ngăn shell commands
user/group = site user (không dùng www-data)
[NEW]
multi-nginx.sh
Multi-site Nginx management:

Dùng lại nginx.conf.tpl (global config) từ bản single
Template mới cho multi-site server block (tương tự site.conf.tpl nhưng động hơn)
nginx_create_site(domain) — Tạo server block
nginx_delete_site(domain) — Xóa server block
nginx_disable_site(domain) / nginx_enable_site(domain) — Tắt/bật via symlink
Mỗi site có error_log riêng: /home/{user}/logs/nginx-error.log
[NEW]
multi/install.sh
First-time server setup (chỉ chạy 1 lần):

Pre-flight checks (root, Ubuntu, RAM ≥ 2GB, disk ≥ 20GB)
System prep (timezone, locale, swap, base packages)
Install Nginx (official repo)
Install default PHP version (8.5) — có thể cài thêm sau
Install MariaDB 10.11
Install Redis (shared instance, sử dụng DB index per site)
Install WP-CLI
Security (UFW, Fail2Ban, SSH hardening)
Install CLI: azwpm → symlink tới multi/menu.sh
KHÔNG tạo site — chỉ setup infrastructure
[NEW]
multi/menu.sh
CLI management tool azwpm:

azwpm                         # Interactive menu
azwpm sites                   # List all sites
azwpm site create domain.com  # Create new site
azwpm site delete domain.com  # Delete site
azwpm site info domain.com    # Site details
azwpm site shell domain.com   # Enter site user shell
azwpm php list                # List PHP versions
azwpm php install 8.3         # Install PHP 8.3
azwpm php switch domain 8.3   # Switch site PHP
azwpm cache purge domain.com  # Purge site cache
azwpm cache purge-all         # Purge all sites cache
azwpm backup full domain.com  # Backup specific site
azwpm backup all              # Backup all sites
azwpm ssl issue domain.com    # Issue SSL for site
azwpm ssl renew               # Renew all certs
azwpm status                  # Server overview
azwpm status domain.com       # Site-specific status
azwpm geoip setup             # Setup GeoIP module
azwpm geoip block CN domain   # Block country for site
azwpm resource set domain ... # Set resource limits
azwpm resource show domain    # Show resource usage
azwpm dns setup domain        # Setup DNS (nameserver)
azwpm security scan domain    # Security scan site
azwpm security scan-all       # Scan all sites
[NEW]
multi-tuning.sh
Auto-tune cho multisite — khác bản single vì phải chia sẻ tài nguyên:

calculate_multi_tune(site_count) — Tính FPM pool size dựa trên RAM / số site
Logic: mỗi site được phân bổ (Total RAM - System Reserved) / site_count
Resource plans: small (2 FPM workers), medium (4), large (8), custom
Khi thêm/xóa site → auto-retune tất cả sites
FastCGI cache: chia đều hoặc theo plan
Phase 2 — User Isolation & Security
Mục tiêu: Site A không thể truy cập file của Site B

[NEW]
multi-isolation.sh
User isolation layers (defense-in-depth):

Layer 1 — Linux User Isolation:

Mỗi site = 1 Linux user riêng (đã có ở Phase 1)
Home directory permissions: 750 (owner only)
Shell: /usr/sbin/nologin (không SSH, chỉ process)
www-data được thêm vào group của từng user (để Nginx đọc static files)
Layer 2 — PHP-FPM Isolation:

Mỗi site = 1 FPM pool riêng, chạy dưới user của site đó
open_basedir = /home/{user}:/tmp:/usr/share/php:/run/redis
disable_functions = passthru,shell_exec,system,proc_open,popen
Temp dir riêng: php_admin_value[upload_tmp_dir] = /home/{user}/tmp
Session dir riêng: php_admin_value[session.save_path] = /home/{user}/tmp
Layer 3 — Filesystem Hardening:

Mỗi site user không thể ls hoặc cd vào /home/ của user khác
chmod 711 /home — cho phép traverse nhưng không list
WordPress file permissions: dirs=750, files=640, wp-config=640
Layer 4 — MariaDB Isolation:

Mỗi site = 1 DB + 1 DB user
DB user chỉ có quyền trên DB của mình (GRANT ALL ON db_name.*)
Không có global privileges
Phase 3 — GeoIP & DNS
Mục tiêu: Block/redirect theo quốc gia, quản lý DNS

[NEW]
multi-geoip.sh
GeoIP2 integration:

geoip_setup() — Install libnginx-mod-http-geoip2 + geoipupdate
geoip_configure_maxmind(account_id, license_key) — Cấu hình MaxMind credentials
geoip_update() — Download/update GeoLite2-Country.mmdb
geoip_auto_update() — Cron weekly update database
Nginx integration:
nginx
# Global (nginx.conf http block)
geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
    auto_reload 5m;
    $geoip2_country_code country iso_code;
}
Per-site GeoIP rules:
geoip_block_country(domain, country_code) — Block
geoip_allow_only(domain, country_codes) — Whitelist
geoip_redirect(domain, country_code, url) — Redirect
Lưu config tại /etc/nginx/azwp-geoip/{domain}.conf
Site block include: include /etc/nginx/azwp-geoip/{domain}.conf;
[NEW]
multi-dns.sh
DNS/Nameserver integration (Cloudflare API):

dns_setup_cloudflare(email, api_key) — Lưu credentials
dns_add_record(domain, type, value) — Tạo DNS record (A, CNAME, etc.)
dns_list_records(domain) — Liệt kê records
dns_delete_record(domain, record_id) — Xóa record
dns_auto_point(domain) — Tự động trỏ A record về VPS IP
Hỗ trợ Cloudflare proxy on/off toggle per domain
Tương lai: có thể mở rộng cho các DNS provider khác
Phase 4 — Resource Management
Mục tiêu: Giới hạn CPU/RAM per site, tránh 1 site chiếm hết tài nguyên

[NEW]
multi-resource.sh
Resource limits via systemd cgroups v2:

resource_set(domain, cpu_percent, memory_max):

bash
# Tạo systemd slice cho user
mkdir -p /etc/systemd/system/user-{UID}.slice.d
cat > /etc/systemd/system/user-{UID}.slice.d/override.conf <<EOF
[Slice]
MemoryMax={memory_max}
CPUQuota={cpu_percent}%
EOF
systemctl daemon-reload
resource_show(domain) — Hiển thị usage hiện tại vs limits

resource_plan_apply(domain, plan):

small: CPU 25%, RAM 512MB
medium: CPU 50%, RAM 1GB
large: CPU 100%, RAM 2GB
unlimited: No limits
resource_monitor() — Dashboard tổng quan CPU/RAM per site

PHP-FPM pool limits cũng tương ứng:

small → pm.max_children=3
medium → pm.max_children=6
large → pm.max_children=12
Phase 5 — Backup & Multi-site Operations
Mục tiêu: Backup/restore per-site, bulk operations

[NEW]
multi-backup.sh
Per-site backup (mở rộng từ backup.sh single):

backup_site(domain, type) — Backup 1 site (full/db/files)
backup_all(type) — Backup tất cả sites tuần tự
restore_site(domain, file) — Restore 1 site
backup_schedule_site(domain, frequency) — Schedule per site
backup_schedule_global(frequency) — Schedule cho tất cả
Backup location: /home/{user}/backups/ (per site)
Phase 6 — Templates Multisite
[NEW] Nginx templates cho multi:
templates/nginx/multi-site.conf.tpl — Server block per site (có GeoIP include)
templates/nginx/nginx-multi.conf.tpl — Global config có GeoIP module
[NEW] PHP templates cho multi:
templates/php/multi-pool.conf.tpl — FPM pool per site (có isolation settings)
Cấu trúc thư mục cuối cùng:
az-wp/
├── single/                    ← GIỮ NGUYÊN 100%
│   ├── install.sh
│   └── menu.sh
├── multi/                     ← MỚI
│   ├── install.sh             ← Server setup (1 lần)
│   └── menu.sh                ← CLI 'azwpm'
├── lib/
│   ├── common.sh              ← Shared (giữ nguyên)
│   ├── detect.sh              ← Shared (giữ nguyên)
│   ├── tuning.sh              ← Shared (giữ nguyên)
│   ├── nginx.sh               ← Shared (giữ nguyên)
│   ├── php.sh                 ← Shared (giữ nguyên)
│   ├── mariadb.sh             ← Shared (giữ nguyên)
│   ├── redis.sh               ← Shared (giữ nguyên)
│   ├── ssl.sh                 ← Shared (giữ nguyên)
│   ├── firewall.sh            ← Shared (giữ nguyên)
│   ├── security.sh            ← Shared (giữ nguyên)
│   ├── cron.sh                ← Shared (giữ nguyên)
│   ├── wordpress.sh           ← Shared (giữ nguyên)
│   ├── backup.sh              ← Shared (giữ nguyên)
│   ├── wp-security.sh         ← Shared (giữ nguyên)
│   ├── multi-common.sh        ← NEW: Registry, helpers multi
│   ├── multi-site.sh          ← NEW: Site CRUD
│   ├── multi-php.sh           ← NEW: Multi PHP
│   ├── multi-nginx.sh         ← NEW: Multi Nginx
│   ├── multi-tuning.sh        ← NEW: Multi tuning
│   ├── multi-isolation.sh     ← NEW: User isolation
│   ├── multi-geoip.sh         ← NEW: GeoIP
│   ├── multi-dns.sh           ← NEW: DNS/Nameserver
│   ├── multi-resource.sh      ← NEW: Resource limits
│   └── multi-backup.sh        ← NEW: Multi backup
├── templates/
│   ├── nginx/
│   │   ├── nginx.conf.tpl           ← Shared
│   │   ├── site.conf.tpl            ← Single only
│   │   ├── fastcgi-cache.conf.tpl   ← Shared
│   │   ├── multi-site.conf.tpl      ← NEW
│   │   └── multi-nginx.conf.tpl     ← NEW (nginx.conf có GeoIP)
│   ├── php/
│   │   ├── pool-web.conf.tpl        ← Single only
│   │   ├── pool-workers.conf.tpl    ← Single only
│   │   ├── php.ini.tpl              ← Shared
│   │   ├── opcache.ini.tpl          ← Shared
│   │   └── multi-pool.conf.tpl      ← NEW (per-site pool)
│   └── ... (mariadb, redis, security — shared)
├── clone/                     ← Giữ nguyên
├── setup.sh                   ← Giữ nguyên (single installer)
├── setup-multi.sh             ← NEW (multi installer)
├── VERSION
└── README.md                  ← Cập nhật
Thứ tự triển khai (Implementation Order)
Phase	Scope	Ước lượng	Mô tả
1a	Foundation	~3h	multi-common.sh + multi-site.sh + multi/install.sh
1b	PHP & Nginx	~2h	multi-php.sh + multi-nginx.sh + templates
1c	Menu & CLI	~3h	multi/menu.sh (azwpm command) + setup-multi.sh
1d	Tuning	~1h	multi-tuning.sh — auto-tune cho multisite
2	Isolation	~2h	multi-isolation.sh — user/PHP/filesystem isolation
3a	GeoIP	~2h	multi-geoip.sh + nginx templates
3b	DNS	~1h	multi-dns.sh — Cloudflare API integration
4	Resources	~2h	multi-resource.sh — cgroups v2 limits
5	Backup	~1h	multi-backup.sh — per-site backup
6	Polish	~1h	README, testing, edge cases
Tổng: ~18h work effort, triển khai theo phase để test từng bước.

Open Questions
IMPORTANT

RAM tối thiểu cho multisite: Đề xuất 2GB. Bạn có muốn hỗ trợ 1GB không (sẽ giới hạn 2-3 sites)?
IMPORTANT

2. MaxMind Account: Bạn có sẵn tài khoản MaxMind cho GeoIP chưa? Nếu chưa, tôi sẽ thêm flow đăng ký trong script.

IMPORTANT

3. DNS Provider: Ngoài Cloudflare, bạn có muốn hỗ trợ provider nào khác không (DigitalOcean DNS, Route53...)?

IMPORTANT

4. Thứ tự ưu tiên: Bạn muốn tôi bắt đầu từ Phase nào? Đề xuất: Phase 1 (Foundation) trước → test tạo/xóa site thành công → rồi tiếp Phase 2-5.

IMPORTANT

5. Clone mode: Bản multi có cần hỗ trợ clone mode (import từ backup sẵn) như bản single không?

Verification Plan
Automated Tests
Chạy shellcheck trên tất cả .sh files
Chạy bash -n (syntax check) trên mỗi file
Test template rendering với mock variables
Manual Verification
Deploy lên VPS test (Ubuntu 24.04, 2GB RAM)
Test flow: install → create site A → create site B → verify isolation
Test: site A không thể read files của site B
Test: PHP version switch
Test: resource limits
Test: GeoIP blocking
Test: backup/restore per site
