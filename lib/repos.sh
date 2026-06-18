# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn/err,
# section, github_ssh_ok.
#
# Clone the Money Means repos a new starter needs.
#
# Repo list comes from one of:
#   - $MAC_SETUP_REPOS env var (whitespace-separated names)
#   - interactive prompt (default: claude-herder + MoneyStory if the
#     user just hits Enter; skipped if --no-clone or MAC_SETUP_REPOS=none)
#
# Repo names are GitHub repos under the moneymeans org. We clone via SSH
# so the user keeps push access without needing a PAT.
#
# Side effect: after a successful MoneyStory clone, the absolute path of
# the clone is added to ~/.claude-sessions-projects (one path per line,
# idempotent). claude-sessions reads that file to populate its project
# picker; without the entry MoneyStory won't show up there. Only mutated
# if the file already exists — we don't create it from scratch.

readonly REPO_NAME_REGEX='^[A-Za-z0-9._-]+$'
readonly DEFAULT_REPOS="claude-herder MoneyStory"
readonly CLAUDE_SESSIONS_FILE="$HOME/.claude-sessions-projects"

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
  printf "  ${BLUE}Default${NC}   Press Enter to clone the standard set:\n"
  echo   "             $DEFAULT_REPOS"
  printf "  ${BLUE}Custom${NC}    Type names space-separated to override:\n"
  echo   "             e.g.  claude-herder MoneyStory api-gateway"
  printf "  ${BLUE}Skip${NC}      Type 'none' to skip (clone later with"
  echo   " git clone git@github.com:moneymeans/<repo>.git)"
  echo ""
  read -rp "Repos [$DEFAULT_REPOS]: " REPOS_INPUT
  REPOS_INPUT="${REPOS_INPUT:-$DEFAULT_REPOS}"
fi

if [[ "$REPOS_INPUT" == "none" ]]; then
  info "Skipping repo clone (explicit 'none')"
  return 0 2>/dev/null || exit 0
fi

if ! github_ssh_ok; then
  err "GitHub SSH access not working. Run ./pre-setup.sh again or add your key at https://github.com/settings/ssh/new"
  exit 1
fi

clone_failed=0
# Tracks which repos ended up present in $WORK_DIR after this stage.
# Same-shell scope (lib/*.sh is sourced, not exec'd), so the next module
# can check `MoneyStory in CLONED_REPOS` without an env-var dance.
CLONED_REPOS=()

# Register a repo path with claude-sessions if (a) the sessions file
# already exists (we don't create it — that's claude-sessions' job), and
# (b) the path isn't already listed. -xF = exact-line, fixed-string match.
register_claude_session() {
  local path="$1"
  [[ -f "$CLAUDE_SESSIONS_FILE" ]] || return 0
  if grep -qxF "$path" "$CLAUDE_SESSIONS_FILE"; then
    ok "$path already registered in claude-sessions"
  else
    info "Registering $path in $CLAUDE_SESSIONS_FILE"
    printf '%s\n' "$path" >> "$CLAUDE_SESSIONS_FILE"
    ok "Added $path to claude-sessions"
  fi
}

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
    CLONED_REPOS+=("$repo")
    if [[ "$repo" == "MoneyStory" ]]; then register_claude_session "$dest"; fi
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
    CLONED_REPOS+=("$repo")
    if [[ "$repo" == "MoneyStory" ]]; then register_claude_session "$dest"; fi
  else
    err "Failed to clone $repo — check the repo name and your access"
    clone_failed=1
  fi
done

if (( clone_failed == 1 )); then
  warn "One or more repos did not clone successfully — scroll up for details."
fi

unset -f register_claude_session
