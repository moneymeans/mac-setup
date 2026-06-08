# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn, section.
#
# Bootstrap a project the user cloned in the previous step.
#
# Activates only if $MAC_SETUP_PROJECT is set AND $HOME/work/$MAC_SETUP_PROJECT
# exists. The buddy onboarding a new starter is responsible for telling them
# which project name to set, and for documenting the project's own bootstrap
# expectations (config files, tmux sessions, etc.) in that project's README.
#
# This module:
#   1. Copies $HOME/work/$MAC_SETUP_PROJECT/<config>.example to $HOME/<config>
#      if BOTH the example exists AND the target doesn't. Filename comes from
#      $MAC_SETUP_PROJECT_CONFIG (optional).
#   2. Creates a detached tmux session named $MAC_SETUP_PROJECT_TMUX (optional).
#   3. Verifies the Docker daemon is up if $MAC_SETUP_PROJECT_NEEDS_DOCKER=1.
#   4. Runs `make install` if a Makefile exists, but only when the venv (if
#      any) is older than the project's requirements*.txt / pyproject.toml.

if [[ -z "${MAC_SETUP_PROJECT:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

PROJECT_DIR="$HOME/work/$MAC_SETUP_PROJECT"
PROJECT_VENV="$PROJECT_DIR/.venv"

if [[ ! -d "$PROJECT_DIR" ]]; then
  return 0 2>/dev/null || exit 0
fi

section "Bootstrap $MAC_SETUP_PROJECT"

# ── config file ────────────────────────────────────────────────────────
if [[ -n "${MAC_SETUP_PROJECT_CONFIG:-}" ]]; then
  TARGET="$HOME/$MAC_SETUP_PROJECT_CONFIG"
  EXAMPLE="$PROJECT_DIR/${MAC_SETUP_PROJECT_CONFIG}.example"
  if [[ -f "$TARGET" ]]; then
    ok "$TARGET already exists (not overwritten)"
  elif [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$TARGET"
    ok "Created $TARGET from example — edit it to match your project"
  else
    warn "No example config at $EXAMPLE — skipping"
  fi
fi

# ── tmux session ───────────────────────────────────────────────────────
if [[ -n "${MAC_SETUP_PROJECT_TMUX:-}" ]]; then
  if have tmux; then
    if tmux has-session -t "$MAC_SETUP_PROJECT_TMUX" 2>/dev/null; then
      ok "tmux session '$MAC_SETUP_PROJECT_TMUX' already exists"
    else
      info "Creating tmux session '$MAC_SETUP_PROJECT_TMUX' (detached)..."
      tmux new-session -d -s "$MAC_SETUP_PROJECT_TMUX"
      ok "tmux session '$MAC_SETUP_PROJECT_TMUX' created"
    fi
  else
    warn "tmux not on PATH — skipping session creation"
  fi
fi

# ── Docker daemon prerequisite ─────────────────────────────────────────
if [[ "${MAC_SETUP_PROJECT_NEEDS_DOCKER:-0}" == "1" ]] && ! docker info &>/dev/null; then
  warn "Docker daemon not running — skipping 'make install'."
  warn "Start Docker Desktop, then re-run: cd $PROJECT_DIR && make install"
  return 0 2>/dev/null || exit 0
fi

# ── make install (with simple staleness check) ─────────────────────────
needs_install=true
if [[ -f "$PROJECT_VENV/pyvenv.cfg" ]]; then
  newest_req=$(
    find "$PROJECT_DIR" -maxdepth 2 \
         \( -name 'requirements*.txt' -o -name 'pyproject.toml' \) \
         -newer "$PROJECT_VENV/pyvenv.cfg" -print -quit 2>/dev/null
  )
  if [[ -z "$newest_req" ]]; then
    needs_install=false
  fi
fi

if ! $needs_install; then
  ok "$MAC_SETUP_PROJECT already bootstrapped (.venv up to date with requirements)"
  return 0 2>/dev/null || exit 0
fi

if [[ -f "$PROJECT_DIR/Makefile" ]]; then
  info "Running 'make install' in $MAC_SETUP_PROJECT..."
  if (cd "$PROJECT_DIR" && make install); then
    ok "$MAC_SETUP_PROJECT install complete"
  else
    warn "$MAC_SETUP_PROJECT install reported issues. Re-run: cd $PROJECT_DIR && make install"
  fi
fi
