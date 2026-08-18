# shellcheck shell=bash
# Sourced from setup.sh after common.sh + status.sh. Uses: info/ok/warn/err,
# section, step_ok/step_fail/step_skip.
#
# Pick which browsers to install. Browsers are deliberately NOT in the
# Brewfile so this can be per-user. Default = chrome only; new starters
# get a multi-select prompt.
#
# Unattended invocation:
#   MAC_SETUP_BROWSERS="chrome firefox"   # space-separated
#   MAC_SETUP_BROWSERS="none"             # skip entirely
#
# NOTE: macOS ships bash 3.2 (associative arrays need 4.0+). We use a
# case statement so this works on every Mac without needing brew-bash.

readonly BROWSER_DEFAULT="chrome"
readonly BROWSER_VALID_REGEX='^[A-Za-z]+$'

# name → brew cask token.
browser_cask() {
  case "$1" in
    chrome)  echo google-chrome ;;
    firefox) echo firefox ;;
    arc)     echo arc ;;
    brave)   echo brave-browser ;;
    *)       echo "" ;;
  esac
}

# name → /Applications/<App>.app — used to detect installs that bypassed brew
# (e.g. user dragged the app in manually). brew install --cask refuses to
# install over an existing .app, so we need to check both.
browser_app() {
  case "$1" in
    chrome)  echo "Google Chrome.app" ;;
    firefox) echo "Firefox.app" ;;
    arc)     echo "Arc.app" ;;
    brave)   echo "Brave Browser.app" ;;
    *)       echo "" ;;
  esac
}

section "Browsers"

if [[ "${MAC_SETUP_BROWSERS:-}" == "none" ]]; then
  info "MAC_SETUP_BROWSERS=none — skipping browser install"
  step_skip "Browsers" "(MAC_SETUP_BROWSERS=none)"
  return 0 2>/dev/null || exit 0
fi

browsers="${MAC_SETUP_BROWSERS:-}"

if [[ -z "$browsers" ]]; then
  multi_select_result=()
  if multi_select \
    "Pick the browsers you want installed:" \
    "chrome:default" "firefox" "arc" "brave"; then
    browsers="${multi_select_result[*]:-}"
  else
    info "Aborted browser selection — skipping browser install"
    step_skip "Browsers" "(you skipped the picker)"
    return 0 2>/dev/null || exit 0
  fi
  if [[ -z "$browsers" ]]; then
    info "No browsers selected — skipping browser install"
    step_skip "Browsers" "(none selected)"
    return 0 2>/dev/null || exit 0
  fi
fi

install_failed=0
# Names (for the human-readable report) and casks (for the copy-paste fix
# command) of anything that didn't install. Kept as parallel arrays rather
# than one string so the remediation line is directly runnable.
failed_browsers=()
failed_casks=()
selected_browsers=()

# Intentional word-split on whitespace.
# shellcheck disable=SC2086
for name in $browsers; do
  if ! [[ "$name" =~ $BROWSER_VALID_REGEX ]]; then
    err "Invalid browser name: '$name' (letters only). Skipping."
    install_failed=1
    continue
  fi

  cask=$(browser_cask "$name")
  if [[ -z "$cask" ]]; then
    warn "Unknown browser '$name' — known options: chrome, firefox, arc, brave. Skipping."
    install_failed=1
    continue
  fi

  if brew list --cask "$cask" &>/dev/null; then
    ok "$name already installed via brew ($cask)"
    selected_browsers+=("$name")
    continue
  fi

  app_name=$(browser_app "$name")
  if [[ -n "$app_name" && -d "/Applications/$app_name" ]]; then
    ok "$name already installed at /Applications/$app_name (not via brew — leaving it alone)"
    selected_browsers+=("$name")
    continue
  fi

  info "Installing $name ($cask)..."
  if brew install --cask "$cask"; then
    ok "$name installed"
    selected_browsers+=("$name")
  else
    err "Failed to install $name ($cask)"
    failed_browsers+=("$name")
    failed_casks+=("$cask")
    install_failed=1
  fi
done

if (( install_failed == 1 )); then
  warn "One or more browsers did not install — scroll up."
  step_fail "Browsers" "failed: ${failed_browsers[*]}" \
    "brew install --cask ${failed_casks[*]}"
else
  step_ok "Browsers" "${selected_browsers[*]:-none selected}"
fi
