#!/usr/bin/env bash
# ============================================================================
# az-wp-single — One-line bootstrap installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/azsmarthub/az-wp/main/setup.sh | bash
#
# What this does:
#   1. Checks root + Ubuntu 22.04/24.04
#   2. Installs git if missing
#   3. Clones az-wp repo to /opt/az-wp
#   4. Runs the installer
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

AZ_INSTALL_DIR="/opt/az-wp"
AZ_REPO="https://github.com/azsmarthub/az-wp.git"
AZ_BRANCH="main"

die() {
    printf "${RED}[ERROR] %s${NC}\n" "$1" >&2
    exit 1
}

ok() {
    printf "${GREEN}  OK${NC}  %s\n" "$1"
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------

printf "\n"
printf "${BOLD}===================================================\n"
printf "  az-wp-single — Bootstrap Installer\n"
printf "===================================================${NC}\n"
printf "\n"

# Must be root
[[ "${EUID:-$(id -u)}" -ne 0 ]] && die "Must run as root. Use: sudo bash or login as root."
ok "Running as root"

# Must be Ubuntu
if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS. /etc/os-release not found."
fi

# shellcheck source=/dev/null
source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    die "This script requires Ubuntu. Detected: $ID"
fi

case "$VERSION_ID" in
    22.04|24.04) ;;
    *) die "Ubuntu $VERSION_ID not supported. Requires 22.04 or 24.04." ;;
esac

ok "Ubuntu $VERSION_ID ($VERSION_CODENAME)"

# ---------------------------------------------------------------------------
# Install git if missing
# ---------------------------------------------------------------------------

if ! command -v git &>/dev/null; then
    printf "  ..  Installing git...\n"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq git >/dev/null 2>&1
    ok "git installed"
else
    ok "git available"
fi

# ---------------------------------------------------------------------------
# Clone or update repo
# ---------------------------------------------------------------------------

if [[ -d "$AZ_INSTALL_DIR/.git" ]]; then
    printf "  ..  Updating existing installation...\n"
    cd "$AZ_INSTALL_DIR"
    git fetch origin "$AZ_BRANCH" --quiet
    git reset --hard "origin/$AZ_BRANCH" --quiet
    ok "Updated to latest version"
else
    # Remove leftover if exists but not a git repo
    [[ -d "$AZ_INSTALL_DIR" ]] && rm -rf "$AZ_INSTALL_DIR"

    printf "  ..  Downloading az-wp...\n"
    git clone --depth 1 --branch "$AZ_BRANCH" "$AZ_REPO" "$AZ_INSTALL_DIR" --quiet
    ok "Downloaded to $AZ_INSTALL_DIR"
fi

# ---------------------------------------------------------------------------
# Set permissions and run installer
# ---------------------------------------------------------------------------

chmod +x "$AZ_INSTALL_DIR/single/install.sh"
[[ -f "$AZ_INSTALL_DIR/single/menu.sh" ]] && chmod +x "$AZ_INSTALL_DIR/single/menu.sh"

printf "\n"
printf "${BOLD}Starting installer...${NC}\n"
printf "\n"

# Use /dev/tty to ensure interactive prompts work even when piped via curl
exec "$AZ_INSTALL_DIR/single/install.sh" </dev/tty
