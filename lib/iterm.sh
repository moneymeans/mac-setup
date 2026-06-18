# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: info/ok/warn.
#
# Push users gently but firmly toward iTerm2:
#
#   1. Skip iTerm's first-run wizard (SUHasLaunchedBefore).
#   2. Disable iTerm's "we're not your default terminal" prompt
#      (NoSyncNeverRemindPrefsChanges).
#   3. Add iTerm to macOS Login Items so it autostarts at every login.
#      This is the closest we can get to "force" — short of replacing
#      Terminal.app's LaunchServices binding, which Apple doesn't
#      expose to user-space scripts. After this runs, every login
#      brings up iTerm whether the user thinks to open it or not.
#
# setup.sh's closing block also `open -a iTerm`s so the very first
# terminal the user sees after our run is iTerm, not Terminal.app.

readonly ITERM_BUNDLE="com.googlecode.iterm2"

if [[ ! -d "/Applications/iTerm.app" ]]; then
  warn "iTerm.app not installed — skipping config (was the Brewfile run?)"
  return 0 2>/dev/null || exit 0
fi

changed=0

set_iterm_int() {
  local key="$1" want="$2" label="$3"
  local current
  current=$(defaults read "$ITERM_BUNDLE" "$key" 2>/dev/null || echo "")
  if [[ "$current" == "$want" ]]; then
    ok "iTerm2: $label already set"
  else
    info "iTerm2: setting $label ($key=$want)"
    defaults write "$ITERM_BUNDLE" "$key" -int "$want"
    changed=1
  fi
}

set_iterm_int SUHasLaunchedBefore       1 "skip first-run wizard"
set_iterm_int NoSyncNeverRemindPrefsChanges 1 "suppress prefs-changed nags"

# Add iTerm to Login Items. Same pattern as Itsycal / Rectangle.
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
    | tr ',' '\n' | grep -qwF "iTerm"; then
  ok "iTerm already in Login Items"
else
  info "Adding iTerm to Login Items (auto-start at login)..."
  if osascript -e 'tell application "System Events" to make new login item at end with properties {path:"/Applications/iTerm.app", hidden:false}' &>/dev/null; then
    ok "iTerm added to Login Items"
  else
    warn "Couldn't add iTerm to Login Items — System Events may not have Accessibility permission. Add manually in System Settings → General → Login Items."
  fi
fi

ok "iTerm2 configured"
