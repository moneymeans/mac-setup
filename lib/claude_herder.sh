# shellcheck shell=bash
# Sourced from setup.sh after lib/repos.sh. Uses: info/ok/warn, section, have.
#
# Bootstrap claude-herder if it was cloned in the repo step:
#   1. `make install` — sync deps, build assets, etc.
#   2. `make start`   — runs the herder server. Backgrounded so it
#                       doesn't block the rest of setup.sh.
#   3. Poll http://localhost:7682/ until it responds (up to ~20s).
#   4. `open` the URL so the user lands on the herder UI when setup ends.
#
# Skipped silently if claude-herder wasn't cloned. WORK_DIR comes from
# lib/repos.sh; defaults to ~/work if that step was bypassed.
#
# Backgrounding: `make start` typically execs a long-running server.
# We `nohup … &` and `disown` so the parent setup.sh can exit cleanly
# without killing the server. Stdout/stderr go to a log file so we
# don't bury the rest of setup.sh's output, and the user can `tail` it
# if the server misbehaves.

readonly HERDER_PORT=7682
readonly HERDER_URL="http://localhost:${HERDER_PORT}/"
readonly HERDER_WAIT_SECS=20

# Only run if claude-herder is among the cloned repos. We rely on the
# array set by lib/repos.sh; fall back to a directory check for runs
# where repos.sh was bypassed (e.g. --no-clone but the repo's already
# on disk from a prior run).
herder_present=false
if [[ -n "${CLONED_REPOS+x}" ]]; then
  for r in "${CLONED_REPOS[@]}"; do
    if [[ "$r" == "claude-herder" ]]; then
      herder_present=true
      break
    fi
  done
fi
HERDER_DIR="$(work_dir)/claude-herder"
if ! $herder_present && [[ -d "$HERDER_DIR/.git" ]]; then
  herder_present=true
fi

if ! $herder_present; then
  step_skip "claude-herder" "(not cloned)"
  return 0 2>/dev/null || exit 0
fi

section "Bootstrap claude-herder"

# ── Hand the work folder over to herder ────────────────────────────────
# setup.sh already asked "where should we clone repos to?" and got an
# answer. Herder needs exactly the same fact — its BASE_DIR, the parent
# folder each session clone is created inside — and ships no default for
# it on purpose (it is per-machine, so guessing one person's layout would
# be wrong for everyone else, and an empty BASE_DIR is what keeps
# herder's `configured` flag false so the first-run Settings modal opens).
#
# The upshot for a new starter was being asked the same question twice,
# in two different UIs, days apart — and not realising the second one
# existed until sessions wouldn't start. So we seed it here from the
# answer we already have.
#
# Deliberately conservative: we only ever ADD a BASE_DIR line when the
# key is absent. An existing value wins, even when it disagrees with
# WORK_DIR, because on an established machine that value describes ~30
# live session clones and silently repointing it would orphan them. A
# disagreement is surfaced in the final report instead.
HERDER_CONF="$HOME/.claude-sessions.conf"
herder_base_dir="$(work_dir)"

# `KEY="value"`, `KEY=value`, and leading whitespace are all valid in this
# conf format (herder's lib/config.py::_get_conf_value strips quotes), so
# match the key loosely — but only uncommented lines, since the shipped
# example file has a commented `# BASE_DIR="~/Projects"` that must not be
# mistaken for a real setting.
#
# The `|| true` is load-bearing: setup.sh runs under `set -e -o pipefail`,
# and grep exits 1 when it matches nothing. Without it, a conf file that
# has no BASE_DIR line — precisely the new-starter case this whole block
# exists to handle — would abort setup.sh instead of seeding the value.
existing_base_dir=""
if [[ -f "$HERDER_CONF" ]]; then
  existing_base_dir="$(grep -E '^[[:space:]]*BASE_DIR[[:space:]]*=' "$HERDER_CONF" 2>/dev/null \
    | tail -1 \
    | sed -E 's/^[[:space:]]*BASE_DIR[[:space:]]*=[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' \
    || true)"
fi

# Expand a leading ~ so the comparison below isn't fooled by "~/work" vs
# "/Users/x/work" being the same folder written two ways.
existing_expanded="${existing_base_dir/#\~/$HOME}"

if [[ -z "$existing_base_dir" ]]; then
  info "Telling claude-herder to use $herder_base_dir for session clones..."
  # Create the file if absent; herder reads it as plain shell-style KEY=value.
  if [[ ! -f "$HERDER_CONF" ]]; then
    printf '%s\n' \
      "# ~/.claude-sessions.conf — Claude Herder configuration" \
      "# Seeded by mac-setup. Edit freely; herder's Settings screen preserves" \
      "# any keys it doesn't manage itself." \
      "" > "$HERDER_CONF"
  fi
  printf '%s\n' \
    "" \
    "# Parent folder for session clones. Seeded by mac-setup from the work" \
    "# folder you chose during ./setup.sh, so you don't have to pick it again." \
    "BASE_DIR=\"$herder_base_dir\"" >> "$HERDER_CONF"
  ok "Herder BASE_DIR set to $herder_base_dir"
  step_ok "Herder work folder" "BASE_DIR=$herder_base_dir"
elif [[ "$existing_expanded" == "$herder_base_dir" ]]; then
  ok "Herder BASE_DIR already set to $herder_base_dir"
  step_ok "Herder work folder" "BASE_DIR=$herder_base_dir (already set)"
else
  warn "Herder is already configured to use $existing_base_dir for session clones,"
  warn "  but you chose $herder_base_dir as your work folder in this run."
  warn "  Leaving herder's existing setting alone — it may already have clones there."
  step_warn "Herder work folder" \
    "BASE_DIR=$existing_base_dir, work folder=$herder_base_dir" \
    "Change it in herder: Settings → Project → Browse… (or edit BASE_DIR in $HERDER_CONF)"
fi

if [[ ! -f "$HERDER_DIR/Makefile" ]]; then
  warn "No Makefile in $HERDER_DIR — skipping herder bootstrap"
  step_fail "claude-herder" "no Makefile in $HERDER_DIR (bad clone?)" \
    "rm -rf $HERDER_DIR && ./setup.sh"
  return 0 2>/dev/null || exit 0
fi

# Already running? Don't double-start.
if curl -fsS --max-time 2 "$HERDER_URL" &>/dev/null; then
  ok "claude-herder already responding at $HERDER_URL"
  step_ok "claude-herder" "running at $HERDER_URL"
  open "$HERDER_URL" 2>/dev/null || true
  return 0 2>/dev/null || exit 0
fi

info "Running 'make install' in claude-herder..."
if ! (cd "$HERDER_DIR" && make install); then
  warn "claude-herder 'make install' reported issues. Re-run: cd $HERDER_DIR && make install"
  step_fail "claude-herder" "'make install' failed" \
    "cd $HERDER_DIR && make install"
  return 0 2>/dev/null || exit 0
fi
ok "claude-herder install complete"

# `make start` runs the server. We push it into the background so the
# rest of setup.sh can continue; stdout+stderr land in a log the user
# can tail. nohup + disown survive the parent shell's exit.
HERDER_LOG="$HOME/.claude-herder-start.log"
info "Starting claude-herder in the background (log: $HERDER_LOG)..."
(
  cd "$HERDER_DIR" || exit 1
  nohup make start </dev/null >"$HERDER_LOG" 2>&1 &
  disown
)

# Poll the port until it's up. curl --max-time per attempt keeps us
# from blocking on a hung server forever.
ok "Waiting up to ${HERDER_WAIT_SECS}s for $HERDER_URL ..."
for (( i=0; i<HERDER_WAIT_SECS; i++ )); do
  if curl -fsS --max-time 2 "$HERDER_URL" &>/dev/null; then
    ok "claude-herder is up at $HERDER_URL"
    step_ok "claude-herder" "running at $HERDER_URL"
    open "$HERDER_URL" 2>/dev/null || true
    return 0 2>/dev/null || exit 0
  fi
  sleep 1
done

warn "claude-herder didn't respond at $HERDER_URL within ${HERDER_WAIT_SECS}s."
warn "  Check the log: tail -f $HERDER_LOG"
warn "  Or restart manually: cd $HERDER_DIR && make start"
step_warn "claude-herder" "installed but not responding on port $HERDER_PORT" \
  "tail -50 $HERDER_LOG   # then: cd $HERDER_DIR && make start"
