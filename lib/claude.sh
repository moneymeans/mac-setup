# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn.
#
# Install Claude Code via Anthropic's native installer. Drops a
# self-updating binary at ~/.local/bin/claude with no Node dependency.
# This is the path Anthropic now marks as "Recommended" in their docs.

CLAUDE_BIN="$HOME/.local/bin/claude"

if have claude; then
  ok "Claude Code already installed ($(claude --version 2>/dev/null | head -1 || command -v claude))"
  return 0 2>/dev/null || exit 0
fi

if [[ -x "$CLAUDE_BIN" ]]; then
  ok "Claude Code already installed at $CLAUDE_BIN"
  return 0 2>/dev/null || exit 0
fi

info "Installing Claude Code via native installer..."
curl -fsSL https://claude.ai/install.sh | bash

# Verify — the installer can exit 0 on a partial write (network truncation,
# permission glitch). Don't claim success unless the binary is actually there.
if [[ -x "$CLAUDE_BIN" ]]; then
  ok "Claude Code installed at $CLAUDE_BIN"
else
  warn "Claude Code installer ran but $CLAUDE_BIN is missing — re-run setup.sh or install manually from claude.ai"
fi

# Make ~/.local/bin reachable in this shell for any later steps. The native
# installer adds it to .zshrc itself.
export PATH="$HOME/.local/bin:$PATH"
