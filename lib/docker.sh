# shellcheck shell=bash
# Sourced from setup.sh after common.sh + status.sh. Uses: info/ok/warn/err,
# have, step_ok/step_warn/step_fail.
#
# Get Docker Desktop to the point where `docker info` works, and be honest
# in the final report when it doesn't.
#
# Why this module is more than `open -a Docker`: on a new starter's Mac in
# August 2026, `brew bundle` reported success but Docker.app was never in
# /Applications, so this stage warned once, 800 lines up, and the closing
# banner still claimed "Docker Desktop (daemon running)". It got installed
# by hand days later. Three things were wrong:
#   1. The cask failure was invisible — brew bundle's non-zero exit is a
#      single aggregate warn that doesn't say WHICH cask failed.
#   2. A missing Docker.app was treated as "nothing to do" and returned 0.
#   3. The daemon wait had no verification the CLI worked afterwards.
#
# So now: if the app is missing we try installing the cask right here (the
# common cause is a transient download failure or a mid-bundle password
# prompt that timed out), and every exit path records a step outcome with
# the exact command to finish the job by hand.

readonly DOCKER_WAIT_TIMEOUT_S=120
readonly DOCKER_POLL_INTERVAL_S=2
readonly DOCKER_STEP="Docker Desktop"
readonly DOCKER_CASK="docker-desktop"

# Already fully working? Nothing to do — the common case on a re-run.
if docker info &>/dev/null; then
  ok "Docker daemon is already running"
  step_ok "$DOCKER_STEP" "daemon running"
  return 0 2>/dev/null || exit 0
fi

# ── Make sure the app is actually on disk ──────────────────────────────
# `brew list --cask docker-desktop` and the /Applications check can
# disagree, and the right repair depends on WHICH way round they disagree.
# The cask's own artifact list installs to /Applications/Docker.app, so
# that path is the source of truth for `open -a Docker`.
#
# Docker Desktop can also live elsewhere (a per-user copy under
# ~/Applications, or a hand-dragged .dmg). Reaching here only means
# `docker info` failed, which for those installs usually means "not running
# yet" — not "not installed". Installing a second copy on top would leave
# two Dockers fighting over one daemon, so look before installing.
#
# DOCKER_APP_PATH is set once we have an app to launch; empty means we
# still need to install one.
DOCKER_APP_PATH=""

if [[ -d "/Applications/Docker.app" ]]; then
  DOCKER_APP_PATH="/Applications/Docker.app"
else
  for candidate in "$HOME/Applications/Docker.app" "/Applications/Utilities/Docker.app"; do
    if [[ -d "$candidate" ]]; then
      warn "Docker.app is not in /Applications, but found at $candidate"
      DOCKER_APP_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$DOCKER_APP_PATH" ]]; then
  warn "Docker.app is not in /Applications — brew bundle did not install it"
  info "Attempting to install the $DOCKER_CASK cask now (this can take a few minutes)..."

  # Deliberately NOT `--force`. For casks --force means "overwrite existing
  # files", which is a blind overwrite of whatever is already there — the
  # opposite of idempotent on a machine that is already set up.
  #
  # The case --force was added for is real but narrow: brew still has the
  # cask registered while the app bundle is gone, so a plain `install` exits
  # "already installed" and repairs nothing. `reinstall` fixes exactly that
  # without the overwrite semantics. We know the bundle is absent — checked
  # directly above.
  if brew list --cask "$DOCKER_CASK" &>/dev/null; then
    info "brew still has $DOCKER_CASK registered but the app is gone — reinstalling"
    docker_install_cmd=(brew reinstall --cask "$DOCKER_CASK")
  else
    docker_install_cmd=(brew install --cask "$DOCKER_CASK")
  fi

  if "${docker_install_cmd[@]}"; then
    ok "Docker Desktop cask installed"
  else
    err "Could not install the $DOCKER_CASK cask automatically"
  fi

  # Re-check: the install may have worked, or the app may have arrived by
  # another route (manual .dmg) since brew bundle ran.
  if [[ -d "/Applications/Docker.app" ]]; then
    DOCKER_APP_PATH="/Applications/Docker.app"
  else
    err "Docker.app still missing — the rest of setup will continue without Docker"
    step_fail "$DOCKER_STEP" "not installed (cask install failed)" \
      "brew install --cask docker-desktop  # then: open -a Docker"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── Start the daemon ───────────────────────────────────────────────────
# The app being present does NOT mean the daemon runs — Docker Desktop
# needs a first launch, which may also show a licence-accept dialog and
# ask for a privileged-helper password. Both need a human, so a timeout
# here is a legitimate "needs your attention", not a hard failure.
info "Starting Docker Desktop..."
# Launch the copy we actually found, which may be outside /Applications.
if ! open -a "$DOCKER_APP_PATH"; then
  # A stale drag-copy or partial bundle looks identical to a healthy one on
  # a `-d` check; only `open` can tell the difference.
  err "Could not launch $DOCKER_APP_PATH — it may be an incomplete copy"
  step_warn "$DOCKER_STEP" "found at $DOCKER_APP_PATH but it would not launch" \
    "Move or delete it, then re-run ./setup.sh to install Docker Desktop properly"
  return 0 2>/dev/null || exit 0
fi

info "Waiting for the Docker daemon (up to ${DOCKER_WAIT_TIMEOUT_S}s)..."
poll_attempts=$((DOCKER_WAIT_TIMEOUT_S / DOCKER_POLL_INTERVAL_S))
docker_ready=false
for _ in $(seq 1 "$poll_attempts"); do
  if docker info &>/dev/null; then
    docker_ready=true
    break
  fi
  sleep "$DOCKER_POLL_INTERVAL_S"
  echo -n "."
done
echo ""

if $docker_ready; then
  ok "Docker daemon ready"
  step_ok "$DOCKER_STEP" "daemon running"
  return 0 2>/dev/null || exit 0
fi

# Timed out. Distinguish the two reasons, because the fix differs: no
# `docker` CLI on PATH is a broken/partial install, whereas a present CLI
# that can't reach the daemon is almost always the first-run dialog
# sitting unanswered behind another window.
if ! have docker; then
  warn "The 'docker' CLI is not on PATH — Docker Desktop's first run installs it"
  step_warn "$DOCKER_STEP" "installed, but CLI missing (first run not completed)" \
    "open -a Docker  # accept the licence + privileged-helper prompt, then: docker info"
else
  warn "Docker daemon didn't come up within ${DOCKER_WAIT_TIMEOUT_S}s"
  warn "  Docker Desktop is probably waiting on its first-run dialog (licence / password)"
  step_warn "$DOCKER_STEP" "installed, daemon not running" \
    "open -a Docker  # answer any dialog, wait for the whale icon, then: docker info"
fi
