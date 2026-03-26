# azwp

WordPress deployment script for Ubuntu VPS. One VPS = One Site.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/azsmarthub/az-wp/main/setup.sh | bash
```

## What it does

- Installs full LEMP stack (Nginx + PHP-FPM + MariaDB + Redis)
- Auto-tunes all configs based on VPS RAM (512MB to 8GB+)
- Dual PHP-FPM pools (web + workers) for background job isolation
- FastCGI full-page cache with smart bypass rules
- SSL via Let's Encrypt (auto-renew)
- Security hardening (UFW, Fail2Ban, SSH)
- CLI management tool: `azwp`

## Requirements

- Fresh Ubuntu 22.04 or 24.04 VPS
- Root access
- Minimum 512MB RAM, 10GB disk

## Post-install management

```bash
azwp              # Interactive menu
azwp status       # System dashboard
azwp cache purge  # Purge all caches
azwp backup full  # Full backup
azwp wp update    # Update WordPress
azwp retune       # Re-tune after VPS resize
```

## Stack

| Component | Version |
|-----------|---------|
| Nginx | Official repo (stable) |
| PHP-FPM | 8.1 - 8.5 (Ondrej PPA) |
| MariaDB | 10.11 LTS |
| Redis | 7.x (Unix socket) |
| SSL | Certbot + Let's Encrypt |
