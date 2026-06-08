#!/usr/bin/env bash
# Money Means — Mac onboarding bootstrap.
#
# One-liner for a brand-new Mac:
#   curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/bootstrap.sh | bash
#
# Downloads the mac-setup repo to ~/mac-setup, then tells you the two
# commands to run next. The actual onboarding (Xcode CLT, SSH key,
# Homebrew, apps, etc.) lives in pre-setup.sh + setup.sh — and they
# need an interactive terminal, so we can't just pipe them inline.

set -euo pipefail

readonly REPO_TARBALL="https://github.com/moneymeans/mac-setup/archive/refs/heads/main.tar.gz"
readonly DEST="$HOME/mac-setup"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ -d "$DEST" ]]; then
  echo -e "${YELLOW}~/mac-setup already exists.${NC} Re-downloading the latest main..."
  rm -rf "$DEST"
fi

mkdir -p "$DEST"
echo "Downloading mac-setup to $DEST..."
curl -fsSL "$REPO_TARBALL" | tar -xz -C "$DEST" --strip-components=1

chmod +x "$DEST/pre-setup.sh" "$DEST/setup.sh"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Downloaded successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Now run these two commands in order:"
echo ""
echo -e "  ${BLUE}cd ~/mac-setup${NC}"
echo -e "  ${BLUE}./pre-setup.sh${NC}    # ~10 min, interactive: SSH key, GitHub paste, git identity"
echo -e "  ${BLUE}./setup.sh${NC}        # ~20-30 min, mostly unattended (one password prompt at the start)"
echo ""
echo "See $DEST/README.md for details, env-var options, and re-running."
