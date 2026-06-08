# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: info/ok/warn, section.
#
# Apply opinionated macOS defaults that every Money Means dev wants:
#   - Fast key repeat + short initial delay (the keyboard preference pane's
#     "Fast" / "Short" sliders maxed out)
#   - Disable press-and-hold accent menu so holding a key actually repeats
#   - Finder shows file extensions + path bar + status bar
#   - Firewall on + stealth mode (don't respond to ping from random hosts)
#   - Require password immediately after screensaver/sleep
#
# Every setting checks the current value first and only writes if it's
# wrong. Safe to re-run.
#
# The firewall and screensaver settings need sudo. They're at the end so
# if sudo isn't available we still get the user-level settings applied.

section "macOS defaults (security + dev quality-of-life)"

# ── Keyboard ────────────────────────────────────────────────────────────
readonly KEY_REPEAT=2          # 2 = "Fast" max
readonly INITIAL_KEY_REPEAT=15 # 15 = "Short" max

current=$(defaults read -g KeyRepeat 2>/dev/null || echo "")
if [[ "$current" == "$KEY_REPEAT" ]]; then
  ok "Key repeat rate already fast ($KEY_REPEAT)"
else
  info "Setting key repeat rate to fast ($KEY_REPEAT)"
  defaults write -g KeyRepeat -int "$KEY_REPEAT"
fi

current=$(defaults read -g InitialKeyRepeat 2>/dev/null || echo "")
if [[ "$current" == "$INITIAL_KEY_REPEAT" ]]; then
  ok "Initial key repeat delay already short ($INITIAL_KEY_REPEAT)"
else
  info "Setting initial key repeat delay to short ($INITIAL_KEY_REPEAT)"
  defaults write -g InitialKeyRepeat -int "$INITIAL_KEY_REPEAT"
fi

# Holding a key repeats instead of showing the accent-character menu.
current=$(defaults read -g ApplePressAndHoldEnabled 2>/dev/null || echo "")
if [[ "$current" == "0" ]]; then
  ok "Press-and-hold accent menu already disabled"
else
  info "Disabling press-and-hold accent menu (holding a key now repeats)"
  defaults write -g ApplePressAndHoldEnabled -bool false
fi

# ── Finder ──────────────────────────────────────────────────────────────
current=$(defaults read NSGlobalDomain AppleShowAllExtensions 2>/dev/null || echo "")
if [[ "$current" == "1" ]]; then
  ok "Finder already shows all file extensions"
else
  info "Finder: show all file extensions"
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
fi

current=$(defaults read com.apple.finder ShowPathbar 2>/dev/null || echo "")
if [[ "$current" == "1" ]]; then
  ok "Finder path bar already shown"
else
  info "Finder: show path bar"
  defaults write com.apple.finder ShowPathbar -bool true
fi

current=$(defaults read com.apple.finder ShowStatusBar 2>/dev/null || echo "")
if [[ "$current" == "1" ]]; then
  ok "Finder status bar already shown"
else
  info "Finder: show status bar"
  defaults write com.apple.finder ShowStatusBar -bool true
fi

# Restart Finder if any of its prefs changed. Best-effort — if Finder is
# busy or the user is in the middle of a copy this might fail; harmless.
killall Finder 2>/dev/null || true

# ── Screen lock ────────────────────────────────────────────────────────
# Require password immediately when the screensaver kicks in or the
# machine sleeps. The default is "5 seconds" which is enough to grab a
# laptop off a desk and skip the lock entirely.
current=$(defaults read com.apple.screensaver askForPassword 2>/dev/null || echo "")
if [[ "$current" == "1" ]]; then
  ok "Screen lock: password required on wake (already set)"
else
  info "Screen lock: require password on wake"
  defaults write com.apple.screensaver askForPassword -int 1
fi

current=$(defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || echo "")
if [[ "$current" == "0" ]]; then
  ok "Screen lock: immediate (already set)"
else
  info "Screen lock: 0s delay (immediate)"
  defaults write com.apple.screensaver askForPasswordDelay -int 0
fi

# ── Firewall ────────────────────────────────────────────────────────────
# Application firewall: block inbound connections except for signed apps
# that the user has approved. Stealth mode = don't respond to pings or
# probes from arbitrary hosts (makes the machine invisible on hostile
# networks like cafe wifi).
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

if [[ ! -x "$FW" ]]; then
  warn "Application firewall binary missing — skipping (macOS version mismatch?)"
elif ! sudo -n true 2>/dev/null; then
  # No cached sudo (the prewarm in lib/sudo.sh expired or never ran).
  # Skip silently rather than block on a password prompt mid-script.
  warn "sudo timestamp expired — skipping firewall config. Re-run setup.sh to enable."
else
  if sudo -n "$FW" --getglobalstate 2>/dev/null | grep -q "enabled"; then
    ok "Firewall already enabled"
  else
    info "Enabling firewall"
    sudo -n "$FW" --setglobalstate on >/dev/null
  fi

  if sudo -n "$FW" --getstealthmode 2>/dev/null | grep -q "enabled"; then
    ok "Firewall stealth mode already enabled"
  else
    info "Enabling firewall stealth mode (don't respond to network probes)"
    sudo -n "$FW" --setstealthmode on >/dev/null
  fi
fi

ok "macOS defaults applied"
