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
HERDER_DIR="${WORK_DIR:-$HOME/work}/claude-herder"
if ! $herder_present && [[ -d "$HERDER_DIR/.git" ]]; then
  herder_present=true
fi

if ! $herder_present; then
  return 0 2>/dev/null || exit 0
fi

section "Bootstrap claude-herder"

if [[ ! -f "$HERDER_DIR/Makefile" ]]; then
  warn "No Makefile in $HERDER_DIR — skipping herder bootstrap"
  return 0 2>/dev/null || exit 0
fi

# Already running? Don't double-start.
if curl -fsS --max-time 2 "$HERDER_URL" &>/dev/null; then
  ok "claude-herder already responding at $HERDER_URL"
  open "$HERDER_URL" 2>/dev/null || true
  return 0 2>/dev/null || exit 0
fi

info "Running 'make install' in claude-herder..."
if ! (cd "$HERDER_DIR" && make install); then
  warn "claude-herder 'make install' reported issues. Re-run: cd $HERDER_DIR && make install"
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
    open "$HERDER_URL" 2>/dev/null || true
    return 0 2>/dev/null || exit 0
  fi
  sleep 1
done

warn "claude-herder didn't respond at $HERDER_URL within ${HERDER_WAIT_SECS}s."
warn "  Check the log: tail -f $HERDER_LOG"
warn "  Or restart manually: cd $HERDER_DIR && make start"
