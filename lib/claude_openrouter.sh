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
# Model + provider selection is fully controlled by a hardcoded
# OpenRouter Preset (`moneymeans`). The preset owns which model to use,
# which provider to route through, and pricing/fallback rules. Change it
# in one place — https://openrouter.ai/settings/presets — and every
# engineer on the team picks up the new config on their next request.
# The wrapper never asks the user about models or presets; the only
# question during setup is the API key.
#
# Modes (dispatched from $1):
#   (none)         Idempotent install. Prompts for or replaces the key,
#                  refreshes the wrapper, probes the gateway.
#   --test         No install — round-trips a real /v1/messages request
#                  against OpenRouter with the stored key + the hardcoded
#                  preset and prints the response. Use to verify health.
#   --uninstall    Removes the wrapper binary + Keychain entry. Does NOT
#                  touch the shared ~/.local/bin PATH block in .zshrc
#                  (the main `claude` binary depends on it too).
#
# This is intentionally NOT wired into setup.sh — it's an opt-in
# experiment for engineers who want to try OpenRouter as the engine.

CLAUDE_OPENROUTER_BIN="$HOME/.local/bin/claude-openrouter"
CLAUDE_OPENROUTER_KEYCHAIN_SERVICE="claude-openrouter"
# Claude Code appends "/v1/messages" itself to ANTHROPIC_BASE_URL, so the
# wrapper must export the bare "…/api" prefix. If we set "…/api/v1" the
# client ends up POSTing to "…/api/v1/v1/messages" and OpenRouter 404s.
CLAUDE_OPENROUTER_BASE_URL="https://openrouter.ai/api"
# Full path we use ourselves for direct curl probes (install-time smoke
# test and --test). We don't rely on the SDK's appending behavior here.
CLAUDE_OPENROUTER_PROBE_URL="$CLAUDE_OPENROUTER_BASE_URL/v1/messages"

# The hardcoded OpenRouter Preset name. The preset lives in the
# OpenRouter dashboard and owns:
#   • which model claude-openrouter uses
#   • which provider(s) requests are pinned to (with allow_fallbacks:false
#     for predictable cost + jurisdiction)
#   • any spend guardrails we want to enforce team-wide
#
# We send the bare "@preset/<name>" as the model string — no base model
# prefix — so OpenRouter reads everything (model included) out of the
# preset. That means changes in the dashboard propagate immediately;
# nothing has to be re-baked into the wrapper on every engineer's laptop.
CLAUDE_OPENROUTER_PRESET="moneymeans"
CLAUDE_OPENROUTER_MODEL_STRING="@preset/$CLAUDE_OPENROUTER_PRESET"

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

# Read a single line as a masked secret. Each printable byte the user
# pastes or types shows a `.` in the prompt so they can see the paste
# was received (73 dots for a normal OpenRouter key). The actual
# characters never hit scrollback. Backspace erases the last dot.
# Enter / newline ends input.
#
# We take direct control of the tty for this read: put it in raw
# (non-canonical, no-echo) mode, disable bracketed paste at both the
# terminal and stty levels, read one byte at a time, then fully restore
# the tty on the way out. This is more code than `read -rs` in cooked
# mode, but it's the only way to (a) show live feedback and (b) be sure
# no leftover bytes (bracketed-paste tail markers, CRLF stragglers) sit
# in the tty buffer to trip up the next interactive read in the script.
#
# Writes the captured string into the variable named in $1 (bash nameref-ish).
read_masked_line() {
  local __dest="$1"
  local prompt="${2:-  key: }"
  local buf="" ch n_visible=0

  # No controlling tty (piped stdin, CI) → fall back to plain read.
  if [[ ! -t 0 ]]; then
    IFS= read -r buf
    printf -v "$__dest" '%s' "$buf"
    return
  fi

  # Save every tty setting so we can restore precisely on exit. `stty -g`
  # emits an opaque cookie the same `stty` can consume verbatim.
  local saved_stty
  saved_stty=$(stty -g)

  # Trap ensures we always restore the tty and re-enable echo even if
  # the user Ctrl-C's out of the read.
  # shellcheck disable=SC2064  # intentional: capture $saved_stty at trap-set time
  trap "stty '$saved_stty' 2>/dev/null; printf '\e[?2004l' >&2" EXIT INT TERM

  # Disable bracketed paste at the terminal level. Belt-and-suspenders:
  # some terminals (iTerm2) will still send the \e[200~/\e[201~ markers
  # if the paste starts before this sequence takes effect, so the byte
  # loop below also drops them.
  printf '\e[?2004l' >&2

  # Non-canonical + no-echo. min=1 time=0 means `read` blocks until at
  # least one byte is available, then returns exactly that byte — no
  # line buffering, no cooked-mode Enter handling.
  stty -icanon -echo min 1 time 0 2>/dev/null || {
    # If stty fails for some reason, fall back to the boring cooked read
    # so setup can still complete.
    stty "$saved_stty" 2>/dev/null
    trap - EXIT INT TERM
    IFS= read -rs -p "$prompt" buf
    echo "" >&2
    buf="${buf//$'\e[200~'/}"
    buf="${buf//$'\e[201~'/}"
    buf="${buf%$'\r'}"
    printf -v "$__dest" '%s' "$buf"
    return
  }

  printf '%s' "$prompt" >&2

  # Byte-by-byte loop. We break on \r or \n (either can arrive depending
  # on the terminal). CSI escape sequences (bracketed paste markers,
  # stray arrow keys) are consumed and dropped. Everything else appends
  # to the buffer and shows a dot.
  while IFS= read -rn1 ch; do
    case "$ch" in
      $'\n'|$'\r')
        break
        ;;
      $'\b'|$'\x7f')
        if (( n_visible > 0 )); then
          buf="${buf:0:${#buf}-1}"
          n_visible=$(( n_visible - 1 ))
          printf '\b \b' >&2
        fi
        ;;
      $'\033')
        # Possible CSI sequence — read the '[' and then param bytes up
        # to the final letter. Drop the whole sequence. Bracketed-paste
        # markers (\e[200~, \e[201~) land here; so do stray arrow keys.
        local next
        IFS= read -rn1 -t 1 next 2>/dev/null || true
        if [[ "$next" == '[' ]]; then
          local final
          while IFS= read -rn1 -t 1 final 2>/dev/null; do
            [[ "$final" =~ [0-9\;] ]] || break
          done
        fi
        continue
        ;;
      '')
        # Empty read shouldn't happen in min=1 mode, but guard anyway.
        continue
        ;;
      *)
        buf+="$ch"
        n_visible=$(( n_visible + 1 ))
        printf '.' >&2
        ;;
    esac
  done
  printf '\n' >&2

  # Restore tty BEFORE draining, so if drain leaves something behind
  # (shouldn't, but…) it lands in a normal cooked-mode buffer.
  stty "$saved_stty" 2>/dev/null
  trap - EXIT INT TERM

  # Best-effort drain: in raw mode with min=1 we consumed exactly what
  # was queued, but flip stty briefly to non-blocking and eat anything
  # the terminal delivered after our loop broke (rare edge case with
  # some tmux configurations).
  stty -icanon min 0 time 0 2>/dev/null && {
    local _drain _i
    for (( _i = 0; _i < 64; _i++ )); do
      _drain=""
      IFS= read -rn1 _drain 2>/dev/null
      [[ -z "$_drain" ]] && break
    done
    stty "$saved_stty" 2>/dev/null
  }

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
    echo -e "${YELLOW}│  Each byte shows as a dot; press Enter ONCE when done.    │${NC}"
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
    -X POST "$CLAUDE_OPENROUTER_PROBE_URL" \
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
      err "OpenRouter returned 404. Most likely the preset '$CLAUDE_OPENROUTER_PRESET' doesn't exist on this account — create it at https://openrouter.ai/settings/presets."
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
# The wrapper is intentionally simple: read the key, set env vars, run
# the Anthropic-headroom check, exec claude. No flag parsing for model
# or preset — those are owned by the hardcoded OpenRouter Preset.
install_wrapper() {
  mkdir -p "$HOME/.local/bin"
  cat > "$CLAUDE_OPENROUTER_BIN" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by mac-setup/lib/claude_openrouter.sh — re-run
# setup-claude-openrouter.sh to regenerate. Do not edit by hand; changes
# will be lost.
#
# Runs Claude Code against OpenRouter instead of Anthropic's API. The
# OpenRouter key is fetched from macOS Keychain on every launch, so
# nothing secret lives on disk. All args are passed through to the real
# \`claude\` binary except --no-usage-check, which we strip and consume.
#
# Model and provider are controlled entirely by the OpenRouter Preset
# "$CLAUDE_OPENROUTER_PRESET" (edit at https://openrouter.ai/settings/presets).
# The wrapper sends the bare model string "@preset/$CLAUDE_OPENROUTER_PRESET" —
# OpenRouter reads model + provider rules out of the preset. That means
# team-wide changes happen in one place; no need to re-run this script
# after a preset update.
#
# Before launch, if the user is logged in to the real Claude Code and
# EITHER their 5h or 7d quota has headroom left (utilization < 99%), we
# warn and ask whether to proceed — the user wants to burn every last
# percent of the plan before spending OpenRouter credits. Stay silent
# only when both buckets are effectively exhausted. Pass --no-usage-check
# to skip the check entirely.
set -euo pipefail

KEYCHAIN_SERVICE="$CLAUDE_OPENROUTER_KEYCHAIN_SERVICE"
BASE_URL="$CLAUDE_OPENROUTER_BASE_URL"
MODEL_STRING="$CLAUDE_OPENROUTER_MODEL_STRING"

key=\$(security find-generic-password -s "\$KEYCHAIN_SERVICE" -a "\$USER" -w 2>/dev/null || true)
if [[ -z "\$key" ]]; then
  echo "claude-openrouter: no OpenRouter key in Keychain. Run setup-claude-openrouter.sh to add one." >&2
  exit 1
fi

# Consume --no-usage-check; forward everything else to claude untouched.
skip_usage_check=0
forwarded_args=()
while (( \$# > 0 )); do
  case "\$1" in
    --no-usage-check)
      skip_usage_check=1
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
export ANTHROPIC_MODEL="\$MODEL_STRING"
# Fast Mode talks to an Anthropic-org-scoped endpoint; skip that check
# when we're not pointed at Anthropic.
export CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1

echo "claude-openrouter → \$BASE_URL  (preset: $CLAUDE_OPENROUTER_PRESET)" >&2

# ── Anthropic-still-available check ──────────────────────────────────
# If the user is logged in to the real Claude Code AND their plan quota
# still has plenty of headroom, they probably meant to run \`claude\`, not
# this wrapper. Warn and confirm before spending OpenRouter credits.
#
# The check is best-effort: any failure (no keychain entry, expired
# token, network hiccup, endpoint change, malformed JSON) is silently
# ignored — we never block launch on a diagnostic we couldn't run.
#
# The endpoint is undocumented (\`/api/oauth/usage\` with the
# oauth-2025-04-20 beta header) and could change; keep the parsing
# forgiving. Suppress the whole block with --no-usage-check.
if (( skip_usage_check == 0 )); then
  anth_blob=\$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  if [[ -n "\$anth_blob" ]]; then
    # python3 does two things at once: extract accessToken + expiresAt,
    # and check expiresAt is still in the future. Print "TOKEN\tEXPIRES"
    # or nothing. Failing silently on any parse error is intentional.
    # \`read\` returns 1 on EOF; under set -e that kills the wrapper. The
    # trailing || true keeps us going when python prints nothing (bad JSON,
    # missing fields, expired-token early-exit).
    anth_token=""; anth_expires=""
    read -r anth_token anth_expires < <(printf '%s' "\$anth_blob" | \
      python3 -c 'import json,sys,time
try:
  b=json.loads(sys.stdin.read()).get("claudeAiOauth") or {}
  t=b.get("accessToken"); e=b.get("expiresAt")
  if isinstance(e,(int,float)):
    e = e/1000 if e>1e11 else e
    if e <= time.time(): sys.exit(0)
  if t: print(t, e or "")
except Exception: pass' 2>/dev/null) || true
    if [[ -n "\${anth_token:-}" ]]; then
      usage_body=\$(curl -sS --max-time 4 \
        -H "Authorization: Bearer \$anth_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)
      if [[ -n "\$usage_body" ]]; then
        # Extract five_hour + seven_day utilization (integers 0-100).
        # The API returns utilization as a float (e.g. 40.0, 97.0). Round
        # to int here so the shell numeric compare below works — bash's
        # ((…)) doesn't accept floats. Skip a bucket entirely if it has no
        # utilization value (API user with no plan data). resets_at is an
        # ISO-8601 datetime — trim to local YYYY-MM-DDTHH:MM for the banner.
        util_5h=""; util_7d=""; reset_5h=""; reset_7d=""
        read -r util_5h util_7d reset_5h reset_7d < <(printf '%s' "\$usage_body" | \
          python3 -c 'import json,sys
from datetime import datetime
def u(b):
  v=(b or {}).get("utilization")
  return str(round(v)) if isinstance(v,(int,float)) else ""
def r(b):
  s=(b or {}).get("resets_at")
  if not isinstance(s,str): return ""
  try:
    # No space in the output — `read` word-splits on whitespace, so a
    # "YYYY-MM-DD HH:MM" would land in two variables. Use T as the sep.
    return datetime.fromisoformat(s.replace("Z","+00:00")).astimezone().strftime("%Y-%m-%dT%H:%M")
  except Exception:
    return ""
try:
  d=json.loads(sys.stdin.read())
  fh=d.get("five_hour") or {}; sd=d.get("seven_day") or {}
  print(u(fh), u(sd), r(fh), r(sd))
except Exception: pass' 2>/dev/null) || true
        # Warn only when BOTH buckets have headroom — running \`claude\`
        # right now would actually get you something. If either bucket is
        # exhausted (≥99%), the plan is effectively spent: the exhausted
        # bucket becomes the binding rate limit and headroom in the other
        # bucket is unreachable until it resets. In that case
        # \`claude-openrouter\` is the correct tool and we stay silent.
        # ≥99% (not ==100%) leaves a hair of margin for the API's
        # rounding so 98.7 rounded to 99 doesn't nag.
        if [[ -n "\${util_5h:-}" && -n "\${util_7d:-}" ]] && \
           [[ "\$util_5h" =~ ^[0-9]+\$ ]] && [[ "\$util_7d" =~ ^[0-9]+\$ ]] && \
           (( util_5h < 99 )) && (( util_7d < 99 )); then
          left_5h=\$(( 100 - util_5h ))
          left_7d=\$(( 100 - util_7d ))
          printf '\n\033[33m⚠  Anthropic Claude still has headroom — burn that first:\033[0m\n' >&2
          printf '     5-hour:  %s%% left  (%s%% used)' "\$left_5h" "\$util_5h" >&2
          [[ -n "\$reset_5h" ]] && printf '   resets %s' "\$reset_5h" >&2
          printf '\n     7-day:   %s%% left  (%s%% used)' "\$left_7d" "\$util_7d" >&2
          [[ -n "\$reset_7d" ]] && printf '   resets %s' "\$reset_7d" >&2
          printf '\n   Run \`claude\` instead to use it up before spending OpenRouter credits.\n\n' >&2
          # Non-tty stdin (piped input, CI) → skip the prompt; the
          # warning alone is enough. Otherwise ask for confirmation.
          if [[ -t 0 ]]; then
            read -rp "   Continue with OpenRouter anyway? [y/N] " reply
            if [[ ! "\$reply" =~ ^[Yy]\$ ]]; then
              echo "Aborted." >&2
              exit 130
            fi
          fi
        fi
      fi
    fi
  fi
fi

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
    info "Using stored key ($(fingerprint "$stored_key")), preset: $CLAUDE_OPENROUTER_PRESET"
    if probe_openrouter "$stored_key" "$CLAUDE_OPENROUTER_MODEL_STRING"; then
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

# ── Step 2: install (or refresh) the wrapper binary ────────────────────
install_wrapper
ok "Installed claude-openrouter at $CLAUDE_OPENROUTER_BIN (preset: $CLAUDE_OPENROUTER_PRESET)"

# ── Step 3: ensure PATH ────────────────────────────────────────────────
ensure_local_bin_on_path

# ── Step 4: smoke-test the gateway end-to-end ──────────────────────────
# Exercises the exact preset path the wrapper will use. If the preset
# doesn't exist on this OpenRouter account, the probe surfaces it here
# rather than at first real use.
echo ""
info "Probing $CLAUDE_OPENROUTER_PROBE_URL with model $CLAUDE_OPENROUTER_MODEL_STRING..."
probe_openrouter "$OPENROUTER_KEY" "$CLAUDE_OPENROUTER_MODEL_STRING" || true

echo ""
echo "Commands:"
echo "  • claude-openrouter                          start a session via OpenRouter (preset: $CLAUDE_OPENROUTER_PRESET)"
echo "  • claude-openrouter --no-usage-check         skip the 'Anthropic is still available' warning"
echo "  • ./setup-claude-openrouter.sh               re-run to change the key"
echo "  • ./setup-claude-openrouter.sh --test        verify the API works"
echo "  • ./setup-claude-openrouter.sh --uninstall   remove wrapper + key"
