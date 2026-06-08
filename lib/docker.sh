# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: info/ok/warn.
#
# Make sure Docker Desktop is running. brew install --cask docker-desktop
# puts the app in /Applications but does NOT start the daemon. Any
# project-bootstrap step that builds an image will need a live daemon.

readonly DOCKER_WAIT_TIMEOUT_S=120
readonly DOCKER_POLL_INTERVAL_S=2

if docker info &>/dev/null; then
  ok "Docker daemon is already running"
  return 0 2>/dev/null || exit 0
fi

if [[ ! -d "/Applications/Docker.app" ]]; then
  warn "Docker.app not found in /Applications — brew bundle may not have installed it. Skipping daemon-start."
  return 0 2>/dev/null || exit 0
fi

info "Starting Docker Desktop..."
open -a Docker

info "Waiting for the Docker daemon (up to ${DOCKER_WAIT_TIMEOUT_S}s)..."
poll_attempts=$((DOCKER_WAIT_TIMEOUT_S / DOCKER_POLL_INTERVAL_S))
for _ in $(seq 1 "$poll_attempts"); do
  if docker info &>/dev/null; then
    ok "Docker daemon ready"
    return 0 2>/dev/null || exit 0
  fi
  sleep "$DOCKER_POLL_INTERVAL_S"
  echo -n "."
done

echo ""
warn "Docker daemon didn't come up within ${DOCKER_WAIT_TIMEOUT_S}s. Open Docker Desktop manually and re-run setup.sh."
