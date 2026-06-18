# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: info/ok/warn.
#
# Configure Rectangle (window-snapping app, installed via Brewfile).
# On first launch Rectangle pops a wizard that asks the user to choose
# between Recommended (⌥⌘ + arrows) and Spectacle keybindings, then
# nags for accessibility permission. We pre-set the prefs that skip
# the wizard so the user gets straight-to-useful behaviour.
#
# Settings shipped as team defaults:
#   - launchOnLogin           = 1  (auto-start at login)
#   - SUHasLaunchedBefore     = 1  (skip the first-run welcome wizard)
#   - alternateDefaultShortcuts = 1  (turn on the Recommended preset —
#                                    skips the choose-your-keybindings step)
#   - allowAnyShortcut        = 1  (allow non-modifier keys when users
#                                  customise their own bindings later)
#   - subsequentExecutionMode = 1  (smart cycle on repeated keypresses —
#                                  Rectangle's most useful behaviour)
#
# Personal hotkey overrides (maximize, reflowTodo, etc.) are deliberately
# NOT shipped — each user picks their own. Same goes for the Spectacle
# vs Recommended preference: we just pick Recommended for the default
# user, they can switch later in the app's preferences.
#
# Like Itsycal: if Rectangle is running when we write the defaults, it
# won't pick them up until next launch. We send a best-effort restart.

readonly RECTANGLE_BUNDLE="com.knollsoft.Rectangle"

if [[ ! -d "/Applications/Rectangle.app" ]]; then
  warn "Rectangle not installed — skipping config (was it in the Brewfile run?)"
  return 0 2>/dev/null || exit 0
fi

changed=0

# Idempotently set an integer pref. Skips the write (and the "changed=1"
# trigger) when the current value already matches.
set_rect_int() {
  local key="$1" want="$2" label="$3"
  local current
  current=$(defaults read "$RECTANGLE_BUNDLE" "$key" 2>/dev/null || echo "")
  if [[ "$current" == "$want" ]]; then
    ok "Rectangle: $label already set"
  else
    info "Rectangle: setting $label ($key=$want)"
    defaults write "$RECTANGLE_BUNDLE" "$key" -int "$want"
    changed=1
  fi
}

set_rect_int launchOnLogin             1 "launch at login"
set_rect_int SUHasLaunchedBefore       1 "skip first-run wizard"
set_rect_int alternateDefaultShortcuts 1 "recommended keybindings preset"
set_rect_int allowAnyShortcut          1 "allow any shortcut (for later customisation)"
set_rect_int subsequentExecutionMode   1 "smart cycle on repeated keypresses"

# Add to macOS Login Items (belt and braces — launchOnLogin=1 already
# tells Rectangle itself to register, but the Login Item entry is what
# survives a Rectangle uninstall/reinstall cleanly).
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
    | tr ',' '\n' | grep -qwF "Rectangle"; then
  ok "Rectangle already in Login Items"
else
  info "Adding Rectangle to Login Items..."
  if osascript -e 'tell application "System Events" to make new login item at end with properties {path:"/Applications/Rectangle.app", hidden:true}' &>/dev/null; then
    ok "Rectangle added to Login Items"
  else
    warn "Couldn't add Rectangle to Login Items — System Events may not have Accessibility permission. Add manually in System Settings → General → Login Items."
  fi
fi

# Restart so changes apply now. Skip if nothing changed.
if (( changed == 1 )) && pgrep -x Rectangle &>/dev/null; then
  info "Restarting Rectangle to apply..."
  killall Rectangle 2>/dev/null || true
  sleep 1
  open -a Rectangle 2>/dev/null || true
fi

ok "Rectangle configured"
