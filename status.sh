#!/usr/bin/env bash
# Money Means — what's installed on this Mac?
#
# READ-ONLY. Answers "did setup work / what's missing?" without running
# setup.sh. Installs nothing, starts nothing, writes nothing. Safe to run
# on a fully configured machine, and safe to run repeatedly.
#
# Exists because the per-stage report was only ever a side effect of a
# full setup.sh run: the only way to ask "what's on here?" was to sit
# through a 30-minute script that also mutates the machine. This answers
# the same question in a couple of seconds.
#
#   ./status.sh              # everything
#   ./status.sh --brief      # one line per section, problems only
#
# Exit status: 0 if nothing needs attention, 1 if anything is missing.
# (So it can gate a CI check or a "is this machine ready?" test.)

set -uo pipefail   # NOT -e: a failed probe is a RESULT, not a crash.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

BRIEF=false
for arg in "$@"; do
  case "$arg" in
    --brief) BRIEF=true ;;
    -h|--help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: '$arg' (try --help)" >&2; exit 1 ;;
  esac
done

MISSING=0        # things that should be here and aren't
ATTENTION=0      # things that are here but not finished
FIXES=()

have() { command -v "$1" &>/dev/null; }

# ── Reporting ──────────────────────────────────────────────────────────
# Deliberately mirrors lib/status.sh's ✓/⚠/✗ vocabulary so this script and
# the end-of-setup report read the same way.
row_ok()   { $BRIEF || printf "  ${GREEN}\xe2\x9c\x93${NC}  %-22s ${DIM}%s${NC}\n" "$1" "${2:-}"; }
row_warn() {
  printf "  ${YELLOW}\xe2\x9a\xa0${NC}  %-22s ${YELLOW}%s${NC}\n" "$1" "${2:-}"
  ATTENTION=$(( ATTENTION + 1 ))
  [[ -n "${3:-}" ]] && FIXES+=("$1|$3")
  return 0
}
row_missing() {
  printf "  ${RED}\xe2\x9c\x97${NC}  %-22s ${RED}%s${NC}\n" "$1" "${2:-}"
  MISSING=$(( MISSING + 1 ))
  [[ -n "${3:-}" ]] && FIXES+=("$1|$3")
  return 0
}
section() { $BRIEF || printf "\n${BLUE}%s${NC}\n" "$1"; }

# ── Homebrew formulae + casks ──────────────────────────────────────────
# Parsed from the Brewfile rather than hardcoded, so this can't drift out
# of sync with what setup.sh actually installs.
check_brew() {
  section "Homebrew"
  if ! have brew; then
    row_missing "Homebrew" "not installed" "Run ./setup.sh, or see https://brew.sh"
    return
  fi
  row_ok "Homebrew" "$(brew --version | head -1 | sed 's/Homebrew //')"

  local bf="$REPO_DIR/Brewfile"
  [[ -f "$bf" ]] || { row_warn "Brewfile" "not found at $bf"; return; }

  # One `brew list` call each instead of one per package — the per-package
  # form takes ~0.4s and there are 20+ of them.
  local installed_formulae installed_casks
  installed_formulae="$(brew list --formula -1 2>/dev/null)"
  installed_casks="$(brew list --cask -1 2>/dev/null)"

  local missing_f=() missing_c=() name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<<"$installed_formulae" || missing_f+=("$name")
  done < <(sed -n 's/^brew "\([^"]*\)".*/\1/p' "$bf")

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<<"$installed_casks" || missing_c+=("$name")
  done < <(sed -n 's/^cask "\([^"]*\)".*/\1/p' "$bf")

  local total_f total_c
  total_f=$(grep -c '^brew "' "$bf")
  total_c=$(grep -c '^cask "' "$bf")

  if (( ${#missing_f[@]} == 0 )); then
    row_ok "CLI tools" "all $total_f present"
  else
    row_missing "CLI tools" "missing: ${missing_f[*]}" \
      "brew install ${missing_f[*]}"
  fi

  if (( ${#missing_c[@]} == 0 )); then
    row_ok "Apps" "all $total_c present"
  else
    row_missing "Apps" "missing: ${missing_c[*]}" \
      "brew install --cask ${missing_c[*]}"
  fi
}

# ── Runtimes ───────────────────────────────────────────────────────────
check_runtimes() {
  section "Runtimes"

  if have mise; then
    local node_v
    node_v="$(mise current node 2>/dev/null | head -1)"
    if [[ -n "$node_v" ]]; then
      row_ok "Node (via mise)" "$node_v"
    elif have node; then
      row_warn "Node" "on PATH but not managed by mise" "mise use -g node@lts"
    else
      row_missing "Node" "mise installed but no node version" "mise use -g node@lts"
    fi
  elif have node; then
    row_warn "Node" "$(node --version) (mise not installed)" "brew install mise"
  else
    row_missing "Node" "not installed" "brew install mise && mise use -g node@lts"
  fi

  if have dotnet; then
    row_ok ".NET SDK" "$(dotnet --version 2>/dev/null)"
  else
    row_missing ".NET SDK" "not on PATH" "Re-run ./setup.sh (installs to ~/.dotnet)"
  fi

  # csharpier is a dotnet tool, not a brew package.
  if have csharpier || [[ -x "$HOME/.dotnet/tools/csharpier" ]]; then
    row_ok "CSharpier" "installed"
  else
    row_warn "CSharpier" "not installed" "dotnet tool install -g csharpier"
  fi

  if have claude; then
    row_ok "Claude Code" "$(claude --version 2>/dev/null | head -1)"
  else
    row_missing "Claude Code" "not on PATH" "Re-run ./setup.sh"
  fi
}

# ── Authentication ─────────────────────────────────────────────────────
# The silent-failure cluster: everything looks installed, but nothing can
# reach a private repo. All probes are read-only and non-interactive.
check_auth() {
  section "Authentication"

  if ! have gh; then
    row_missing "GitHub CLI" "gh not installed" "brew install gh && gh auth login"
  elif gh auth status &>/dev/null; then
    row_ok "GitHub CLI" "signed in"
  else
    row_missing "GitHub CLI" "not signed in" "gh auth login"
  fi

  if ! have az; then
    row_missing "Azure CLI" "az not installed" "brew install azure-cli && az login"
  elif az account show &>/dev/null; then
    row_ok "Azure CLI" "signed in"
  else
    row_warn "Azure CLI" "not signed in" "az login"
  fi

  # SSH to GitHub: exit 1 with "successfully authenticated" is SUCCESS
  # (github never grants a shell), so match the message, not the code.
  local ssh_out
  ssh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 -T git@github.com 2>&1)"
  if grep -qi 'successfully authenticated' <<<"$ssh_out"; then
    row_ok "GitHub SSH" "key accepted"
  else
    row_missing "GitHub SSH" "key not accepted" \
      "./pre-setup.sh   # regenerates + re-verifies your key"
  fi

  # SSO is the one that bit a real starter: the key is on the account, so
  # the check above passes, but the org refuses to serve repos over it.
  local org="${GITHUB_ORG:-moneymeans}"
  local ls_out ls_rc
  ls_out="$(GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code \
    "git@github.com:${org}/claude-herder.git" HEAD 2>&1)" && ls_rc=0 || ls_rc=$?
  if (( ls_rc == 0 )); then
    row_ok "GitHub org access" "$org repos readable"
  elif grep -qiE 'saml|single.sign.on|sso' <<<"$ls_out"; then
    row_missing "GitHub org access" "key not SSO-authorised for $org" \
      "Authorise at https://github.com/settings/keys (Configure SSO → Authorize)"
  else
    row_warn "GitHub org access" "could not verify (network, or no access)" \
      "Check: git ls-remote git@github.com:${org}/claude-herder.git"
  fi

  if have gpg && git config --get user.signingkey &>/dev/null; then
    local keyid
    keyid="$(git config --get user.signingkey)"
    if gpg --list-secret-keys "$keyid" &>/dev/null; then
      row_ok "GPG signing" "key $keyid"
    else
      row_warn "GPG signing" "git points at missing key $keyid" "./setup-gpg-signing.sh"
    fi
  else
    row_warn "GPG signing" "not configured" "./setup-gpg-signing.sh"
  fi
}

# ── Docker ─────────────────────────────────────────────────────────────
check_docker() {
  section "Docker"
  local app=""
  for candidate in "/Applications/Docker.app" "$HOME/Applications/Docker.app"; do
    [[ -d "$candidate" ]] && { app="$candidate"; break; }
  done

  if [[ -z "$app" ]]; then
    row_missing "Docker Desktop" "not installed" \
      "brew install --cask docker-desktop  # then: open -a Docker"
    return
  fi

  if docker info &>/dev/null; then
    row_ok "Docker Desktop" "daemon running"
  elif have docker; then
    row_warn "Docker Desktop" "installed, daemon not running" \
      "open -a \"$app\"  # then: docker info"
  else
    row_warn "Docker Desktop" "installed, CLI not on PATH (first run incomplete)" \
      "open -a \"$app\"  # accept the licence + helper prompt"
  fi
}

# ── Repos & herder ─────────────────────────────────────────────────────
check_repos() {
  section "Repos"
  # Same precedence as lib/common.sh's work_dir(): an explicit override
  # wins, otherwise the default. Kept in sync deliberately.
  local wd="${MAC_SETUP_WORK_DIR:-$HOME/work}"
  wd="${wd/#\~/$HOME}"

  if [[ ! -d "$wd" ]]; then
    row_missing "Work folder" "$wd does not exist" \
      "./setup.sh   # or set MAC_SETUP_WORK_DIR"
    return
  fi
  row_ok "Work folder" "$wd"

  local found=() d
  for d in "$wd"/*/; do
    [[ -d "$d/.git" ]] && found+=("$(basename "$d")")
  done
  if (( ${#found[@]} > 0 )); then
    row_ok "Cloned repos" "${found[*]}"
  else
    row_warn "Cloned repos" "none found in $wd" "./setup.sh"
  fi

  local conf="$HOME/.claude-sessions.conf"
  if [[ -f "$conf" ]]; then
    local base
    base="$(grep -E '^[[:space:]]*BASE_DIR[[:space:]]*=' "$conf" 2>/dev/null \
      | tail -1 | sed -E 's/^[[:space:]]*BASE_DIR[[:space:]]*=[[:space:]]*//; s/^"//; s/"$//' || true)"
    if [[ -z "$base" ]]; then
      row_warn "Herder BASE_DIR" "not set in $conf" "./setup.sh"
    elif [[ -d "${base/#\~/$HOME}" ]]; then
      row_ok "Herder BASE_DIR" "$base"
    else
      row_missing "Herder BASE_DIR" "$base does not exist" \
        "Fix BASE_DIR in $conf, or re-run ./setup.sh"
    fi
  else
    row_warn "Herder config" "no $conf" "./setup.sh"
  fi
}

# ── Shell ──────────────────────────────────────────────────────────────
check_shell() {
  section "Shell"
  local zshrc="$HOME/.zshrc"
  if [[ -f "$zshrc" ]] && grep -qE 'oh-my-zsh\.sh|ZSH=.*oh-my-zsh' "$zshrc"; then
    row_ok "Oh My Zsh" "loaded in ~/.zshrc"
  else
    row_warn "Oh My Zsh" "not loaded" "./setup.sh"
  fi

  if [[ -f "$zshrc" ]] && grep -q 'mise activate' "$zshrc"; then
    row_ok "mise activation" "in ~/.zshrc"
  elif have mise; then
    row_warn "mise activation" "mise installed but not activated in ~/.zshrc" \
      "echo 'eval \"\$(mise activate zsh)\"' >> ~/.zshrc"
  fi
}

# ── Run ────────────────────────────────────────────────────────────────
printf "\n${BLUE}Money Means — Mac setup status${NC}\n"
printf "${DIM}Read-only: nothing is installed, started, or modified.${NC}\n"

check_brew
check_runtimes
check_auth
check_docker
check_repos
check_shell

echo ""
total=$(( MISSING + ATTENTION ))
if (( total == 0 )); then
  printf "${GREEN}Everything's in place.${NC}\n\n"
  exit 0
fi

printf "${YELLOW}%d thing(s) need attention${NC}" "$total"
(( MISSING > 0 )) && printf " ${RED}(%d missing)${NC}" "$MISSING"
printf ":\n\n"

n=0
for entry in "${FIXES[@]}"; do
  n=$(( n + 1 ))
  printf "  %d. %s\n     ${GREEN}%s${NC}\n" "$n" "${entry%%|*}" "${entry#*|}"
done
echo ""
echo "  Stuck? From this folder run:"
printf "     ${GREEN}claude \"status.sh reported these problems, help me fix them\"${NC}\n\n"

exit 1
