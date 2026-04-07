# Clone Build & Update Guide (for AI assistants)

## Overview

`az-wp/clone/` contains pre-built packages for deploying AffiliateCMS sites. When `install.sh` runs in clone mode, it restores the database, extracts wp-content, and installs all plugins/themes automatically.

## Clone Directory Contents

```
clone/
├── database.sql.gz              ← MySQL dump (gzipped) from production
├── wp-config-template.php       ← wp-config with CLONE_* placeholders
├── wp-content.tar.gz            ← Full wp-content (plugins + themes, for fresh install)
├── affiliatecms-pro.zip         ← Plugin: AffiliateCMS Pro
├── affiliatecms-cat.zip         ← Plugin: AffiliateCMS Categories
├── affiliatecms-ai.zip          ← Plugin: AffiliateCMS AI
├── affiliateCMS-theme.zip       ← Theme: AffiliateCMS (parent)
└── affiliateCMS-Child-theme.zip ← Theme: Child theme template
```

## Two Use Cases

### 1. Fresh Install (clone mode)
Uses `database.sql.gz` + `wp-content.tar.gz`. Full site clone with data.

### 2. Updates (azwp update)
Uses individual `.zip` files. `wp plugin install --force` / `wp theme install --force`.

---

## How to Rebuild Clone Packages

### Step 1: Export Database

Export from the production/staging site that has the latest data:

```bash
# SSH into the source server
ssh root@SERVER_IP

# Export (keys stay in dump — install.sh auto-clears them on clone)
cd /home/SITE_USER/DOMAIN
sudo -u SITE_USER wp db export - | gzip > /tmp/clone-db.sql.gz
```

Download to local:
```bash
scp root@SERVER_IP:/tmp/clone-db.sql.gz ~/projects/az-wp/clone/database.sql.gz
```

**IMPORTANT**: Do NOT manually remove API keys from the dump. The install script handles this automatically during clone (`install.sh` line ~377: "Clearing cloned API keys").

### Step 2: Build Zip Packages

From the main code repository:

```bash
cd ~/projects/affiliatecms-ai
CLONE_DIR="../az-wp/clone"

for d in affiliatecms-pro affiliatecms-cat affiliatecms-ai affiliateCMS-theme affiliateCMS-Child-theme; do
    rm -f "${CLONE_DIR}/${d}.zip"
    zip -r "${CLONE_DIR}/${d}.zip" "${d}/" \
        -x "${d}/.git/*" -x "${d}/node_modules/*" -x "${d}/vendor/*" \
        -x "${d}/.DS_Store" -x "${d}/*.log" -x "${d}/*.cache" \
        -x "${d}/.phpcs-cache" -x "${d}/composer.json" -x "${d}/composer.lock" \
        -x "${d}/package.json" -x "${d}/pnpm-lock.yaml" -x "${d}/gulpfile.js" \
        -x "${d}/prompts.md" -x "${d}/*.bak"
done
```

### Step 3: Build wp-content.tar.gz

```bash
STAGING="/tmp/azwp-wp-content-build"
rm -rf "$STAGING"
mkdir -p "$STAGING/wp-content/plugins" "$STAGING/wp-content/themes"

for plugin in affiliatecms-pro affiliatecms-cat affiliatecms-ai; do
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='vendor' \
        --exclude='composer.*' --exclude='*.log' --exclude='package.json' \
        --exclude='pnpm-lock.yaml' --exclude='gulpfile.js' --exclude='.phpcs-cache' \
        --exclude='prompts.md' --exclude='*.bak' \
        "${plugin}/" "$STAGING/wp-content/plugins/${plugin}/"
done

for theme in affiliateCMS-theme affiliateCMS-Child-theme; do
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='vendor' \
        --exclude='package.json' --exclude='pnpm-lock.yaml' --exclude='gulpfile.js' \
        --exclude='*.log' --exclude='*.bak' \
        "${theme}/" "$STAGING/wp-content/themes/${theme}/"
done

# Include nginx cache plugin if exists
[ -d "azsmart-nginx-cache" ] && rsync -a --exclude='.git' \
    "azsmart-nginx-cache/" "$STAGING/wp-content/plugins/azsmart-nginx-cache/"

cd "$STAGING"
tar czf ~/projects/az-wp/clone/wp-content.tar.gz wp-content/
rm -rf "$STAGING"
```

### Step 4: Commit & Push

```bash
cd ~/projects/az-wp
git add clone/
git commit -m "update: rebuild clone packages from latest code"
git push
```

### Step 5: Deploy to VPS

```bash
# On the VPS:
azwp update pull-update    # Pull + update all components
```

---

## Install Script Clone Flow

When `install.sh` detects `clone/database.sql.gz` + `clone/wp-content.tar.gz`, it runs:

1. Download WordPress core
2. Create wp-config.php from template
3. Import database.sql.gz
4. Extract wp-content.tar.gz
5. Fix hardcoded paths (CDN URL, FPM pool name)
6. Search & replace domain (productreviews.org → new domain)
7. Configure Redis
8. Install redis-cache plugin
9. Set cache path
10. Reset admin password
11. **Clear cloned API keys** (acms_ai_api_key, acms_crawlbase_token, acms_paapi_credentials, general_settings keys)
12. **Seed AI prompt defaults** (DefaultPrompts::seed())
13. **Re-activate plugins** (triggers activation hooks, schema migrations)
14. Set file permissions
15. Install 19 AffiliateCMS cron jobs

## Security: API Keys

- Database dump **MAY contain** real API keys from source site
- `install.sh` **automatically clears** all keys after DB import (step 11)
- New site starts with empty keys — user must enter their own
- Keys cleared: `acms_ai_api_key`, `acms_crawlbase_token`, `acms_paapi_credentials`, and embedded keys in `acms_general_settings`
- **NEVER** manually remove keys from the dump — the script handles it

## Cron Jobs (19 total)

Automatically installed when API token found in DB:

**Tier 1 — Pipeline (every 2 min, staggered):**
1. `scrape` — Scrape dispatcher
2. `process-scheduled` (+20s) — Process scheduled products
3. `scrape-monitor` (+40s) — Scrape monitor
4. `pro-queue` (+50s) — Keyword queue processor
5. `queue-processor` (+60s) — Category queue processor
6. `queue-monitor` (+80s) — Category queue monitor

**Tier 2 — AI (every 2-5 min):**
7. `ai-jobs` (+10s, */2) — AI job processor (parallel workers)
8. `product-ai` (*/5) — ASIN enhancement
9. `post-ai` (+30s, */5) — Post AI generation
10. `category-ai` (+60s, */5) — Category AI content
11. `brand-ai` (+90s, */5) — Brand AI content
12. `brand-category-ai` (+120s, */5) — Brand-category AI

**Tier 3 — Maintenance:**
13. `quick-update` (*/30) — Price/rating updates
14. `retry-stuck` (*/10) — Retry stuck items
15. `date-update` (3am daily) — Date placeholder updates
16. `bulk-update` (*/1) — Bulk update worker
17. `cache-preload` (3am weekly) — Cache preload
18. `cache-refresh` (*/4h) — Smart cache refresh
19. `cache-resume` (*/30) — Resume cache queue
