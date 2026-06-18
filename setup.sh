#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Money Means — Mac Developer Setup
#
# Run ./pre-setup.sh FIRST (Xcode CLT, SSH key, git identity).
# Then this script handles everything else: Homebrew, apps, runtimes,
# and per-project bootstrap.

read -r -d '' USAGE <<'EOF' || true
Money Means — Mac Developer Setup

  Pre-requisite: ./pre-setup.sh has been run (Xcode CLT, SSH key, git identity).

  Usage:
    ./setup.sh                     # everything: brew → apps → runtimes → repos → project
    ./setup.sh --no-clone          # skip repo cloning (tooling refresh only)
    ./setup.sh -h | --help         # show this help

  Remote (once the repo is public):
    curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/setup.sh | bash

  Environment variables (your buddy will tell you which to set):
    MAC_SETUP_WORK_DIR="/path/to/work"      # where to clone repos (default: ~/work)
    MAC_SETUP_REPOS="repo1 repo2"           # pre-supply the clone list
    MAC_SETUP_REPOS="none"                  # explicitly skip the clone prompt
    MAC_SETUP_BROWSERS="chrome firefox"     # pre-supply browser list (default: chrome)
    MAC_SETUP_BROWSERS="none"               # skip the browser prompt
    MAC_SETUP_OMZ="yes"                     # install Oh My Zsh without prompting
    MAC_SETUP_OMZ="no"                      # skip Oh My Zsh without prompting
    MAC_SETUP_PROJECT="<repo-name>"         # which cloned repo to bootstrap (Makefile)
    MAC_SETUP_PROJECT_CONFIG="<conf>"       # copy <conf>.example from the project to ~/<conf>
    MAC_SETUP_PROJECT_TMUX="<session>"      # create a detached tmux session with this name
    MAC_SETUP_PROJECT_NEEDS_DOCKER=1        # require docker daemon before make install
    MAC_SETUP_NO_PAUSE=1                    # skip the welcome-screen "press Enter" pause
    MAC_SETUP_NO_AUTH=1                     # skip the interactive gh/az/claude auth section
    MAC_SETUP_RAW=<url>                     # override raw URL (advanced)
EOF

REPO_RAW="${MAC_SETUP_RAW:-https://raw.githubusercontent.com/moneymeans/mac-setup/main}"

DO_CLONE=true
for arg in "$@"; do
  case "$arg" in
    --no-clone) DO_CLONE=false ;;
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    *)
      echo "Unknown argument: '$arg'" >&2
      echo "" >&2
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done

# ── Locate REPO_DIR ────────────────────────────────────────────────────
# Local clone: source lib/*.sh from disk.
# curl|bash:  stage lib/ + Brewfile into a tempdir from raw.githubusercontent.com.
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

LIB_FILES=(
  Brewfile
  lib/common.sh
  lib/preflight.sh
  lib/sudo.sh
  lib/homebrew.sh
  lib/browsers.sh
  lib/ohmyzsh.sh
  lib/node.sh
  lib/dotnet.sh
  lib/claude.sh
  lib/itsycal.sh
  lib/rectangle.sh
  lib/iterm.sh
  lib/macos_defaults.sh
  lib/docker.sh
  lib/repos.sh
  lib/claude_herder.sh
  lib/project_bootstrap.sh
  lib/auth_clis.sh
  lib/gpg_signing.sh
)

REPO_DIR_IS_TEMP=false
if [[ -z "$REPO_DIR" || ! -f "$REPO_DIR/lib/common.sh" ]]; then
  REPO_DIR="$(mktemp -d -t mac-setup.XXXXXX)"
  REPO_DIR_IS_TEMP=true
  trap 'rm -rf "$REPO_DIR"' EXIT
  echo "Staging lib/ + Brewfile to $REPO_DIR ..."
  for f in "${LIB_FILES[@]}"; do
    mkdir -p "$REPO_DIR/$(dirname "$f")"
    curl -fsSL "$REPO_RAW/$f" -o "$REPO_DIR/$f"
  done
fi

# shellcheck disable=SC1091
source "$REPO_DIR/lib/common.sh"

# ── Welcome banner ─────────────────────────────────────────────────────
section "Money Means — Mac Developer Setup" "$GREEN"
cat <<'WELCOME'
Welcome! This script will take ~20-30 minutes and is mostly unattended.

Here's what's about to happen, in order:

  1.  Preflight checks (Xcode CLT, GitHub SSH, git identity from pre-setup)
  2.  macOS password prompt — once, so brew bundle doesn't re-prompt later
  3.  Homebrew + every app/CLI in Brewfile (heaviest stage, ~10-15 min)
  4.  Browsers — interactive picker (chrome / firefox / arc / brave)
  5.  Oh My Zsh — optional, you'll be asked (default = yes)
  6.  Node (mise + LTS), .NET 10 SDK, CSharpier, Claude Code
  7.  Itsycal + Rectangle + iTerm2 config (autostart + sensible defaults)
  8.  macOS defaults (fast key repeat, Finder dev settings, firewall, screen lock)
  9.  Docker Desktop — launches and waits for the daemon
  10. Repo cloning — default = claude-herder + MoneyStory (press Enter
      to accept; type names to override; 'none' to skip)
  11. Bootstrap claude-herder if cloned — `make install` + `make start`,
      then opens http://localhost:7682/
  12. Project bootstrap — optional, only if MAC_SETUP_PROJECT is set
  13. CLI auth — we'll walk you through `gh`, `az`, and `claude` sign-ins
  14. GPG commit signing — generates a key and tells you to add it to GitHub
  15. Summary + "next steps" you still need to do by hand

Things to know:
  • Stay nearby for the brew bundle stage — Docker/Teams may prompt for
    your password despite the prewarm (macOS quirk).
  • Every step is idempotent — re-running setup.sh is always safe.
  • If anything warns, the final banner turns yellow instead of green so
    you'll know to scroll up.
  • Ctrl-C is safe at any point. Re-run to pick up where you left off.

WELCOME

# Pause for the user only when running interactively. Skipped under
# curl|bash, CI, or `MAC_SETUP_NO_PAUSE=1` — so unattended runs aren't
# wedged at the welcome screen.
if [[ -t 0 && "${MAC_SETUP_NO_PAUSE:-0}" != "1" ]]; then
  read -rp "Press Enter to continue (or Ctrl-C to abort)... "
fi

# ── Preflight ──────────────────────────────────────────────────────────
source "$REPO_DIR/lib/preflight.sh"

# ── Self-update (only when running from a clone) ───────────────────────
# Preflight just proved GitHub SSH works, so we can safely `git pull`
# before doing any heavy work. If the pull brings in new commits, stop
# and ask the user to re-run — bash holds the script open by fd and
# mid-run edits are undefined behaviour. Skipped under `curl|bash`
# (REPO_DIR_IS_TEMP=true) because that path already fetches fresh.
if ! $REPO_DIR_IS_TEMP && [[ -d "$REPO_DIR/.git" ]]; then
  section "Checking for updates"
  if ! git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null \
     || ! git -C "$REPO_DIR" diff --cached --quiet HEAD 2>/dev/null; then
    info "Local changes in $REPO_DIR — skipping self-update so we don't clobber them"
  else
    before=$(git -C "$REPO_DIR" rev-parse HEAD)
    if git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
      after=$(git -C "$REPO_DIR" rev-parse HEAD)
      if [[ "$before" != "$after" ]]; then
        section "Setup script updated — please re-run" "$YELLOW"
        echo "Pulled new commits into $REPO_DIR:"
        echo ""
        git -C "$REPO_DIR" log --oneline "$before..$after"
        echo ""
        echo "Re-run ./setup.sh to continue with the latest version."
        exit 0
      fi
      ok "Already up to date"
    else
      info "Could not fast-forward (diverged branch?) — continuing with local copy"
    fi
  fi
fi

# ── Pre-warm sudo (so casks don't re-prompt mid-flow) ──────────────────
source "$REPO_DIR/lib/sudo.sh"

# ── Stage 1: brew + everything in the Brewfile ─────────────────────────
source "$REPO_DIR/lib/homebrew.sh"

# ── Stage 1b: browsers (interactive multi-select) ──────────────────────
source "$REPO_DIR/lib/browsers.sh"

# ── Stage 2: zsh framework (must run before node/etc. so its block in
#            .zshrc lands ABOVE the mise-activate block; oh-my-zsh sets
#            PROMPT and we want anything later to override it) ─────────
source "$REPO_DIR/lib/ohmyzsh.sh"

# ── Stage 2a: runtimes that need to be on PATH ─────────────────────────
source "$REPO_DIR/lib/node.sh"
source "$REPO_DIR/lib/dotnet.sh"
source "$REPO_DIR/lib/claude.sh"

# ── Stage 2b: app-specific config ──────────────────────────────────────
source "$REPO_DIR/lib/itsycal.sh"
source "$REPO_DIR/lib/rectangle.sh"
source "$REPO_DIR/lib/iterm.sh"

# ── Stage 2c: macOS defaults (security + dev QoL) ──────────────────────
source "$REPO_DIR/lib/macos_defaults.sh"

# ── Stage 3: Docker Desktop daemon ─────────────────────────────────────
# Needed before any project-bootstrap step that requires Docker.
source "$REPO_DIR/lib/docker.sh"

# ── Stage 4: clone repos ───────────────────────────────────────────────
if $DO_CLONE; then
  source "$REPO_DIR/lib/repos.sh"
else
  info "Skipping repo clone (--no-clone)"
fi

# ── Stage 4b: claude-herder bootstrap (no-op if it wasn't cloned) ──────
source "$REPO_DIR/lib/claude_herder.sh"

# ── Stage 5: project bootstrap ─────────────────────────────────────────
source "$REPO_DIR/lib/project_bootstrap.sh"

# ── Stage 6: interactive CLI auth ──────────────────────────────────────
source "$REPO_DIR/lib/auth_clis.sh"

# ── Stage 7: GPG commit signing ────────────────────────────────────────
# Runs after auth_clis so the "upload key to GitHub" prompt lands at the
# end of the script where it's most visible. Pre-setup has already
# guaranteed user.name + user.email exist in global git config.
source "$REPO_DIR/lib/gpg_signing.sh"

# ── Summary ────────────────────────────────────────────────────────────
if (( SETUP_HAD_WARNINGS == 0 )); then
  section "Setup complete!" "$GREEN"
else
  section "Setup finished with WARNINGS — scroll up" "$YELLOW"
fi

echo "Installed / verified:"
echo "  - Homebrew + Brewfile (apps + CLI tools)"
echo "  - Browsers (per your selection)"
echo "  - mise + Node.js LTS"
echo "  - .NET 10 SDK + CSharpier"
echo "  - Claude Code CLI"
echo "  - Oh My Zsh"
echo "  - Docker Desktop (daemon running)"
echo "  - GPG commit signing (key generated, git configured)"
if $DO_CLONE; then
  echo "  - Cloned repos under ${WORK_DIR:-$HOME/work}"
fi
if [[ -n "${MAC_SETUP_PROJECT:-}" && -d "${WORK_DIR:-$HOME/work}/${MAC_SETUP_PROJECT}" ]]; then
  echo "  - Bootstrapped $MAC_SETUP_PROJECT"
fi

echo ""
echo -e "${YELLOW}Next steps — these need a human:${NC}"
echo "  1. Sign in to the apps: Slack, Notion, Microsoft Teams, your browser(s), VS Code."
echo "  2. Docker Desktop: complete the first-run setup (it may ask for"
echo "     keychain access and accept-licence)."
if [[ -n "${MAC_SETUP_PROJECT_CONFIG:-}" && -f "$HOME/${MAC_SETUP_PROJECT_CONFIG}" ]]; then
  echo "  3. Edit ~/${MAC_SETUP_PROJECT_CONFIG} to match your project."
fi

# Launch iTerm so the user lands in our preferred terminal as setup
# ends — and close Terminal.app's window if that's what they're in.
# We don't `killall Terminal` because that would yank the rug out from
# under any ongoing copy/git op the user might have started elsewhere.
if [[ -d "/Applications/iTerm.app" ]]; then
  echo ""
  echo -e "${GREEN}Launching iTerm — switch to it now. You can close this Terminal window.${NC}"
  open -a iTerm 2>/dev/null || true
fi
