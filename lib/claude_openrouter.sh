# shellcheck shell=bash
# Sourced by setup-claude-openrouter.sh. Uses helpers from common.sh.
#
# Sets up `claude-openrouter` — a wrapper around Claude Code that routes
# through OpenRouter instead of the official Anthropic API. The user's
# OpenRouter key is stored in macOS Keychain (never on disk in plaintext,
# never in this repo). At launch the wrapper reads the key, sets
# ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL, then execs
# the real claude binary so every flag, hook, skill, and MCP server keeps
# working.
#
# Modes (dispatched from $1):
#   (none)         Idempotent install. Prompts for or replaces the key,
#                  refreshes the wrapper, probes the gateway.
#   --test         No install — round-trips a real /v1/messages request
#                  against OpenRouter with the stored key + default model
#                  and prints the response. Use to verify ongoing health.
#   --uninstall    Removes the wrapper binary + Keychain entry. Does NOT
#                  touch the shared ~/.local/bin PATH block in .zshrc
#                  (the main `claude` binary depends on it too).
#
# This is intentionally NOT wired into setup.sh — it's an opt-in
# experiment for engineers who want to try OpenRouter as the engine.

CLAUDE_OPENROUTER_BIN="$HOME/.local/bin/claude-openrouter"
CLAUDE_OPENROUTER_KEYCHAIN_SERVICE="claude-openrouter"
CLAUDE_OPENROUTER_BASE_URL="https://openrouter.ai/api/v1"

# Two-option menu offered at install time. The free one is purely a smoke
# test ("can we reach OpenRouter at all?") — its quality/performance for
# real Claude Code work isn't the point. The paid one is what an engineer
# would actually use day-to-day.
CLAUDE_OPENROUTER_PAID_MODEL="z-ai/glm-5.2"
CLAUDE_OPENROUTER_FREE_MODEL="meta-llama/llama-3.3-70b-instruct:free"
CLAUDE_OPENROUTER_DEFAULT_MODEL="$CLAUDE_OPENROUTER_PAID_MODEL"

# ── Helpers ───────────────────────────────────────────────────────────

# Print a short fingerprint of a secret so the user can verify they
# pasted the right thing without us logging the whole key. Shows the
# first 8 chars (prefix is non-secret on OpenRouter — sk-or-v1) and last
# 4 chars (collision-resistant enough for human eyeballing).
fingerprint() {
  local s="$1" n=${#1}
  if (( n <= 12 )); then
    printf '%s' "$s"
  else
    printf '%s…%s' "${s:0:8}" "${s: -4}"
  fi
}

# Detect the most common paste mistake: the user pasted twice because
# nothing echoed. Returns 0 (true) if the string is exactly its own first
# half doubled. We only check when the length is plausibly doubled
# (>= 80 chars; an OpenRouter key is ~73), to avoid false positives on
# legitimately short or pathological inputs.
looks_doubled() {
  local s="$1" n=${#1}
  if (( n < 80 || n % 2 != 0 )); then
    return 1
  fi
  local half=$(( n / 2 ))
  [[ "${s:0:$half}" == "${s:$half}" ]]
}

# Read a single line as a masked secret. Each character the user pastes
# or types echoes as `*` so they can see something is landing — but the
# actual characters never hit scrollback. Backspace erases the last char.
# Enter / newline ends input.
#
# Strips ANSI bracketed-paste markers (\e[200~ and \e[201~) that iTerm,
# Terminal.app, and most modern terminals wrap pasted text in. If those
# bytes ended up in the captured string we'd silently store a corrupt
# key. The strip happens at the byte level inside the loop so the user
# never sees the escape sequence echoed back.
#
# Writes the captured string into the variable named in $1 (bash nameref-ish).
read_masked_line() {
  local __dest="$1"
  local prompt="${2:-  key: }"
  local buf="" ch n_visible=0

  # Disable bracketed paste for the duration of the read. Most terminals
  # ignore an unknown CSI sequence cleanly, but if they don't (e.g. older
  # tmux) we get nicer behavior with it explicitly off.
  printf '\e[?2004l' >&2

  printf '%s' "$prompt" >&2

  # State machine: when we see ESC ('\e' / '\033'), look ahead for the
  # bracketed-paste markers. CSI sequences here are short and known, so we
  # don't need a full ANSI parser.
  while IFS= read -rsn1 ch; do
    case "$ch" in
      '')
        # Empty read can be Enter on macOS bash 3.2's IFS=read behavior,
        # but mostly we catch newline below. Keep going.
        break
        ;;
      $'\n'|$'\r')
        break
        ;;
      $'\b'|$'\x7f')
        # Backspace / DEL — only erase if there's something to erase.
        if (( n_visible > 0 )); then
          buf="${buf:0:${#buf}-1}"
          n_visible=$(( n_visible - 1 ))
          # Move cursor back 1, overwrite with space, move back again.
          printf '\b \b' >&2
        fi
        ;;
      $'\033')
        # Possible CSI escape. Pull the next byte (must be '[') and then
        # the parameter chars until a final letter. For bracketed paste
        # we expect either \e[200~ (paste start) or \e[201~ (paste end).
        local next="" param="" final=""
        IFS= read -rsn1 -t 1 next
        if [[ "$next" != '[' ]]; then
          # Not a CSI we care about. Drop it silently (do not append ESC
          # or the next byte to the buffer — that would corrupt the key).
          continue
        fi
        # Read parameter bytes (digits, ;) up to the first non-param byte.
        while IFS= read -rsn1 -t 1 final; do
          if [[ "$final" == [0-9\;] ]]; then
            param+="$final"
          else
            break
          fi
        done
        # Drop the whole sequence regardless of what it was. If a stray
        # arrow key or similar arrives, ignoring it is the safest move.
        continue
        ;;
      *)
        buf+="$ch"
        n_visible=$(( n_visible + 1 ))
        printf '*' >&2
        ;;
    esac
  done
  printf '\n' >&2

  printf -v "$__dest" '%s' "$buf"
}

# Loud, repeatable paste flow. Calls read_masked_line, validates the
# result, and re-prompts on detected garbage (empty, doubled, bad prefix).
read_openrouter_key() {
  local __dest="$1"
  local key=""
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    echo ""
    echo -e "${YELLOW}┌───────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│  PASTE YOUR OPENROUTER KEY ON THE NEXT LINE.              │${NC}"
    echo -e "${YELLOW}│  It will appear as **** so the key stays out of           │${NC}"
    echo -e "${YELLOW}│  scrollback. Press Enter ONCE when done.                  │${NC}"
    echo -e "${YELLOW}└───────────────────────────────────────────────────────────┘${NC}"
    read_masked_line key "  key: "

    if [[ -z "$key" ]]; then
      warn "Empty input — try again, or Ctrl-C to cancel."
      continue
    fi
    if looks_doubled "$key"; then
      warn "That looks doubled (${#key} chars, first half == second half) — you probably pasted twice. Try once more."
      key=""
      continue
    fi
    if [[ "$key" != sk-or-* ]]; then
      warn "Key doesn't start with 'sk-or-' — OpenRouter keys usually do."
      if (( attempt < 3 )); then
        read -rp "  Re-paste? [Y/n] " confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
          key=""
          continue
        fi
      fi
    fi
    echo "  ✓ received ${#key} characters ($(fingerprint "$key"))"
    break
  done
  printf -v "$__dest" '%s' "$key"
}

# Send a real /v1/messages request and print the verdict. Used by the
# install flow and by --test. Returns 0 on a 200 response with content,
# non-zero otherwise — so callers can branch.
probe_openrouter() {
  local key="$1" model="$2"
  local probe_body http
  probe_body=$(mktemp)
  http=$(curl -sS -o "$probe_body" -w '%{http_code}' \
    -X POST "$CLAUDE_OPENROUTER_BASE_URL/messages" \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    --data "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}]}" \
    2>/dev/null || echo "000")

  case "$http" in
    200)
      ok "OpenRouter responded 200 OK (model: $model)"
      # Pull the first text block out of the response so the user sees the
      # model actually answered, not just that the gateway returned 200.
      # We don't require jq — a portable grep+sed is good enough for a
      # one-line answer.
      local reply
      reply=$(grep -o '"text":"[^"]*"' "$probe_body" | head -1 | sed 's/^"text":"//;s/"$//')
      if [[ -n "$reply" ]]; then
        echo "  Model said: \"$reply\""
      else
        warn "Gateway returned 200 but no text block found in the response — check the body manually:"
        head -c 500 "$probe_body"; echo ""
      fi
      rm -f "$probe_body"
      return 0
      ;;
    401|403)
      err "Gateway rejected the key ($http). Verify at https://openrouter.ai/keys, then re-run to replace it."
      ;;
    404)
      err "OpenRouter returned 404 for /v1/messages — the Anthropic-compatible gateway may not exist at this URL."
      err "claude-openrouter will not work until we route through a translation proxy."
      ;;
    402)
      err "OpenRouter returned 402 — out of credits. Top up at https://openrouter.ai/credits."
      ;;
    000)
      err "No response from OpenRouter (network error). Check your connection."
      ;;
    *)
      err "Unexpected response from OpenRouter ($http). Body:"
      head -c 500 "$probe_body"; echo ""
      ;;
  esac
  rm -f "$probe_body"
  return 1
}

# Reads the current key from Keychain, or empty string if none.
read_stored_key() {
  security find-generic-password \
    -s "$CLAUDE_OPENROUTER_KEYCHAIN_SERVICE" \
    -a "$USER" -w 2>/dev/null || true
}

# Two-option model picker. Defaults to the paid model on Enter / empty
# input; '2' picks the free smoke-test model. Anything else re-prompts.
# Writes the chosen slug into the variable named in $1 (nameref-ish).
pick_model() {
  local __dest="$1"
  echo ""
  echo "Pick the default model claude-openrouter will use:"
  echo ""
  echo "  [1] $CLAUDE_OPENROUTER_PAID_MODEL   (recommended — paid, needs credits)"
  echo "  [2] $CLAUDE_OPENROUTER_FREE_MODEL   (free — smoke test only, often rate-limited)"
  echo ""
  echo "You can always override per session: claude-openrouter --model <id>"
  while true; do
    read -rp "Choice [1/2, default 1]: " choice
    case "${choice:-1}" in
      1) printf -v "$__dest" '%s' "$CLAUDE_OPENROUTER_PAID_MODEL"; return 0 ;;
      2) printf -v "$__dest" '%s' "$CLAUDE_OPENROUTER_FREE_MODEL"; return 0 ;;
      *) warn "Type 1 or 2 (or Enter for 1)." ;;
    esac
  done
}

# Reads the DEFAULT_MODEL line out of the installed wrapper. Returns
# empty string if the wrapper doesn't exist or the line isn't present.
# Used by --test so we exercise the same model claude-openrouter would
# actually pick by default.
read_installed_default_model() {
  if [[ ! -f "$CLAUDE_OPENROUTER_BIN" ]]; then
    return 0
  fi
  # The wrapper line looks like:
  #   DEFAULT_MODEL="${CLAUDE_OPENROUTER_MODEL:-z-ai/glm-5.2}"
  # We want the slug inside the :- fallback.
  sed -n 's/^DEFAULT_MODEL="\${CLAUDE_OPENROUTER_MODEL:-\(.*\)}"$/\1/p' \
    "$CLAUDE_OPENROUTER_BIN" | head -1
}

# Writes the key to Keychain. -U updates if present (so we don't need to
# delete-then-add as separate steps and risk a half-deleted entry).
store_key() {
  local key="$1"
  security add-generic-password \
    -s "$CLAUDE_OPENROUTER_KEYCHAIN_SERVICE" \
    -a "$USER" \
    -w "$key" \
    -U \
    -T "" >/dev/null
}

# Writes (or overwrites) ~/.local/bin/claude-openrouter. Idempotent.
# Takes the default model slug as $1 — that's what the wrapper bakes in.
install_wrapper() {
  local default_model="$1"
  mkdir -p "$HOME/.local/bin"
  cat > "$CLAUDE_OPENROUTER_BIN" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by mac-setup/lib/claude_openrouter.sh — re-run
# setup-claude-openrouter.sh to regenerate. Do not edit by hand; changes
# will be lost.
#
# Runs Claude Code against OpenRouter instead of Anthropic's API. The
# OpenRouter key is fetched from macOS Keychain on every launch, so
# nothing secret lives on disk. All flags after \`claude-openrouter\` are
# passed through to the real \`claude\` binary, except --model which we
# strip and translate into ANTHROPIC_MODEL before exec.
set -euo pipefail

KEYCHAIN_SERVICE="$CLAUDE_OPENROUTER_KEYCHAIN_SERVICE"
BASE_URL="$CLAUDE_OPENROUTER_BASE_URL"
DEFAULT_MODEL="\${CLAUDE_OPENROUTER_MODEL:-$default_model}"

key=\$(security find-generic-password -s "\$KEYCHAIN_SERVICE" -a "\$USER" -w 2>/dev/null || true)
if [[ -z "\$key" ]]; then
  echo "claude-openrouter: no OpenRouter key in Keychain. Run setup-claude-openrouter.sh to add one." >&2
  exit 1
fi

# Pull --model <id> out of the args, if present, before we forward
# everything else to claude. Anthropic's CLI doesn't take --model on the
# command line in all versions, so the env var is the reliable channel.
model="\$DEFAULT_MODEL"
forwarded_args=()
while (( \$# > 0 )); do
  case "\$1" in
    --model)
      if [[ -z "\${2:-}" ]]; then
        echo "claude-openrouter: --model requires an argument (e.g. anthropic/claude-sonnet-4.5)" >&2
        exit 2
      fi
      model="\$2"
      shift 2
      ;;
    --model=*)
      model="\${1#--model=}"
      shift
      ;;
    *)
      forwarded_args+=("\$1")
      shift
      ;;
  esac
done

# Per OpenRouter + community guidance: blank ANTHROPIC_API_KEY so the
# claude binary doesn't pick up a stored Anthropic key and bypass the
# OpenRouter route. ANTHROPIC_AUTH_TOKEN is the channel for Bearer auth
# against a non-Anthropic gateway.
export ANTHROPIC_BASE_URL="\$BASE_URL"
export ANTHROPIC_AUTH_TOKEN="\$key"
export ANTHROPIC_API_KEY=""
export ANTHROPIC_MODEL="\$model"
# Fast Mode talks to an Anthropic-org-scoped endpoint; skip that check
# when we're not pointed at Anthropic.
export CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1

echo "claude-openrouter → \$BASE_URL  (model: \$model)" >&2
# bash 3.2 + set -u: "\${arr[@]}" on an empty array errors with
# "unbound variable". The +"alt" form expands to nothing if the array
# is unset/empty, so `claude-openrouter` with no args works.
exec claude \${forwarded_args[@]+"\${forwarded_args[@]}"}
WRAPPER
  chmod +x "$CLAUDE_OPENROUTER_BIN"
}

# Make sure ~/.local/bin is on PATH so `claude-openrouter` is resolvable.
# Shares the `local-bin` block name with lib/claude.sh — append_block
# is a no-op if the block already exists, so this is safe to call after
# the main setup.
ensure_local_bin_on_path() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    if ! grep -qF "mac-setup: local-bin" "$ZSHRC" 2>/dev/null; then
      append_block "$ZSHRC" "local-bin" <<'LOCAL_BIN_BLOCK' || true
# Claude Code (native installer drops binaries here)
export PATH="$HOME/.local/bin:$PATH"
LOCAL_BIN_BLOCK
      info "Added ~/.local/bin to PATH in $ZSHRC — open a new shell, or run: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
  fi
}

# ── Mode dispatch ─────────────────────────────────────────────────────

mode="${1:-install}"

case "$mode" in
  --uninstall)
    section "Uninstalling claude-openrouter"
    removed_any=0
    if [[ -f "$CLAUDE_OPENROUTER_BIN" ]]; then
      rm -f "$CLAUDE_OPENROUTER_BIN"
      ok "Removed $CLAUDE_OPENROUTER_BIN"
      removed_any=1
    else
      info "No wrapper at $CLAUDE_OPENROUTER_BIN — nothing to remove"
    fi
    if security delete-generic-password \
         -s "$CLAUDE_OPENROUTER_KEYCHAIN_SERVICE" \
         -a "$USER" >/dev/null 2>&1; then
      ok "Removed OpenRouter key from Keychain (service: $CLAUDE_OPENROUTER_KEYCHAIN_SERVICE)"
      removed_any=1
    else
      info "No OpenRouter key in Keychain — nothing to remove"
    fi
    # Deliberately do NOT touch ~/.zshrc's local-bin block: lib/claude.sh
    # uses the same block to put the main `claude` binary on PATH, so
    # removing it here would break the main install. The block is a no-op
    # for users who don't have ~/.local/bin populated anyway.
    if (( removed_any )); then
      ok "claude-openrouter uninstalled."
    else
      info "Nothing to uninstall."
    fi
    return 0 2>/dev/null || exit 0
    ;;

  --test)
    section "Testing claude-openrouter"
    if ! have curl; then
      err "curl is required for --test."
      return 1 2>/dev/null || exit 1
    fi
    stored_key=$(read_stored_key)
    if [[ -z "$stored_key" ]]; then
      err "No OpenRouter key in Keychain. Run ./setup-claude-openrouter.sh first."
      return 1 2>/dev/null || exit 1
    fi
    # Test what claude-openrouter would actually run by default — read the
    # model out of the installed wrapper, not the lib constant. Falls back
    # to the lib's paid default if the wrapper was never written (e.g.
    # someone ran --test without ever running install).
    test_model=$(read_installed_default_model)
    test_model="${test_model:-$CLAUDE_OPENROUTER_DEFAULT_MODEL}"
    info "Using stored key ($(fingerprint "$stored_key")), model: $test_model"
    if probe_openrouter "$stored_key" "$test_model"; then
      ok "End-to-end test passed."
      return 0 2>/dev/null || exit 0
    else
      return 1 2>/dev/null || exit 1
    fi
    ;;

  install|"")
    # Fall through to the install flow below.
    ;;

  *)
    err "Unknown argument: '$mode'"
    echo "Usage:"
    echo "  ./setup-claude-openrouter.sh              # install (idempotent)"
    echo "  ./setup-claude-openrouter.sh --test       # verify the API works"
    echo "  ./setup-claude-openrouter.sh --uninstall  # remove wrapper + key"
    return 1 2>/dev/null || exit 1
    ;;
esac

# ── Install flow ──────────────────────────────────────────────────────

# Sanity: the real claude binary has to exist, otherwise the wrapper has
# nothing to wrap. We don't try to install it from here — that's
# lib/claude.sh's job during the main setup.
if ! have claude && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  err "Claude Code isn't installed. Run ./setup.sh first (or install via https://claude.ai/install.sh) before setting up claude-openrouter."
  return 1 2>/dev/null || exit 1
fi

# ── Step 1: get an OpenRouter API key ──────────────────────────────────
# Idempotent: ALWAYS prompt for a key. If one is already stored, just
# tell the user — they Ctrl-C to keep it, or paste a new one to replace.
# Avoids a K/R/C menu nobody enjoys reading.
existing_key=$(read_stored_key)
OPENROUTER_KEY=""

echo ""
if [[ -n "$existing_key" ]]; then
  echo "A key is already stored in Keychain (fingerprint: $(fingerprint "$existing_key"))."
  echo "To keep it as-is, press Ctrl-C now. To replace it, paste a new one below."
else
  echo "No OpenRouter key found in Keychain. Get one at https://openrouter.ai/keys"
fi
read_openrouter_key OPENROUTER_KEY
store_key "$OPENROUTER_KEY"
if [[ -n "$existing_key" ]]; then
  ok "Replaced stored OpenRouter key in Keychain"
else
  ok "Stored OpenRouter key in macOS Keychain (service: $CLAUDE_OPENROUTER_KEYCHAIN_SERVICE)"
fi

# ── Step 2: pick the default model ─────────────────────────────────────
# If a wrapper already exists, default to whatever it had baked in last
# time — re-runs shouldn't silently flip the user's model choice unless
# they actively change it. Fall back to the paid default if no wrapper.
previous_model=$(read_installed_default_model)
if [[ -n "$previous_model" ]]; then
  info "Wrapper already exists with default model: $previous_model"
  echo "Press Enter to keep it, or pick a new default below."
fi
SELECTED_MODEL=""
pick_model SELECTED_MODEL
# pick_model always sets a value; previous_model logic is informational.
# To actually preserve previous_model on Enter we'd need pick_model to
# accept it as the default. Keeping the simpler "always offer the menu"
# behavior — the menu is two lines and re-runs are rare.

# ── Step 3: install (or refresh) the wrapper binary ────────────────────
install_wrapper "$SELECTED_MODEL"
ok "Installed claude-openrouter at $CLAUDE_OPENROUTER_BIN (default model: $SELECTED_MODEL)"

# ── Step 4: ensure PATH ────────────────────────────────────────────────
ensure_local_bin_on_path

# ── Step 5: smoke-test the gateway end-to-end ──────────────────────────
echo ""
info "Probing $CLAUDE_OPENROUTER_BASE_URL/messages with model $SELECTED_MODEL..."
probe_openrouter "$OPENROUTER_KEY" "$SELECTED_MODEL" || true

echo ""
echo "Commands:"
echo "  • claude-openrouter                                start a session via OpenRouter"
echo "  • claude-openrouter --model <id>                   override per session"
echo "  • ./setup-claude-openrouter.sh                     re-run to change the key"
echo "  • ./setup-claude-openrouter.sh --test              verify the API works"
echo "  • ./setup-claude-openrouter.sh --uninstall         remove wrapper + key"
