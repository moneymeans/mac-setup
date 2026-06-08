# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn,
# section.
#
# Walk the user through authenticating the CLIs they're about to use.
# Each one opens a browser-based OAuth flow; we prompt before each to
# avoid three browser windows fighting for focus.
#
# Defaults to Yes (just press Enter to authenticate now) so a starter
# can hold Enter through this section. Each step is independently
# skippable — already-authenticated CLIs short-circuit.
#
# Skip the whole section entirely with MAC_SETUP_NO_AUTH=1 or when
# stdin isn't a tty (curl|bash / CI).

if [[ "${MAC_SETUP_NO_AUTH:-0}" == "1" ]] || [[ ! -t 0 ]]; then
  info "Skipping interactive CLI auth (no tty or MAC_SETUP_NO_AUTH=1)"
  return 0 2>/dev/null || exit 0
fi

section "Authenticate CLIs"
cat <<'EOF'
We'll now authenticate the CLIs you'll be using. Each one opens a
browser; finish the flow there, come back here, and we'll move to the
next. Press Enter for Yes, type 'n' to skip an individual CLI.

EOF

# Yes/no prompt that defaults to yes. Returns 0 for yes, 1 for no.
_yn_yes() {
  local prompt="$1" answer
  read -rp "$prompt [Y/n] " answer
  case "${answer:-y}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ── GitHub CLI ─────────────────────────────────────────────────────────
if have gh; then
  if gh auth status &>/dev/null; then
    ok "gh already authenticated ($(gh api user --jq .login 2>/dev/null || echo 'unknown user'))"
  else
    echo ""
    echo "  ${BLUE}GitHub CLI (gh)${NC} — needed for `gh pr create`, `gh repo`, etc."
    if _yn_yes "  Authenticate gh now?"; then
      # --git-protocol ssh: we configured SSH in pre-setup, keep it consistent
      # --skip-ssh-key:     don't offer to upload another key, we already did
      # --web:              use browser flow (the standard interactive mode)
      gh auth login --git-protocol ssh --skip-ssh-key --web || \
        warn "gh auth login didn't complete — re-run later: gh auth login"
    else
      info "Skipped gh — run later with: gh auth login"
    fi
  fi
else
  warn "gh not on PATH — skipping (re-run setup.sh to install)"
fi

# ── Azure CLI ──────────────────────────────────────────────────────────
if have az; then
  if az account show &>/dev/null; then
    ok "az already authenticated ($(az account show --query user.name -o tsv 2>/dev/null || echo 'unknown user'))"
  else
    echo ""
    echo "  ${BLUE}Azure CLI (az)${NC} — needed if you'll touch Azure (App Configuration, Key Vault, etc.)"
    if _yn_yes "  Authenticate az now?"; then
      az login || warn "az login didn't complete — re-run later: az login"
    else
      info "Skipped az — run later with: az login"
    fi
  fi
else
  warn "az not on PATH — skipping (re-run setup.sh to install)"
fi

# ── Claude Code ────────────────────────────────────────────────────────
# `claude` doesn't have a non-interactive auth-status query (its first
# run prompts for browser auth if needed). We just tell the user.
if have claude; then
  echo ""
  echo "  ${BLUE}Claude Code CLI${NC} — the AI coding assistant we use heavily."
  echo "  First run of \`claude\` opens a browser for sign-in."
  if _yn_yes "  Run \`claude\` now to trigger first-run auth?"; then
    info "Launching claude (this will open a browser if not yet authed). Quit with Ctrl-C or /quit when done."
    claude || true
  else
    info "Skipped claude — run later with: claude"
  fi
else
  warn "claude not on PATH — skipping (re-run setup.sh to install)"
fi

ok "CLI authentication step complete"
