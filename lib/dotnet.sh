# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn/err,
# append_block, ZSHRC.

export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$DOTNET_ROOT:$PATH"

_dotnet_has_v10() {
  have dotnet && dotnet --list-sdks 2>/dev/null | grep -q '^10\.'
}

if _dotnet_has_v10; then
  ok ".NET 10 SDK already installed"
else
  info "Installing .NET 10 SDK..."
  curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0

  # The installer sometimes exits 0 without actually placing an SDK 10 on
  # disk (e.g. partial download, channel-not-yet-published). Re-verify so
  # downstream steps don't fail with confusing messages.
  if ! _dotnet_has_v10; then
    warn ".NET 10 SDK install completed but no SDK 10.x is present — re-run setup.sh, or install manually from dot.net"
    return 0 2>/dev/null || exit 0
  fi
  ok ".NET 10 SDK installed"
fi

append_block "$ZSHRC" "dotnet" <<'DOTNET_BLOCK' || true
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$DOTNET_ROOT:$PATH"
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
