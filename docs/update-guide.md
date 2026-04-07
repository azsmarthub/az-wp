# AffiliateCMS Update Guide

## Quick Reference

```bash
# One command: pull latest + update everything
azwp update pull-update

# Or step by step:
azwp update pull          # Pull latest packages from GitHub
azwp update all           # Update all plugins + themes

# Update individual component:
azwp update pro           # AffiliateCMS Pro
azwp update cat           # AffiliateCMS Categories
azwp update ai            # AffiliateCMS AI
azwp update theme         # Parent theme
azwp update child-theme   # Child theme

# Utilities:
azwp update seed          # Seed AI prompt defaults
```

---

## How It Works

```
[Developer PC]                    [GitHub: az-wp repo]              [VPS Server]
                                                                    
Build zips from code ───push───> clone/*.zip stored ───pull───> azwp update pull
                                 in az-wp repo                  azwp update all
                                                                wp plugin install --force
```

1. Developer builds zip packages locally, commits to `az-wp` repo
2. VPS pulls latest from GitHub via `azwp update pull`
3. `azwp update all` installs each zip via WP-CLI

---

## Setup: Public vs Private Repo

### Public Repo (default)

No setup needed. `git pull` works out of the box.

```bash
# Verify it works:
azwp update pull
```

### Private Repo

Requires SSH deploy key on each VPS.

#### Step 1: Generate SSH key on VPS

```bash
# Login to VPS as root
ssh root@YOUR_VPS_IP

# Generate deploy key (no passphrase)
ssh-keygen -t ed25519 -C "azwp-deploy@$(hostname)" -f /root/.ssh/azwp_deploy -N ""

# Show the public key (copy this)
cat /root/.ssh/azwp_deploy.pub
```

#### Step 2: Add deploy key to GitHub

1. Go to: `https://github.com/azsmarthub/az-wp/settings/keys`
2. Click **Add deploy key**
3. Title: `VPS - yourdomain.com`
4. Key: paste the public key from Step 1
5. **Do NOT check** "Allow write access" (read-only is safer)
6. Click **Add key**

#### Step 3: Configure SSH on VPS

```bash
# Create SSH config to use the deploy key for GitHub
cat >> /root/.ssh/config << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/azwp_deploy
    IdentitiesOnly yes
EOF

chmod 600 /root/.ssh/config
```

#### Step 4: Switch repo URL to SSH

```bash
cd /opt/azwp
git remote set-url origin git@github.com:azsmarthub/az-wp.git
```

#### Step 5: Test connection

```bash
# Test SSH access
ssh -T git@github.com
# Expected: "Hi azsmarthub/az-wp! You've been granted access..."

# Test pull
azwp update pull
```

---

## Quick Setup: New VPS (before installing azwp)

One command — copy-paste into any fresh VPS. Generates SSH key, configures GitHub access, shows the key to add:

```bash
mkdir -p /root/.ssh && ssh-keygen -t ed25519 -C "azwp-deploy@$(hostname)" -f /root/.ssh/azwp_deploy -N "" -q && cat >> /root/.ssh/config << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/azwp_deploy
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF
chmod 600 /root/.ssh/config /root/.ssh/azwp_deploy && echo "" && echo "========================================" && echo "  DEPLOY KEY (copy this entire line):" && echo "========================================" && echo "" && cat /root/.ssh/azwp_deploy.pub && echo "" && echo "Add it here → https://github.com/azsmarthub/az-wp/settings/keys" && echo "Title: VPS - $(hostname)" && echo ""
```

After adding key to GitHub, install azwp:
```bash
git clone git@github.com:azsmarthub/az-wp.git /opt/azwp && bash /opt/azwp/single/install.sh
```

## All-in-One: Setup Private Repo Access (azwp already installed)

Copy-paste on a VPS that already has azwp installed:

```bash
mkdir -p /root/.ssh && ssh-keygen -t ed25519 -C "azwp-deploy@$(hostname)" -f /root/.ssh/azwp_deploy -N "" -q && cat >> /root/.ssh/config << 'SSHEOF'
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/azwp_deploy
    IdentitiesOnly yes
    StrictHostKeyChecking no
SSHEOF
chmod 600 /root/.ssh/config /root/.ssh/azwp_deploy && \
cd /opt/azwp && git remote set-url origin git@github.com:azsmarthub/az-wp.git && \
echo "" && echo "========================================" && echo "  DEPLOY KEY (copy this entire line):" && echo "========================================" && echo "" && cat /root/.ssh/azwp_deploy.pub && echo "" && echo "Add it here → https://github.com/azsmarthub/az-wp/settings/keys" && echo ""
```

After adding the key to GitHub:
```bash
azwp update pull-update
```

---

## Common Commands

### Daily Operations

```bash
# Check current versions
azwp wp plugins                   # List all plugins with versions

# Update everything
azwp update pull-update           # Pull + update all

# Update just one plugin
azwp update pull                  # Get latest packages
azwp update pro                   # Update only Pro plugin
```

### After Fresh Install (Clone Mode)

```bash
# Verify prompts are seeded
azwp update seed

# Verify crons are installed
azwp cron list

# If crons missing:
azwp cron preset
```

### Troubleshooting

```bash
# Plugin not activating after update?
azwp wp cli
wp plugin deactivate affiliatecms-pro && wp plugin activate affiliatecms-pro

# Pull fails with "permission denied"?
ssh -T git@github.com              # Check SSH key access
cat /root/.ssh/azwp_deploy.pub     # Verify key exists

# Pull fails with "not a git repository"?
ls -la /opt/azwp/.git              # Check repo exists
cd /opt/azwp && git status         # Check repo state

# Pull fails with "diverged branches"?
cd /opt/azwp && git reset --hard origin/main   # Force sync with remote

# Cache issues after update?
azwp cache purge                   # Purge FastCGI + Redis
```

### Building New Packages (Developer)

On your local machine:

```bash
cd ~/projects/affiliatecms-ai

# Build all zips
for d in affiliatecms-pro affiliatecms-cat affiliatecms-ai affiliateCMS-theme affiliateCMS-Child-theme; do
    zip -r "../az-wp/clone/${d}.zip" "${d}/" \
        -x "${d}/.git/*" -x "${d}/node_modules/*" -x "${d}/vendor/*" \
        -x "${d}/.DS_Store" -x "${d}/*.log" -x "${d}/composer.*" \
        -x "${d}/package.json" -x "${d}/pnpm-lock.yaml"
done

# Commit to az-wp
cd ~/projects/az-wp
git add clone/*.zip
git commit -m "update: rebuild packages from latest code"
git push
```

Then on each VPS:
```bash
azwp update pull-update
```

---

## Component Map

| Command | Plugin/Theme | Zip File | Type |
|---------|-------------|----------|------|
| `azwp update pro` | AffiliateCMS Pro | `affiliatecms-pro.zip` | Plugin |
| `azwp update cat` | AffiliateCMS Categories | `affiliatecms-cat.zip` | Plugin |
| `azwp update ai` | AffiliateCMS AI | `affiliatecms-ai.zip` | Plugin |
| `azwp update theme` | AffiliateCMS Theme | `affiliateCMS-theme.zip` | Theme |
| `azwp update child-theme` | Child Theme | `affiliateCMS-Child-theme.zip` | Theme |

---

## Security Notes

- Deploy keys are **read-only** by default (recommended)
- Each VPS gets its own unique deploy key
- To revoke access: remove the key from GitHub settings
- Keys are stored at `/root/.ssh/azwp_deploy` (private) and `.pub` (public)
- SSH config at `/root/.ssh/config` routes GitHub traffic through the deploy key
