# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn/err,
# section, github_ssh_ok.
#
# Clone the Money Means repos a new starter needs.
#
# Repo list comes from one of:
#   - $MAC_SETUP_REPOS env var (whitespace-separated names)
#   - interactive prompt (skipped if --no-clone or MAC_SETUP_REPOS=none)
#
# Repo names are GitHub repos under the moneymeans org. We clone via SSH
# so the user keeps push access without needing a PAT.

readonly REPO_NAME_REGEX='^[A-Za-z0-9._-]+$'

section "Clone Money Means repos"

# ── Choose the work folder ─────────────────────────────────────────────
# Where the user's checked-out repos live. Defaults to ~/work; can be
# overridden via $MAC_SETUP_WORK_DIR (unattended) or the prompt below.
# Exported so later modules (project_bootstrap.sh, the final summary)
# pick up the user's choice instead of hardcoding ~/work.
DEFAULT_WORK_DIR="$HOME/work"
WORK_DIR="${MAC_SETUP_WORK_DIR:-}"

if [[ -z "$WORK_DIR" ]]; then
  if [[ -t 0 ]]; then
    echo "Where should we clone repos to? Press Enter for the default."
    echo ""
    read -rp "Work folder [$DEFAULT_WORK_DIR]: " WORK_DIR
    WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
    echo ""
  else
    WORK_DIR="$DEFAULT_WORK_DIR"
  fi
fi

# Expand ~ and $HOME if the user typed them literally.
WORK_DIR="${WORK_DIR/#\~/$HOME}"
WORK_DIR="${WORK_DIR/#\$HOME/$HOME}"

if [[ "$WORK_DIR" != /* ]]; then
  err "Work folder must be an absolute path (got: '$WORK_DIR')"
  exit 1
fi

mkdir -p "$WORK_DIR"
export WORK_DIR
ok "Using work folder: $WORK_DIR"

if [[ "${MAC_SETUP_REPOS:-}" == "none" ]]; then
  info "MAC_SETUP_REPOS=none — skipping clone step"
  return 0 2>/dev/null || exit 0
fi

REPOS_INPUT="${MAC_SETUP_REPOS:-}"

# If no env var AND no tty, we can't prompt — fail cleanly with guidance
# rather than silently corrupting state by consuming script bytes.
if [[ -z "$REPOS_INPUT" && ! -t 0 ]]; then
  warn "No tty available for interactive prompt. Either run from a clone, or"
  warn "  set MAC_SETUP_REPOS=\"repo1 repo2\" (or MAC_SETUP_REPOS=none to skip)"
  return 0 2>/dev/null || exit 0
fi

if [[ -z "$REPOS_INPUT" ]]; then
  echo "We can clone the Money Means repos you'll be working on now."
  echo ""
  echo "  ⚠️  Ask your buddy / onboarder which repos you need."
  echo "  They'll give you a list of names (under github.com/moneymeans/)."
  echo ""
  printf "  ${BLUE}Option A${NC}  Type the names space-separated and press Enter:\n"
  echo   "             e.g.  some-service api-gateway"
  printf "  ${BLUE}Option B${NC}  Just press Enter to skip — you can clone manually later with:\n"
  echo   "             git clone git@github.com:moneymeans/<repo>.git"
  echo ""
  read -rp "Repos (or press Enter to skip): " REPOS_INPUT
fi

if [[ -z "$REPOS_INPUT" ]]; then
  info "No repos specified — skipping clone step"
  return 0 2>/dev/null || exit 0
fi

if ! github_ssh_ok; then
  err "GitHub SSH access not working. Run ./pre-setup.sh again or add your key at https://github.com/settings/ssh/new"
  exit 1
fi

clone_failed=0

# shellcheck disable=SC2086 -- intentional word-split on whitespace.
for repo in $REPOS_INPUT; do
  if ! [[ "$repo" =~ $REPO_NAME_REGEX ]]; then
    err "Invalid repo name: '$repo' (allowed: letters, digits, '.', '_', '-'). Skipping."
    clone_failed=1
    continue
  fi

  dest="$WORK_DIR/$repo"
  if [[ -d "$dest/.git" ]]; then
    ok "$repo already cloned at $dest"
    continue
  fi
  if [[ -e "$dest" ]]; then
    warn "$dest exists but is not a git repo — skipping"
    clone_failed=1
    continue
  fi

  info "Cloning moneymeans/$repo → $dest"
  if git clone -- "git@github.com:moneymeans/$repo.git" "$dest"; then
    ok "Cloned $repo"
  else
    err "Failed to clone $repo — check the repo name and your access"
    clone_failed=1
  fi
done

if (( clone_failed == 1 )); then
  warn "One or more repos did not clone successfully — scroll up for details."
fi
