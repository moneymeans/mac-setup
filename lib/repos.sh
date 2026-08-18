# shellcheck shell=bash
# Sourced from setup.sh after common.sh + status.sh. Uses: have,
# info/ok/warn/err, section, github_ssh_ok, github_org_access,
# print_sso_instructions, step_ok/step_warn/step_fail/step_skip.
#
# Clone the Money Means repos a new starter needs.
#
# Repo list comes from one of:
#   - $MAC_SETUP_REPOS env var (whitespace-separated names)
#   - interactive prompt (default: claude-herder alone if the user just
#     hits Enter; skipped if --no-clone or MAC_SETUP_REPOS=none)
#
# MoneyStory is deliberately NOT in the default set: claude-herder clones
# it itself during its own bootstrap, so cloning it here would duplicate
# work and leave two sources of truth for where the checkout lives.
#
# Repo names are GitHub repos under the moneymeans org. We clone via SSH
# so the user keeps push access without needing a PAT.
#
# Side effect: after a successful MoneyStory clone, the absolute path of
# the clone is added to ~/.claude-sessions-projects (one path per line,
# idempotent). claude-sessions reads that file to populate its project
# picker; without the entry MoneyStory won't show up there. Only mutated
# if the file already exists — we don't create it from scratch. This only
# fires if the user names MoneyStory explicitly; the herder-managed clone
# is registered by herder.

readonly REPO_NAME_REGEX='^[A-Za-z0-9._-]+$'
readonly DEFAULT_REPOS="claude-herder"
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
  step_skip "Repo clone" "(MAC_SETUP_REPOS=none)"
  return 0 2>/dev/null || exit 0
fi

REPOS_INPUT="${MAC_SETUP_REPOS:-}"

# If no env var AND no tty, we can't prompt — fail cleanly with guidance
# rather than silently corrupting state by consuming script bytes.
if [[ -z "$REPOS_INPUT" && ! -t 0 ]]; then
  warn "No tty available for interactive prompt. Either run from a clone, or"
  warn "  set MAC_SETUP_REPOS=\"repo1 repo2\" (or MAC_SETUP_REPOS=none to skip)"
  step_warn "Repo clone" "no tty to prompt for the repo list" \
    "MAC_SETUP_REPOS=\"claude-herder\" ./setup.sh"
  return 0 2>/dev/null || exit 0
fi

if [[ -z "$REPOS_INPUT" ]]; then
  echo "We can clone the Money Means repos you'll be working on now."
  echo ""
  printf "  ${BLUE}Default${NC}   Press Enter to clone the standard set:\n"
  echo   "             $DEFAULT_REPOS"
  echo   "             (MoneyStory is cloned by claude-herder itself)"
  printf "  ${BLUE}Custom${NC}    Type names space-separated to override:\n"
  echo   "             e.g.  claude-herder api-gateway"
  printf "  ${BLUE}Skip${NC}      Type 'none' to skip (clone later with"
  echo   " git clone git@github.com:${GITHUB_ORG}/<repo>.git)"
  echo ""
  read -rp "Repos [$DEFAULT_REPOS]: " REPOS_INPUT
  REPOS_INPUT="${REPOS_INPUT:-$DEFAULT_REPOS}"
fi

if [[ "$REPOS_INPUT" == "none" ]]; then
  info "Skipping repo clone (explicit 'none')"
  step_skip "Repo clone" "(you chose 'none')"
  return 0 2>/dev/null || exit 0
fi

# ── Prove we can actually READ org repos before trying to clone ────────
# Two distinct gates, because they fail for different reasons and have
# different fixes:
#   github_ssh_ok    — is the key on the account at all?
#   github_org_access — may that key read moneymeans repos? Our org enforces
#                       SAML SSO, which needs a SECOND authorisation per key.
#
# The August 2026 new-starter failure was entirely in the second gate: the
# key was on the account (so the old check passed), pre-setup had said all
# was well, and then every clone died on an SSO error nobody recognised.
# Checking up front means we explain it ONCE, before N failed clones.
if ! github_ssh_ok; then
  err "GitHub SSH access not working. Run ./pre-setup.sh again or add your key at https://github.com/settings/ssh/new"
  step_fail "Repo clone" "GitHub SSH not working" \
    "./pre-setup.sh   # regenerates + re-verifies your key"
  return 0 2>/dev/null || exit 0
fi

# Loop so the user can fix SSO in the browser and retry without having to
# restart a 30-minute setup run from the top.
#
# Bounded on purpose. Each pass blocks on `read`, so a human can always
# escape with 's' — but two things could otherwise spin this forever with
# no pause: stdin closing mid-run (read returns EOF immediately, forever)
# and a user who keeps retrying without fixing anything. Both end up as a
# reported failure rather than a wedged terminal.
readonly MAX_SSO_RETRIES=10
sso_attempts=0
org_state="$(github_org_access)"
while [[ "$org_state" != "ok" ]]; do
  sso_attempts=$(( sso_attempts + 1 ))
  if (( sso_attempts > MAX_SSO_RETRIES )); then
    warn "Giving up on the org-access check after $MAX_SSO_RETRIES attempts."
    step_fail "Repo clone" "no ${GITHUB_ORG} access after $MAX_SSO_RETRIES attempts" \
      "Authorise your key at https://github.com/settings/keys (Configure SSO → Authorize), then: ./setup.sh"
    return 0 2>/dev/null || exit 0
  fi
  case "$org_state" in
    sso)
      section "Your SSH key needs SSO authorisation" "$YELLOW"
      err "GitHub accepts your key, but it is not authorised for the ${GITHUB_ORG} org."
      echo ""
      echo "This is the single most common thing to go wrong here, and it is NOT"
      echo "a problem with your key or this script — GitHub needs one extra click."
      print_sso_instructions
      ;;
    denied)
      section "Cannot read ${GITHUB_ORG} repos" "$YELLOW"
      err "Your key authenticates with GitHub, but ${GITHUB_ORG} repos are refused."
      echo ""
      echo "Most likely one of:"
      echo "  • The key isn't SSO-authorised for the org (see the steps below)."
      echo "  • You're not a member of ${GITHUB_ORG} yet — check"
      echo "    https://github.com/orgs/${GITHUB_ORG}/people and ask your buddy for"
      echo "    an invite if you're not listed."
      print_sso_instructions
      ;;
    offline)
      section "Can't reach github.com" "$YELLOW"
      err "Network problem talking to github.com — check your connection or VPN."
      echo ""
      ;;
  esac

  if [[ ! -t 0 ]]; then
    step_fail "Repo clone" "no org access ($org_state), not interactive" \
      "./setup.sh   # re-run once SSO is authorised"
    return 0 2>/dev/null || exit 0
  fi

  echo "  Options:"
  echo "    [Enter]  retry the check once you've fixed it"
  echo "    s        skip cloning and carry on with the rest of setup"
  echo "    a        ask Claude Code to diagnose it for you"
  echo ""
  # A failed read means EOF (stdin closed under us) — treat it as "skip"
  # rather than looping instantly on an empty answer.
  if ! read -rp "Your choice [Enter/s/a]: " sso_choice; then
    warn "Input closed — skipping repo clone"
    step_fail "Repo clone" "skipped, no ${GITHUB_ORG} access (input closed)" \
      "./setup.sh   # re-run after authorising your key for SSO"
    return 0 2>/dev/null || exit 0
  fi

  case "$sso_choice" in
    s|S)
      warn "Skipping repo clone — no org access yet"
      step_fail "Repo clone" "skipped, no ${GITHUB_ORG} access" \
        "./setup.sh   # re-run after authorising your key for SSO"
      return 0 2>/dev/null || exit 0
      ;;
    a|A)
      # Hand the user a command that carries the real diagnostic context,
      # rather than making them describe a problem they don't understand.
      echo ""
      echo "Run this in another terminal window, then come back and press Enter:"
      echo ""
      echo -e "  ${GREEN}claude \"git clone from ${GITHUB_ORG} is failing. Diagnose it: run"
      echo -e "    ssh -T git@github.com and git ls-remote git@github.com:${GITHUB_ORG}/${GITHUB_SSO_PROBE_REPO}.git,"
      echo -e "    read the errors, and tell me exactly what to fix.\"${NC}"
      echo ""
      ;;
  esac

  org_state="$(github_org_access)"
  if [[ "$org_state" == "ok" ]]; then
    ok "Org access confirmed — carrying on with the clone"
  fi
done

clone_failed=0
# Names of repos that failed, split by cause: SSO-blocked ones share a
# single remediation, so the report can say "authorise your key" once
# instead of repeating it per repo.
FAILED_REPOS=()
SSO_BLOCKED_REPOS=()
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

# Intentional word-split on whitespace.
# shellcheck disable=SC2086
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

  info "Cloning ${GITHUB_ORG}/$repo → $dest"
  # Capture stderr so a failure can be classified rather than just echoed.
  # A mid-loop SSO failure is possible even after the up-front check (a
  # token can expire, or the repo may be one the user lacks rights to),
  # and the fix differs completely from a typo'd repo name.
  clone_err="$(git clone -- "git@github.com:${GITHUB_ORG}/$repo.git" "$dest" 2>&1)" && clone_rc=0 || clone_rc=$?
  if (( clone_rc == 0 )); then
    ok "Cloned $repo"
    CLONED_REPOS+=("$repo")
    if [[ "$repo" == "MoneyStory" ]]; then register_claude_session "$dest"; fi
  else
    echo "$clone_err" >&2
    if echo "$clone_err" | grep -qiE 'saml|single.sign.on|sso'; then
      err "$repo was refused because your key isn't SSO-authorised for ${GITHUB_ORG}"
      print_sso_instructions
      SSO_BLOCKED_REPOS+=("$repo")
    elif echo "$clone_err" | grep -qi 'repository not found'; then
      err "moneymeans/$repo doesn't exist, or your account can't see it — check the name"
    else
      err "Failed to clone $repo — see the error above"
    fi
    FAILED_REPOS+=("$repo")
    clone_failed=1
    # A partial clone leaves a directory behind that would be mistaken for
    # a good checkout on the next run (and skipped). Remove it.
    [[ -d "$dest" && ! -d "$dest/.git" ]] && rm -rf "$dest"
  fi
done

if (( clone_failed == 1 )); then
  warn "One or more repos did not clone successfully — scroll up for details."
  if (( ${#SSO_BLOCKED_REPOS[@]} > 0 )); then
    step_fail "Repo clone" "SSO-blocked: ${SSO_BLOCKED_REPOS[*]}" \
      "Authorise your key at https://github.com/settings/keys (Configure SSO → Authorize), then: ./setup.sh"
  else
    step_fail "Repo clone" "failed: ${FAILED_REPOS[*]}" \
      "cd ${WORK_DIR} && git clone git@github.com:${GITHUB_ORG}/<repo>.git"
  fi
elif (( ${#CLONED_REPOS[@]} > 0 )); then
  step_ok "Repo clone" "${CLONED_REPOS[*]} → $WORK_DIR"
else
  step_skip "Repo clone" "(nothing requested)"
fi

unset -f register_claude_session
