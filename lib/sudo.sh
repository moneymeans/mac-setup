# shellcheck shell=bash
# Sourced from setup.sh after preflight. Uses: info/ok.
#
# Several brew casks (Docker Desktop, Microsoft Teams, etc.) shell out to
# `sudo /usr/sbin/installer` mid-install. We pre-warm the sudo timestamp
# once at the start of setup.sh and keep it alive with a background loop.
#
# Key detail: macOS sudo defaults to `tty_tickets`, meaning each tty/pgrp
# has its own timestamp. The keep-alive MUST run in the same process
# group as setup.sh so its `sudo -nv` refreshes the same timestamp that
# brew bundle's child sudo calls will see.
#
# Two corrections from the previous version:
#  - `sudo -nv` (validate) instead of `sudo -n true` — -v refreshes the
#    timestamp, true just consumes it.
#  - No `( ... )` subshell around the loop — & directly from the parent
#    keeps process-group/tty inheritance intact.
#
# Even with all that, some PKG installers (Microsoft Teams in particular)
# run their own sudo invocation that ignores cached timestamps. Expect
# 1-2 prompts during brew bundle on a truly fresh machine — but far fewer
# than without this prewarm.

if sudo -nv 2>/dev/null; then
  ok "sudo timestamp already cached"
else
  info "Caching sudo credentials (one-time prompt — reduces password prompts during brew bundle)..."
  sudo -v
fi

# Background keep-alive. `sudo -nv` extends the timestamp without prompting;
# fails (exit non-zero) if the timestamp expired, at which point we just
# stop trying — the cask installer will prompt directly.
while true; do
  sudo -nv 2>/dev/null || break
  sleep 60
  kill -0 "$$" 2>/dev/null || break
done &
SUDO_KEEPALIVE_PID=$!

# Make sure the keepalive dies when setup.sh does. The trap is additive
# so the existing tempdir-cleanup trap from setup.sh still runs.
_existing_exit_trap=$(trap -p EXIT | sed -E "s/^trap -- '//;s/' EXIT\$//")
trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true; ${_existing_exit_trap:-:}" EXIT

ok "sudo keep-alive running (PID $SUDO_KEEPALIVE_PID)"
