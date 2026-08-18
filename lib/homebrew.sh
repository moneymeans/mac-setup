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
# brew bundle's exit code is an aggregate: one failed cask out of twenty
# turns the whole thing non-zero without saying which. That opacity is how
# a missing Docker.app went unnoticed for days, so on failure we ask brew
# which entries are still unsatisfied and name them in the report.
if brew bundle --file="$REPO_DIR/Brewfile"; then
  step_ok "Homebrew + Brewfile" "all formulae and casks present"
else
  warn "brew bundle reported issues — continuing, but downstream stages that depend on missing tools may also warn or fail."

  # `brew bundle list` prints every entry the Brewfile asks for; we then
  # ask brew which of those are actually installed. Diffing intent against
  # reality names the real stragglers instead of reprinting brew's output.
  missing=""
  for formula in $(brew bundle list --file="$REPO_DIR/Brewfile" --brews 2>/dev/null); do
    brew list --formula "$formula" &>/dev/null || missing="$missing $formula"
  done
  for cask in $(brew bundle list --file="$REPO_DIR/Brewfile" --casks 2>/dev/null); do
    brew list --cask "$cask" &>/dev/null || missing="$missing $cask"
  done
  missing="${missing# }"

  if [[ -n "$missing" ]]; then
    warn "Still missing after brew bundle: $missing"
    step_fail "Homebrew + Brewfile" "missing: $missing" \
      "brew install $missing   # add --cask for apps, e.g. brew install --cask docker-desktop"
  else
    # Non-zero exit but nothing actually missing — usually a failed
    # `brew upgrade` on an already-installed package. Not worth alarming.
    step_warn "Homebrew + Brewfile" "brew reported an error but nothing is missing" \
      "brew bundle --file=$REPO_DIR/Brewfile   # re-run to see the detail"
  fi
fi
