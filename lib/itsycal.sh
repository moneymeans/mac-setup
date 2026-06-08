# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn.
#
# Configure Itsycal:
#   - Menu-bar clock format:      EEEE - MMMM dd yyyy - H:mm
#   - Hide the calendar icon:     HideIcon = 1   (text only in the menu bar)
#   - Highlight weekdays Mon-Fri: HighlightedDOWs = 62   (bitmask, see below)
#   - Auto-start on login:        added as a macOS Login Item via osascript
#
# Itsycal stores preferences under com.mowglii.ItsycalApp. Most values use
# Apple's NSDateFormatter syntax (ICU-style). HighlightedDOWs is a bitmask
# where bit N = day N of the week starting from Sunday=1:
#   Sun=1, Mon=2, Tue=4, Wed=8, Thu=16, Fri=32, Sat=64
#   Mon-Fri = 2+4+8+16+32 = 62
#
# If Itsycal is running when we write the defaults, it won't pick up the
# changes until next launch. We send a best-effort `killall Itsycal` + `open`
# so re-runs apply immediately.

readonly ITSYCAL_BUNDLE="com.mowglii.ItsycalApp"
readonly ITSYCAL_CLOCK_FORMAT='EEEE - MMMM dd yyyy - H:mm'
readonly ITSYCAL_HIDE_ICON=1
readonly ITSYCAL_HIGHLIGHT_DOWS=62   # Mon-Fri

if [[ ! -d "/Applications/Itsycal.app" ]]; then
  warn "Itsycal not installed — skipping config"
  return 0 2>/dev/null || exit 0
fi

changed=0

current_format=$(defaults read "$ITSYCAL_BUNDLE" ClockFormat 2>/dev/null || true)
if [[ "$current_format" == "$ITSYCAL_CLOCK_FORMAT" ]]; then
  ok "Itsycal clock format already set"
else
  info "Setting Itsycal clock format: $ITSYCAL_CLOCK_FORMAT"
  defaults write "$ITSYCAL_BUNDLE" ClockFormat -string "$ITSYCAL_CLOCK_FORMAT"
  changed=1
fi

current_hide=$(defaults read "$ITSYCAL_BUNDLE" HideIcon 2>/dev/null || echo "")
if [[ "$current_hide" == "$ITSYCAL_HIDE_ICON" ]]; then
  ok "Itsycal HideIcon already set"
else
  info "Setting Itsycal HideIcon = $ITSYCAL_HIDE_ICON"
  defaults write "$ITSYCAL_BUNDLE" HideIcon -int "$ITSYCAL_HIDE_ICON"
  changed=1
fi

current_dows=$(defaults read "$ITSYCAL_BUNDLE" HighlightedDOWs 2>/dev/null || echo "")
if [[ "$current_dows" == "$ITSYCAL_HIGHLIGHT_DOWS" ]]; then
  ok "Itsycal weekday highlight already set"
else
  info "Setting Itsycal HighlightedDOWs = $ITSYCAL_HIGHLIGHT_DOWS (Mon-Fri)"
  defaults write "$ITSYCAL_BUNDLE" HighlightedDOWs -int "$ITSYCAL_HIGHLIGHT_DOWS"
  changed=1
fi

# Auto-start: add to macOS Login Items if not already present. osascript
# returns a comma-separated list; grep -wF avoids partial matches.
if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
    | tr ',' '\n' | grep -qwF "Itsycal"; then
  ok "Itsycal already in Login Items (auto-start)"
else
  info "Adding Itsycal to Login Items (auto-start at login)..."
  if osascript -e 'tell application "System Events" to make new login item at end with properties {path:"/Applications/Itsycal.app", hidden:false}' &>/dev/null; then
    ok "Itsycal added to Login Items"
  else
    warn "Couldn't add Itsycal to Login Items — System Events may not have Accessibility permission. Add manually in System Settings → General → Login Items."
  fi
fi

# Restart Itsycal so changes apply right away.
if (( changed == 1 )) && pgrep -x Itsycal &>/dev/null; then
  info "Restarting Itsycal to apply..."
  killall Itsycal 2>/dev/null || true
  sleep 1
  open -a Itsycal 2>/dev/null || true
fi

ok "Itsycal configured"
