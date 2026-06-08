#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Money Means — Mac Pre-Setup
#
# The human-attended step. Run this first, on a completely fresh Mac:
#   ./pre-setup.sh
#
# This script is fundamentally interactive — it prompts for your email,
# pauses while you upload your SSH key to GitHub, prompts for your name.
# It CANNOT be `curl | bash`'d. Fail early with a clear message if anyone
# tries.

if [[ ! -t 0 ]]; then
  echo "ERROR: pre-setup.sh needs an interactive terminal (stdin is not a tty)." >&2
  echo "" >&2
  echo "If you're running this via curl|bash, that won't work — pre-setup pauses" >&2
  echo "for your SSH key upload. Instead, download the repo first, then run it:" >&2
  echo "" >&2
  echo "  curl -fsSL https://github.com/moneymeans/mac-setup/archive/refs/heads/main.tar.gz \\" >&2
  echo "    | tar -xz -C \$HOME && mv \$HOME/mac-setup-main \$HOME/mac-setup" >&2
  echo "  cd \$HOME/mac-setup" >&2
  echo "  ./pre-setup.sh" >&2
  echo "" >&2
  exit 1
fi
#
# What it does (every step idempotent):
#   1. Installs Xcode Command Line Tools (waits for the macOS GUI installer).
#   2. Generates an ed25519 SSH key (or reuses an existing one).
#      The key is generated WITHOUT a passphrase so the script can keep
#      moving — pre-seeded GitHub host keys mitigate the usual TOFU risk.
#   3. Copies the public key to your clipboard and waits while you paste it
#      into https://github.com/settings/ssh/new
#   4. Verifies GitHub now accepts the key.
#   5. Sets your global git identity (user.name + user.email).
#
# After this finishes, run `./setup.sh` to install all the actual tooling
# (Homebrew, apps, runtimes, repos). setup.sh refuses to run if pre-setup
# hasn't completed.
#
# Self-contained: depends only on stock macOS commands. The helpers below
# are duplicated from lib/common.sh on purpose — at this point we cannot
# assume the repo is present.

# ── Constants ─────────────────────────────────────────────────────────
readonly MAX_GITHUB_KEY_ATTEMPTS=5
readonly XCODE_POLL_INTERVAL_S=5
readonly XCODE_MAX_POLL_ATTEMPTS=60   # 60 × 5s = 5 minutes
readonly EMAIL_REGEX='^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'

# Official GitHub host keys, fingerprint-pinned by GitHub at
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# Pre-seeding these into known_hosts converts the first SSH connection
# from trust-on-first-use to strict-known-host, closing the MITM window.
readonly GITHUB_KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

# ── Helpers (duplicated from lib/common.sh — keep in sync) ─────────────
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

section() {
  local title="$1" color="${2:-$BLUE}"
  echo ""
  echo -e "${color}========================================${NC}"
  echo -e "${color}  ${title}${NC}"
  echo -e "${color}========================================${NC}"
  echo ""
}

ask() {
  local prompt="$1" __varname="$2" default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
  else
    while [[ -z "${value:-}" ]]; do read -rp "$prompt: " value; done
  fi
  printf -v "$__varname" '%s' "$value"
}

ask_email() {
  local prompt="$1" __varname="$2" default="${3:-}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -rp "$prompt: " value
    fi
    if [[ "$value" =~ $EMAIL_REGEX ]]; then
      printf -v "$__varname" '%s' "$value"
      return 0
    fi
    warn "That doesn't look like a valid email address. Try again."
  done
}

ssh_works() {
  # `ssh -T git@github.com` exits 1 on success; capture instead of piping to
  # avoid pipefail breaking the check in callers that run under set -o pipefail.
  local output
  output=$(ssh -T \
              -o StrictHostKeyChecking=yes \
              -o ConnectTimeout=5 \
              git@github.com 2>&1 || true)
  echo "$output" | grep -q "successfully authenticated"
}

# ── 1/4 Xcode Command Line Tools ──────────────────────────────────────
section "1/4  Xcode Command Line Tools"

if xcode-select -p &>/dev/null && [[ -d "$(xcode-select -p)" ]]; then
  ok "Xcode Command Line Tools already installed ($(xcode-select -p))"
else
  info "Installing Xcode Command Line Tools — accept the macOS dialog when it appears..."
  xcode-select --install 2>/dev/null || true
  attempt=0
  until xcode-select -p &>/dev/null && [[ -d "$(xcode-select -p)" ]]; do
    attempt=$((attempt + 1))
    if (( attempt > XCODE_MAX_POLL_ATTEMPTS )); then
      echo ""
      err "Xcode CLT didn't install within $((XCODE_MAX_POLL_ATTEMPTS * XCODE_POLL_INTERVAL_S))s."
      err "Open the macOS dialog manually, complete the install, then re-run ./pre-setup.sh"
      exit 1
    fi
    sleep "$XCODE_POLL_INTERVAL_S"
    echo -n "."
  done
  echo ""
  ok "Xcode Command Line Tools installed"
fi

# ── 2/4 SSH key + known_hosts ────────────────────────────────────────
section "2/4  SSH key"

SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
SSH_CONFIG="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

# Pre-seed GitHub host keys. Idempotent — only appends if a github.com
# line isn't already in known_hosts. Closes the TOFU MITM window on a
# fresh Mac with no prior SSH history.
if ! grep -q '^github\.com ' "$KNOWN_HOSTS" 2>/dev/null; then
  info "Pre-seeding GitHub host keys into $KNOWN_HOSTS..."
  printf '%s\n' "$GITHUB_KNOWN_HOSTS" >> "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS"
  ok "GitHub host keys pinned"
else
  ok "GitHub host keys already pinned in known_hosts"
fi

if [[ -f "$SSH_KEY" ]]; then
  ok "SSH key already exists at $SSH_KEY"
else
  info "Generating a new ed25519 key (no passphrase — see README)..."
  ask_email "Enter your work email" GIT_EMAIL
  ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$SSH_KEY" -N ""
  ok "SSH key generated"
fi

if ! grep -qF "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<'SSH_CONF'

# >>> mac-setup: ssh-config >>>
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
# <<< mac-setup: ssh-config <<<
SSH_CONF
  ok "Added github.com block to ~/.ssh/config"
fi
chmod 600 "$SSH_CONFIG"

# Re-use a live ssh-agent if one is already running for this session.
if [[ -z "${SSH_AUTH_SOCK:-}" ]] || ! ssh-add -l &>/dev/null; then
  eval "$(ssh-agent -s)" &>/dev/null
fi
ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null \
  || ssh-add "$SSH_KEY" 2>/dev/null \
  || true

# ── 3/4 Upload to GitHub + verify ────────────────────────────────────
section "3/4  Upload to GitHub"

if ssh_works; then
  ok "GitHub already accepts this key — skipping upload step"
else
  echo ""
  echo -e "${GREEN}Your public key (also copied to clipboard):${NC}"
  echo ""
  cat "$SSH_KEY.pub"
  pbcopy < "$SSH_KEY.pub" 2>/dev/null || true
  echo ""
  echo -e "${YELLOW}Steps:${NC}"
  echo "  1. Open https://github.com/settings/ssh/new"
  echo "  2. Paste the key (it's already in your clipboard)"
  echo "  3. Give it a title (your Mac name works well) and click 'Add SSH key'"
  echo ""

  for attempt in $(seq 1 "$MAX_GITHUB_KEY_ATTEMPTS"); do
    read -rp "Press Enter once the key is added to GitHub... "
    if ssh_works; then
      ok "GitHub now accepts the key"
      break
    fi
    if (( attempt == MAX_GITHUB_KEY_ATTEMPTS )); then
      err "GitHub still doesn't recognise the key after $MAX_GITHUB_KEY_ATTEMPTS attempts."
      err "Check it at https://github.com/settings/keys and re-run pre-setup.sh"
      exit 1
    fi
    warn "Still not authorised — make sure you pasted the whole public key and saved it. Try again."
  done
fi

# ── 4/4 Git identity ─────────────────────────────────────────────────
section "4/4  Git identity"

CURRENT_NAME=$(git config --global user.name 2>/dev/null || true)
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null || true)

if [[ -n "$CURRENT_NAME" ]]; then
  ok "git user.name already set to: $CURRENT_NAME"
else
  ask "Enter your full name for git commits" GIT_NAME
  git config --global user.name "$GIT_NAME"
fi

if [[ -n "$CURRENT_EMAIL" ]]; then
  ok "git user.email already set to: $CURRENT_EMAIL"
else
  ask_email "Enter your work email for git commits" GIT_EMAIL "${GIT_EMAIL:-}"
  git config --global user.email "$GIT_EMAIL"
fi

ok "Git identity: $(git config --global user.name) <$(git config --global user.email)>"

# ── Done ────────────────────────────────────────────────────────────
section "Pre-setup complete!" "$GREEN"
echo "Next: run ./setup.sh to install Homebrew, apps, runtimes, and clone repos."
