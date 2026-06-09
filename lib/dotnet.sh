# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn/err,
# append_block, replace_block, ZSHRC.
#
# Installs .NET 10 SDK + CSharpier, and points $DOTNET_ROOT at the right
# install location so apphosts like `sqlpackage` can find the runtime.
#
# Two valid install layouts on macOS:
#   - Homebrew: `dotnet` lives at /opt/homebrew/bin/dotnet, runtime under
#     /opt/homebrew/opt/dotnet/libexec/shared/Microsoft.NETCore.App.
#     We pick this up automatically if the user previously installed
#     `brew install dotnet` (mac-setup itself does NOT brew-install dotnet
#     today, but engineers may have done it before adopting this repo).
#   - Per-user (`dotnet-install.sh`): everything under $HOME/.dotnet,
#     including $HOME/.dotnet/shared/Microsoft.NETCore.App.
#
# Why this matters: the `dotnet` CLI resolves its own runtime from the
# binary's location and ignores $DOTNET_ROOT. But tool apphosts installed
# via `dotnet tool install -g` (CSharpier, sqlpackage) trust $DOTNET_ROOT
# and look for the runtime under $DOTNET_ROOT/shared/Microsoft.NETCore.App.
# Pinning $DOTNET_ROOT to an empty directory makes every such tool fail
# with "You must install .NET to run this application" — even though
# `dotnet --info` works fine. Be precise.

# Detect where dotnet (if any) is installed and where its runtime lives.
# Sets two vars used below:
#   DOTNET_LOCATION  = "brew" | "peruser" | "none"
#   DOTNET_ROOT_PATH = absolute path to use for $DOTNET_ROOT
_detect_dotnet_layout() {
  local brew_libexec="/opt/homebrew/opt/dotnet/libexec"
  if have dotnet && [[ "$(command -v dotnet)" == /opt/homebrew/* ]] \
       && [[ -d "$brew_libexec/shared/Microsoft.NETCore.App" ]]; then
    DOTNET_LOCATION="brew"
    DOTNET_ROOT_PATH="$brew_libexec"
    return 0
  fi
  DOTNET_LOCATION="peruser"
  DOTNET_ROOT_PATH="$HOME/.dotnet"
}

_detect_dotnet_layout

# Set DOTNET_ROOT for THIS shell so any dotnet tool we install below (e.g.
# csharpier) inherits the right value and so subsequent setup.sh stages
# don't need to re-detect.
export DOTNET_ROOT="$DOTNET_ROOT_PATH"
export PATH="$DOTNET_ROOT:$HOME/.dotnet/tools:$PATH"

_dotnet_has_v10() {
  have dotnet && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'
}

if _dotnet_has_v10; then
  if [[ "$DOTNET_LOCATION" == "brew" ]]; then
    ok ".NET 10 SDK already installed (Homebrew)"
  else
    ok ".NET 10 SDK already installed (~/.dotnet)"
  fi
else
  info "Installing .NET 10 SDK to ~/.dotnet (per-user installer)..."
  curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0

  # The per-user installer just populated ~/.dotnet — re-detect so the
  # block we write to ~/.zshrc below points at the right place.
  _detect_dotnet_layout
  export DOTNET_ROOT="$DOTNET_ROOT_PATH"
  export PATH="$DOTNET_ROOT:$HOME/.dotnet/tools:$PATH"

  # The installer sometimes exits 0 without actually placing an SDK 10 on
  # disk (e.g. partial download, channel-not-yet-published). Re-verify so
  # downstream steps don't fail with confusing messages.
  if ! _dotnet_has_v10; then
    warn ".NET 10 SDK install completed but no SDK 10.x is present — re-run setup.sh, or install manually from dot.net"
    return 0 2>/dev/null || exit 0
  fi
  ok ".NET 10 SDK installed"
fi

# Sanity-check the runtime is actually present at $DOTNET_ROOT. If not,
# apphosts will fail at runtime with confusing errors — warn now instead.
if [[ ! -d "$DOTNET_ROOT/shared/Microsoft.NETCore.App" ]]; then
  warn "No runtime found under $DOTNET_ROOT/shared/Microsoft.NETCore.App."
  warn "  Tools installed via 'dotnet tool install -g' will fail to launch."
  warn "  This usually means dotnet is installed somewhere mac-setup didn't detect."
fi

# Use replace_block (not append_block): on machines where an earlier run
# of mac-setup pinned the wrong DOTNET_ROOT (e.g. brew dotnet present but
# we still wrote $HOME/.dotnet), append_block would short-circuit and leave
# the stale block in place forever. replace_block corrects it on re-run.
replace_block "$ZSHRC" "dotnet" <<DOTNET_BLOCK
export DOTNET_ROOT="$DOTNET_ROOT_PATH"
export PATH="\$DOTNET_ROOT:\$HOME/.dotnet/tools:\$PATH"
DOTNET_BLOCK

if ! have dotnet; then
  warn "dotnet still not on PATH — skipping CSharpier install"
  return 0 2>/dev/null || exit 0
fi

if dotnet tool list -g 2>/dev/null | grep -q 'csharpier'; then
  ok "CSharpier already installed"
else
  info "Installing CSharpier..."
  dotnet tool install -g csharpier
  ok "CSharpier installed"
fi
