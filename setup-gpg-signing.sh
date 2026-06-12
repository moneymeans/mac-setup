#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Money Means — Standalone GPG commit-signing setup
#
# For Macs that are ALREADY set up (Homebrew installed, git identity
# configured) and just need GPG commit signing added. Engineers who
# went through ./setup.sh already get this automatically — they don't
# need to run this script.
#
# Usage (local clone):
#   ./setup-gpg-signing.sh
#
# Usage (one-liner, no clone required):
#   curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/setup-gpg-signing.sh | bash
#
# What it does:
#   • brew installs gnupg + pinentry-mac (if missing)
#   • Reuses an existing GPG key for your git email, or generates an
#     RSA 4096 key with no passphrase
#   • Configures git globally to sign every commit and tag
#   • Configures gpg-agent to use pinentry-mac
#   • Adds `export GPG_TTY=$(tty)` to your shell rc (zsh or bash)
#   • Exports the public key, copies it to your clipboard, prints it,
#     and tells you how to add it to GitHub
#   • Makes a signed test commit in a temp repo to verify
#
# Idempotent. Re-runnable. Safe to pipe into bash.

REPO_RAW="${MAC_SETUP_RAW:-https://raw.githubusercontent.com/moneymeans/mac-setup/main}"

# ── Locate the lib/ files (local clone or curl|bash stage) ────────────
# Identical pattern to setup.sh — keep behaviour consistent so anyone
# who has read setup.sh recognises this block.
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

LIB_FILES=(
  lib/common.sh
  lib/gpg_signing.sh
)

if [[ -z "$REPO_DIR" || ! -f "$REPO_DIR/lib/common.sh" ]]; then
  REPO_DIR="$(mktemp -d -t mac-setup-gpg.XXXXXX)"
  trap 'rm -rf "$REPO_DIR"' EXIT
  echo "Staging lib files to $REPO_DIR ..."
  for f in "${LIB_FILES[@]}"; do
    mkdir -p "$REPO_DIR/$(dirname "$f")"
    curl -fsSL "$REPO_RAW/$f" -o "$REPO_DIR/$f"
  done
fi

# shellcheck disable=SC1091
source "$REPO_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/gpg_signing.sh"

# Match setup.sh's success/warning banner so the experience is the same
# whether the user ran the standalone script or the full setup.
if (( SETUP_HAD_WARNINGS == 0 )); then
  section "GPG signing setup complete!" "$GREEN"
else
  section "GPG signing finished with WARNINGS — scroll up" "$YELLOW"
fi
