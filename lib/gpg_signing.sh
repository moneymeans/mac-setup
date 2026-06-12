# shellcheck shell=bash
# Sourced from setup.sh and from the standalone setup-gpg-signing.sh.
# Uses helpers from lib/common.sh: have, info/ok/warn/err, section,
# append_block, ZSHRC, SETUP_HAD_WARNINGS.
#
# Sets up GPG commit signing on macOS so every commit (including ones
# made non-interactively by tooling like Claude Code) is automatically
# signed and shows up as "Verified" on GitHub.
#
# How GPG signing works, in one paragraph for the C#/TS folks: GPG is
# an asymmetric-crypto CLI. You generate a keypair — a private key kept
# in ~/.gnupg, a public key you upload to GitHub. `git commit -S` runs
# `gpg --sign` over the commit object, attaching a signature. GitHub
# verifies the signature against the public key you uploaded and
# displays "Verified" next to your commit. The signing key's UID
# (name + email) MUST match your git committer email or GitHub will
# show "Unverified". `pinentry-mac` is the GUI prompt program GPG uses
# when it needs a passphrase — we use it as a safety net even though
# we generate keys with no passphrase (matches our SSH policy).
#
# Idempotency contract: every check below is "already done?" first. Safe
# to re-run on a fully-configured machine; it'll just print [OK] lines.

# ── 0. Sanity: macOS only ─────────────────────────────────────────────
# This module deliberately bails on non-macOS — pinentry-mac doesn't
# exist anywhere else, and the rest of mac-setup is macOS-only too.
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "GPG signing setup is macOS-only (you're on $(uname -s))."
  return 1 2>/dev/null || exit 1
fi

section "GPG commit signing"

# ── 1. Preflight: Homebrew must already be present ────────────────────
# When this module is sourced from setup.sh, brew is installed in the
# previous stage (lib/homebrew.sh) so this is just a sanity check.
# When sourced from the standalone setup-gpg-signing.sh, this is a real
# gate — we don't want to bootstrap brew here.
if ! have brew; then
  err "Homebrew is required but not found on PATH."
  err "Install it from https://brew.sh and re-run, or run ./setup.sh which installs brew first."
  return 1 2>/dev/null || exit 1
fi

# ── 2. Install gnupg + pinentry-mac (only if missing) ─────────────────
# `brew list --formula <name>` exits 0 if installed, 1 otherwise. Cheaper
# and more reliable than `brew bundle` for a single-package check, and
# means re-runs print "[OK] already installed" instead of triggering
# brew's "Already installed" line.
_brew_has() { brew list --formula "$1" &>/dev/null; }

if _brew_has gnupg; then
  ok "gnupg already installed"
else
  info "Installing gnupg via Homebrew..."
  brew install gnupg
  ok "gnupg installed"
fi

if _brew_has pinentry-mac; then
  ok "pinentry-mac already installed"
else
  info "Installing pinentry-mac via Homebrew..."
  brew install pinentry-mac
  ok "pinentry-mac installed"
fi

# Resolve the gpg binary location now that brew has guaranteed it's
# installed. We use the absolute path (not just "gpg") for git config
# so future shells with weird PATHs still find it.
GPG_BIN="$(command -v gpg)"
if [[ -z "$GPG_BIN" ]]; then
  err "gpg is installed via brew but not on PATH. Open a new shell and re-run."
  return 1 2>/dev/null || exit 1
fi
ok "gpg binary at $GPG_BIN"

# ── 3. Identity: name + email from global git config ──────────────────
# We MUST use the same email as the git committer, otherwise GitHub
# marks signed commits as "Unverified". Read from global config first;
# only prompt if missing (which on this repo shouldn't happen because
# pre-setup.sh set it, but the standalone script may be run on a Mac
# that never ran pre-setup.sh).
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"

if [[ -z "$GIT_NAME" ]]; then
  ask "Enter your full name for git commits" GIT_NAME
  git config --global user.name "$GIT_NAME"
fi
if [[ -z "$GIT_EMAIL" ]]; then
  ask "Enter your work email for git commits" GIT_EMAIL
  git config --global user.email "$GIT_EMAIL"
fi
ok "Using identity: $GIT_NAME <$GIT_EMAIL>"

# ── 4. Key handling (idempotent: reuse if it exists, else generate) ───
# `gpg --list-secret-keys --with-colons <email>` is the machine-readable
# query. It outputs colon-separated records; the "sec" record's 5th field
# (index 4) is the long key ID. If no key exists, gpg exits 2 and prints
# nothing. The trailing `|| true` is load-bearing: under `set -euo
# pipefail` (how setup-gpg-signing.sh runs us), pipefail propagates gpg's
# exit 2 through the pipe, and macOS's bash 3.2 then exits on the
# `KEY_ID=$(...)` assignment below. `2>/dev/null` only hides stderr — it
# does NOT change the exit code, so we must swallow it explicitly here.
#
# Why long key IDs (16 hex chars) instead of short ones (8): short IDs
# have known collisions. Git accepts either; we use long.
_get_signing_key_id() {
  gpg --list-secret-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '/^sec:/ { print $5; exit }' \
    || true
}

EXISTING_KEY_ID="$(_get_signing_key_id "$GIT_EMAIL")"

if [[ -n "$EXISTING_KEY_ID" ]]; then
  ok "Reusing existing GPG key for $GIT_EMAIL: $EXISTING_KEY_ID"
  KEY_ID="$EXISTING_KEY_ID"
else
  info "No GPG key found for $GIT_EMAIL — generating a new one..."
  info "  • Type:       RSA 4096"
  info "  • Expiration: never (0 = no expiry)"
  info "  • Passphrase: none (matches the SSH key policy in pre-setup.sh)"
  info "  • This takes ~10-30s while GPG harvests entropy. Move the mouse if it stalls."

  # GPG's --batch --gen-key takes a parameter file describing the key.
  # `%no-protection` alone generates an unprotected (passphrase-less) key.
  # Do NOT add an empty `Passphrase:` line — GnuPG 2.5+ rejects it with
  # "missing argument" and aborts key generation (exit 2), which under
  # `set -e` killed this script before it could share the key. Older docs
  # paired an empty `Passphrase:` with `%no-protection`; newer GnuPG needs
  # only the latter.
  # Heredoc to a temp file (not a pipe) because some gpg builds get
  # finicky reading the parameter file from stdin under set -o pipefail.
  KEY_PARAMS="$(mktemp -t gpg-keygen.XXXXXX)"
  cat > "$KEY_PARAMS" <<EOF
%echo Generating signing key for $GIT_NAME <$GIT_EMAIL>
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Subkey-Type: RSA
Subkey-Length: 4096
Subkey-Usage: sign
Name-Real: $GIT_NAME
Name-Email: $GIT_EMAIL
Expire-Date: 0
%no-protection
%commit
%echo Done
EOF
  # Run gpg in batch mode; --pinentry-mode loopback prevents pinentry-mac
  # from popping a GUI dialog for the (empty) passphrase.
  gpg --batch --pinentry-mode loopback --gen-key "$KEY_PARAMS"
  rm -f "$KEY_PARAMS"

  KEY_ID="$(_get_signing_key_id "$GIT_EMAIL")"
  if [[ -z "$KEY_ID" ]]; then
    err "Key generation reported success but no key for $GIT_EMAIL is present."
    err "Run 'gpg --list-secret-keys' to investigate."
    return 1 2>/dev/null || exit 1
  fi
  ok "Generated new GPG key: $KEY_ID"
fi

# ── 5. Git config (global) ────────────────────────────────────────────
# Always re-apply: cheap, and self-healing if the user changed git
# config by hand. `git config` is idempotent — setting the same value
# twice is a no-op, no duplicate entries.
git config --global user.signingkey "$KEY_ID"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.program "$GPG_BIN"
ok "Global git config: user.signingkey=$KEY_ID, commit.gpgsign=true, tag.gpgsign=true, gpg.program=$GPG_BIN"

# ── 6. Agent / pinentry setup ─────────────────────────────────────────
# gpg-agent.conf tells gpg-agent which pinentry program to use. We need
# pinentry-mac because the default `pinentry` on macOS is a TTY prompt
# that fails when gpg is called from a non-interactive context (e.g.
# Claude Code, VS Code's source control, git from a script).
#
# Even with no passphrase on the key today, configuring pinentry-mac is
# cheap insurance — if the user ever rotates to a passphrase-protected
# key, the GUI prompt will Just Work without further setup.
GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

GPG_AGENT_CONF="$GNUPGHOME/gpg-agent.conf"
PINENTRY_PATH="$(brew --prefix pinentry-mac)/bin/pinentry-mac"
PINENTRY_LINE="pinentry-program $PINENTRY_PATH"

# Append the pinentry line only if not already present. We grep for the
# exact line (-Fx) so we don't get fooled by a comment that mentions
# "pinentry-program" but doesn't actually set it.
if [[ -f "$GPG_AGENT_CONF" ]] && grep -Fxq "$PINENTRY_LINE" "$GPG_AGENT_CONF"; then
  ok "gpg-agent.conf already configured for pinentry-mac"
else
  echo "$PINENTRY_LINE" >> "$GPG_AGENT_CONF"
  chmod 600 "$GPG_AGENT_CONF"
  ok "Added pinentry-mac line to $GPG_AGENT_CONF"
fi

# GPG_TTY tells gpg-agent which terminal to associate with this session
# — needed for pinentry to know where to draw, and for ssh-agent-style
# socket discovery. Without it, signing from a fresh tmux pane or VS
# Code terminal can hang waiting for a non-existent TTY.
#
# Detect the user's interactive shell rc file. zsh is the macOS default
# since Catalina; we fall back to bash if the user has changed it.
USER_SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"
case "$USER_SHELL_NAME" in
  zsh)  SHELL_RC="$HOME/.zshrc" ;;
  bash) SHELL_RC="$HOME/.bashrc" ;;
  *)    SHELL_RC="$HOME/.zshrc" ;;  # unknown shell — assume zsh, the macOS default
esac

# Reuse append_block from lib/common.sh if it's been sourced, so this
# plays nicely with the rest of mac-setup's sentinel-comment system.
# Standalone callers that sourced common.sh first get the same treatment.
if declare -f append_block >/dev/null 2>&1; then
  if append_block "$SHELL_RC" "gpg" <<'GPG_TTY_BLOCK'
export GPG_TTY=$(tty)
GPG_TTY_BLOCK
  then
    ok "Added GPG_TTY export to $SHELL_RC"
  else
    ok "GPG_TTY export already in $SHELL_RC"
  fi
else
  # Fallback: plain grep-and-append if common.sh isn't around.
  if grep -qF 'export GPG_TTY=' "$SHELL_RC" 2>/dev/null; then
    ok "GPG_TTY export already in $SHELL_RC"
  else
    printf '\nexport GPG_TTY=$(tty)\n' >> "$SHELL_RC"
    ok "Added GPG_TTY export to $SHELL_RC"
  fi
fi

# Export for the CURRENT shell too — the test commit below needs it,
# and so does any signing the user does in this same terminal session.
# `tty` exits 1 ("not a tty") under curl|bash; that's fine — leave the
# var empty in that case so gpg-agent uses its existing TTY association.
GPG_TTY="$(tty 2>/dev/null || true)"
export GPG_TTY

# Restart gpg-agent so it picks up the new gpg-agent.conf. `reloadagent`
# is gentler than killing the agent outright and avoids breaking any
# concurrent gpg sessions.
gpg-connect-agent reloadagent /bye >/dev/null 2>&1 || true
ok "gpg-agent reloaded"

# ── 7. Export public key, copy to clipboard, print ────────────────────
# `--armor` produces the BEGIN PGP PUBLIC KEY BLOCK ASCII format GitHub
# expects. We do all three (clipboard, file, terminal) so the user can
# pick whichever they find most convenient.
PUBKEY_FILE="$HOME/gpg-public-key-${KEY_ID}.asc"
gpg --armor --export "$KEY_ID" > "$PUBKEY_FILE"
chmod 600 "$PUBKEY_FILE"

if have pbcopy; then
  pbcopy < "$PUBKEY_FILE"
  CLIPBOARD_MSG=" (also copied to clipboard)"
else
  CLIPBOARD_MSG=""
fi

echo ""
echo -e "${GREEN}Your GPG public key${CLIPBOARD_MSG}:${NC}"
echo ""
cat "$PUBKEY_FILE"
echo ""
ok "Saved to $PUBKEY_FILE"

# ── 8. Verify by making a signed test commit in a temp repo ───────────
# Done in a throwaway repo so we don't pollute any of the user's real
# checkouts. If signing is broken (wrong key id, agent not running,
# pinentry dialog cancelled), `git commit -S` exits non-zero and we
# warn — but we never fail the whole script, because the key + config
# might still be salvageable with a shell restart.
info "Running a signed test commit in a temp repo to verify..."
TEST_REPO="$(mktemp -d -t gpg-signing-test.XXXXXX)"
# We deliberately don't use `trap '... EXIT'` here — the caller
# (setup.sh / setup-gpg-signing.sh) already has an EXIT trap for its
# own REPO_DIR cleanup, and setting another would clobber it. Instead
# we clean up explicitly after the subshell, then `|| true` so a
# stubborn rm doesn't take down the whole setup.
(
  cd "$TEST_REPO"
  git init -q
  # Pin the identity locally in case the user has a weird system-level
  # override that would otherwise win over --global.
  git config user.name "$GIT_NAME"
  git config user.email "$GIT_EMAIL"
  # --allow-empty: no tree changes needed to test signing. -S is
  # redundant with commit.gpgsign=true but makes the intent explicit.
  if git commit --allow-empty -S -m "gpg signing test" >/dev/null 2>&1; then
    if git log --show-signature -1 2>&1 | grep -q "Good signature"; then
      ok "Signed test commit verified — GPG signing is working."
    else
      warn "Test commit was created but 'git log --show-signature' didn't report 'Good signature'."
      warn "Run 'git log --show-signature -1' inside a real repo to see why."
    fi
  else
    warn "Test commit failed to sign. Try opening a NEW terminal (so GPG_TTY is set) and run:"
    warn "  git commit --allow-empty -S -m test"
    warn "If that still fails, run: gpg --sign /dev/null  to see the underlying error."
  fi
)
rm -rf "$TEST_REPO" || true

# ── 9. Next-step instructions ─────────────────────────────────────────
echo ""
echo -e "${YELLOW}Next steps — upload the public key to GitHub:${NC}"
echo "  1. Open https://github.com/settings/gpg/new"
echo "     (or: GitHub → Settings → SSH and GPG keys → New GPG key)"
echo "  2. Paste the key block above (it's already in your clipboard)."
echo "  3. Click 'Add GPG key'."
echo ""
echo "After that, every commit you make from this Mac will show 'Verified' on GitHub."
echo ""
echo "Useful commands:"
echo "  gpg --list-secret-keys --keyid-format=long           # see your keys"
echo "  git log --show-signature -1                          # verify a commit was signed"
echo "  git commit --no-gpg-sign -m '...'                    # one-off unsigned commit if needed"
