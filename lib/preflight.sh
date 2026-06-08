# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: err, ok, github_ssh_ok.
#
# Refuse to run setup.sh unless pre-setup.sh has been completed. Pre-setup
# outputs that setup depends on:
#   - Xcode CLT (otherwise Homebrew install pops a GUI modal mid-run)
#   - SSH access to github.com (otherwise repo cloning will fail)
#   - git user.name + user.email (otherwise the first commit in a cloned
#     repo gets the wrong identity)

PREFLIGHT_FAIL=0

if ! xcode-select -p &>/dev/null; then
  err "Xcode Command Line Tools not installed."
  PREFLIGHT_FAIL=1
fi

if ! github_ssh_ok; then
  err "SSH access to github.com not working."
  PREFLIGHT_FAIL=1
fi

if ! git config --global user.name &>/dev/null || ! git config --global user.email &>/dev/null; then
  err "Global git user.name / user.email not set."
  PREFLIGHT_FAIL=1
fi

if [[ "$PREFLIGHT_FAIL" -eq 1 ]]; then
  echo ""
  echo -e "${YELLOW}Run ./pre-setup.sh first.${NC} It installs Xcode CLT, generates an SSH key,"
  echo "  walks you through adding it to GitHub, and sets your git identity."
  exit 1
fi

ok "Preflight passed: Xcode CLT, GitHub SSH, git identity all OK"
