#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Money Means — Standalone claude-openrouter setup
#
# Installs `claude-openrouter`: a wrapper around Claude Code that routes
# through OpenRouter instead of Anthropic's API. Useful for experimenting
# with different models (Anthropic via OR, OpenAI, DeepSeek, etc.) while
# keeping every Claude Code feature — hooks, skills, slash commands,
# MCP servers — intact.
#
# This is intentionally NOT wired into ./setup.sh. It's an opt-in
# experiment; run this script explicitly if you want it.
#
# Usage (local clone):
#   ./setup-claude-openrouter.sh                # install / change key (idempotent)
#   ./setup-claude-openrouter.sh --test         # verify the API works end-to-end
#   ./setup-claude-openrouter.sh --uninstall    # remove wrapper + Keychain key
#
# Usage (one-liner, no clone required):
#   curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/setup-claude-openrouter.sh | bash
#
# What the install flow does:
#   • Prompts for your OpenRouter API key (https://openrouter.ai/keys)
#     — or, if a key is already stored, asks whether to keep or replace
#   • Stores the key in macOS Keychain — nothing secret on disk, nothing
#     in this repo
#   • Drops a wrapper at ~/.local/bin/claude-openrouter that reads the
#     key from Keychain, sets ANTHROPIC_BASE_URL + AUTH_TOKEN + MODEL,
#     and execs the real claude binary with all flags forwarded
#   • Adds ~/.local/bin to PATH in your .zshrc if it isn't already there
#   • Probes OpenRouter's Anthropic-compatible /v1/messages endpoint to
#     confirm the gateway actually works with your key + chosen model
#
# Idempotent. Re-runnable. Safe to pipe into bash.

REPO_RAW="${MAC_SETUP_RAW:-https://raw.githubusercontent.com/moneymeans/mac-setup/main}"

# ── Locate the lib/ files (local clone or curl|bash stage) ────────────
# Same pattern as setup.sh / setup-gpg-signing.sh, kept identical on
# purpose so the three scripts behave the same way.
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

LIB_FILES=(
  lib/common.sh
  lib/claude_openrouter.sh
)

if [[ -z "$REPO_DIR" || ! -f "$REPO_DIR/lib/common.sh" ]]; then
  REPO_DIR="$(mktemp -d -t mac-setup-claude-openrouter.XXXXXX)"
  trap 'rm -rf "$REPO_DIR"' EXIT
  echo "Staging lib files to $REPO_DIR ..."
  for f in "${LIB_FILES[@]}"; do
    mkdir -p "$REPO_DIR/$(dirname "$f")"
    curl -fsSL "$REPO_RAW/$f" -o "$REPO_DIR/$f"
  done
fi

# shellcheck disable=SC1091
source "$REPO_DIR/lib/common.sh"

section "claude-openrouter — OpenRouter wrapper for Claude Code" "$GREEN"

# Forward args (--test, --uninstall) to the lib so it can branch.
# $1 may be unset; the lib guards on ${1:-}.
# shellcheck disable=SC1091
source "$REPO_DIR/lib/claude_openrouter.sh" "$@"

# Tailor the closing banner to the mode that ran. --uninstall and --test
# shouldn't print "setup complete" — that'd be misleading.
case "${1:-install}" in
  --uninstall)
    : ;;  # lib already printed its own status
  --test)
    : ;;  # lib already reported pass/fail; an extra banner would be noise
  *)
    if (( SETUP_HAD_WARNINGS == 0 )); then
      section "claude-openrouter setup complete!" "$GREEN"
    else
      section "claude-openrouter setup finished with WARNINGS — scroll up" "$YELLOW"
    fi
    ;;
esac
