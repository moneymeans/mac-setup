# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: have, info/ok/warn, append_block,
# ZSHRC.
#
# Install Node.js via mise.
#
# Why mise (and not Volta): Volta is unmaintained as of 2026 — its own
# maintainers point users to mise. mise reads .mise.toml / .tool-versions
# files in repos and per-directory-switches Node automatically.
#
# Per-repo pinning: in a repo, run `mise use node@<version>` to write a
# `.mise.toml`.

if ! have mise; then
  warn "mise not on PATH yet. Re-run setup.sh after restarting the shell."
  step_fail "Node.js (mise)" "mise not on PATH" \
    "brew install mise && ./setup.sh"
  return 0 2>/dev/null || exit 0
fi

# Activate mise in this shell so we can use the `mise` and shimmed `node` now.
# Best-effort: mise's first invocation occasionally fails to fetch metadata
# on a brand-new machine, and we don't want setup.sh to abort on that.
eval "$(mise activate bash)" || warn "mise activation reported issues — continuing"

# Pin Node LTS globally if no global Node is set.
if mise current node 2>/dev/null | grep -q '^[0-9]'; then
  ok "Node already managed by mise ($(mise current node))"
else
  info "Installing Node LTS via mise..."
  mise use --global node@lts
  ok "Node installed via mise ($(mise current node))"
fi

# Persist mise activation in .zshrc for future shells.
append_block "$ZSHRC" "mise" <<'MISE_BLOCK' || true
# mise — polyglot version manager
eval "$(mise activate zsh)"
MISE_BLOCK

# Verify rather than assume: `mise use --global` can succeed while the
# shim isn't resolvable yet, and a Node that isn't runnable is not a
# working Node — reporting it as installed would be the same kind of
# optimistic lie the Docker stage used to tell.
if node_version="$(node --version 2>/dev/null)"; then
  step_ok "Node.js (mise)" "$node_version"
elif mise_node="$(mise current node 2>/dev/null)" && [[ -n "$mise_node" ]]; then
  step_warn "Node.js (mise)" "mise has $mise_node but 'node' isn't on PATH in this shell" \
    "exec zsh   # then: node --version"
else
  step_fail "Node.js (mise)" "no usable Node found" \
    "mise use --global node@lts && exec zsh"
fi
