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
    MAC_SETUP_REPOS="repo1 repo2"           # pre-supply the clone list
    MAC_SETUP_REPOS="none"                  # explicitly skip the clone prompt
    MAC_SETUP_BROWSERS="chrome firefox"     # pre-supply browser list (default: chrome)
    MAC_SETUP_BROWSERS="none"               # skip the browser prompt
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
  lib/node.sh
  lib/dotnet.sh
  lib/claude.sh
  lib/ohmyzsh.sh
  lib/itsycal.sh
  lib/docker.sh
  lib/repos.sh
  lib/project_bootstrap.sh
  lib/auth_clis.sh
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
  5.  Node (mise + LTS), .NET 10 SDK, CSharpier, Claude Code, Oh My Zsh
  6.  Itsycal config (clock format, hide icon, weekday highlight, autostart)
  7.  Docker Desktop — launches and waits for the daemon
  8.  Repo cloning — you'll be asked which repos to clone (ask your buddy)
  9.  Project bootstrap — optional, only if MAC_SETUP_PROJECT is set
  10. CLI auth — we'll walk you through `gh`, `az`, and `claude` sign-ins
  11. Summary + "next steps" you still need to do by hand

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

# ── Pre-warm sudo (so casks don't re-prompt mid-flow) ──────────────────
source "$REPO_DIR/lib/sudo.sh"

# ── Stage 1: brew + everything in the Brewfile ─────────────────────────
source "$REPO_DIR/lib/homebrew.sh"

# ── Stage 1b: browsers (interactive multi-select) ──────────────────────
source "$REPO_DIR/lib/browsers.sh"

# ── Stage 2: runtimes that need to be on PATH ──────────────────────────
source "$REPO_DIR/lib/node.sh"
source "$REPO_DIR/lib/dotnet.sh"
source "$REPO_DIR/lib/claude.sh"
source "$REPO_DIR/lib/ohmyzsh.sh"

# ── Stage 2b: app-specific config ──────────────────────────────────────
source "$REPO_DIR/lib/itsycal.sh"

# ── Stage 3: Docker Desktop daemon ─────────────────────────────────────
# Needed before any project-bootstrap step that requires Docker.
source "$REPO_DIR/lib/docker.sh"

# ── Stage 4: clone repos ───────────────────────────────────────────────
if $DO_CLONE; then
  source "$REPO_DIR/lib/repos.sh"
else
  info "Skipping repo clone (--no-clone)"
fi

# ── Stage 5: project bootstrap ─────────────────────────────────────────
source "$REPO_DIR/lib/project_bootstrap.sh"

# ── Stage 6: interactive CLI auth ──────────────────────────────────────
source "$REPO_DIR/lib/auth_clis.sh"

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
$DO_CLONE && echo "  - Cloned repos under ~/work"
[[ -n "${MAC_SETUP_PROJECT:-}" && -d "$HOME/work/${MAC_SETUP_PROJECT}" ]] && \
  echo "  - Bootstrapped $MAC_SETUP_PROJECT"

echo ""
echo -e "${YELLOW}Next steps — these need a human:${NC}"
echo "  1. Quit Terminal.app and switch to iTerm2 — that's the terminal we use."
echo "     (Find it in /Applications, or hit ⌘-Space and type 'iTerm'.)"
echo "  2. Sign in to the apps: Slack, Notion, Microsoft Teams, your browser(s), VS Code."
echo "  3. Docker Desktop: complete the first-run setup (it may ask for"
echo "     keychain access and accept-licence)."
if [[ -n "${MAC_SETUP_PROJECT_CONFIG:-}" && -f "$HOME/${MAC_SETUP_PROJECT_CONFIG}" ]]; then
  echo "  4. Edit ~/${MAC_SETUP_PROJECT_CONFIG} to match your project."
fi
