# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn, append_block,
# ZPROFILE, REPO_DIR.

if have brew; then
  ok "Homebrew already installed ($(brew --version | head -1))"
else
  info "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Activate brew in the current shell regardless of how it was installed.
# Apple Silicon only (we don't support Intel).
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Persist brew on PATH for future shells.
append_block "$ZPROFILE" "homebrew" <<'BREW_BLOCK' || true
eval "$(/opt/homebrew/bin/brew shellenv)"
BREW_BLOCK

info "Running brew bundle (skips already-installed)..."
if ! brew bundle --file="$REPO_DIR/Brewfile"; then
  warn "brew bundle reported issues — continuing, but downstream stages that depend on missing tools may also warn or fail."
fi
