# shellcheck shell=bash
# Shared helpers, sourced by setup.sh and every lib/*.sh module.
# Everything here must be idempotent (safe to source multiple times).
#
# NOTE: pre-setup.sh deliberately does NOT source this file — it runs on a
# completely bare Mac before this repo can be assumed present. A small set
# of these helpers is duplicated in pre-setup.sh on purpose. Keep them in
# sync if you change them.

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Track whether any warn() fired during this run. setup.sh reads this to
# decide whether to print the green "Setup complete!" or a yellow
# "Setup finished with warnings — scroll up" banner. Honesty over cheer.
: "${SETUP_HAD_WARNINGS:=0}"

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; SETUP_HAD_WARNINGS=1; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Print a section banner. Replaces the 3-line copy-pasted blocks that
# were drifting (some BLUE, some GREEN) across modules.
section() {
  local title="$1" color="${2:-$BLUE}"
  echo ""
  echo -e "${color}========================================${NC}"
  echo -e "${color}  ${title}${NC}"
  echo -e "${color}========================================${NC}"
  echo ""
}

ZPROFILE="$HOME/.zprofile"
ZSHRC="$HOME/.zshrc"

# Test whether a command is on PATH.
have() { command -v "$1" &>/dev/null; }

# Sentinel-comment markers we write around blocks we append to shell rcs.
# Generic substrings like "DOTNET_ROOT" or "brew shellenv" can collide
# with user comments or other tools' activation lines, leading to silent
# skips or duplicate appends. Sentinel comments are collision-proof.
MAC_SETUP_MARKER_PREFIX="# >>> mac-setup:"
MAC_SETUP_MARKER_SUFFIX="# <<< mac-setup:"

# Append a sentinel-wrapped block to a file once.
# Usage:
#   append_block <file> <name> <<'EOF'
#     ... lines ...
#   EOF
#
# Generates start/end markers like `# >>> mac-setup: dotnet >>>`. Re-runs
# detect the marker and skip, so re-running setup.sh never duplicates the
# block — and a user-edited file with a coincidentally-named export
# (DOTNET_ROOT, VOLTA_HOME) no longer prevents us from re-adding our own.
append_block() {
  local file="$1" name="$2"
  local marker="$MAC_SETUP_MARKER_PREFIX $name >>>"
  if grep -qF "$marker" "$file" 2>/dev/null; then
    return 1
  fi
  {
    echo ""
    echo "$marker"
    cat
    echo "$MAC_SETUP_MARKER_SUFFIX $name <<<"
  } >> "$file"
  return 0
}

# Replace a sentinel-wrapped block in $file. If the block is absent, behaves
# like append_block. If present, the existing block (and only the existing
# block) is removed and the new content is appended at the end. We append
# rather than substitute in-place because the block content can include
# characters that would need awkward escaping for sed.
#
# Usage mirrors append_block:
#   replace_block <file> <name> <<'EOF'
#     ... new lines ...
#   EOF
#
# Use this when the block's content can legitimately change between runs
# (e.g. DOTNET_ROOT differs by install type), so a stale block on disk must
# be corrected rather than left alone.
replace_block() {
  local file="$1" name="$2"
  local start="$MAC_SETUP_MARKER_PREFIX $name >>>"
  local end="$MAC_SETUP_MARKER_SUFFIX $name <<<"
  local new_content
  new_content="$(cat)"

  if [[ -f "$file" ]] && grep -qF "$start" "$file"; then
    local tmp
    tmp="$(mktemp)"
    # Strip the existing block, preserving everything else verbatim.
    awk -v s="$start" -v e="$end" '
      index($0, s) { skip=1; next }
      index($0, e) { skip=0; next }
      !skip { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi

  {
    echo ""
    echo "$start"
    printf '%s\n' "$new_content"
    echo "$end"
  } >> "$file"
}

# Prompt the user for a value, with an optional default. Re-prompts on empty.
# Usage: ask "Your name" GIT_NAME "$(git config --global user.name)"
ask() {
  local prompt="$1" __varname="$2" default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
  else
    while [[ -z "${value:-}" ]]; do read -rp "$prompt: " value; done
  fi
  printf -v "$__varname" '%s' "$value"
}

# NOTE: Don't wrap the dual-mode return idiom in a helper function — a
# `return` inside the helper only returns from the helper, not from the
# script that called it. The correct form is INLINE in each call site:
#
#     return 0 2>/dev/null || exit 0
#
# `return` works when the file is sourced; on the (rare) case of executing
# the lib/*.sh directly, `return` errors and we fall through to `exit`.

# Interactive multi-select widget. Arrow keys to move, Space to toggle,
# Enter to confirm, q to abort.
#
# Usage:
#   multi_select_result=()
#   multi_select \
#     "Pick the browsers you want installed:" \
#     "chrome:default" "firefox" "arc" "brave"
#   # multi_select_result is now an array of the selected keys.
#
# Each option is "key" or "key:annotation". The annotation "default"
# pre-checks the row and is shown as "(default)" next to the label; any
# other annotation is shown verbatim in parens.
#
# Works on macOS bash 3.2 — no associative arrays, no readarray.
# Falls back to picking defaults when stdin isn't a tty (curl|bash, CI).
#
# Returns 0 on Enter, 1 on q/abort. Result lands in the GLOBAL array
# `multi_select_result` (a function can't return arrays in bash 3.2).
#
# Implementation: redraws the menu in a small inline region using
# cursor-save/restore (\033[s and \033[u). Avoids fragile line-counting
# math — no matter how many lines we draw, we always return to the same
# anchor point and clear from there before redrawing.
multi_select() {
  local title="$1"; shift
  local n=$#
  local i

  if [[ ! -t 0 ]]; then
    multi_select_result=()
    for opt in "$@"; do
      local r="${opt#*:}"
      [[ "$opt" == *:default ]] && multi_select_result+=("${opt%%:*}")
    done
    return 0
  fi

  local keys=() labels=() checked=()
  for opt in "$@"; do
    local key="${opt%%:*}"
    local annotation=""
    [[ "$opt" == *:* ]] && annotation="${opt#*:}"
    keys+=("$key")
    if [[ "$annotation" == "default" ]]; then
      labels+=("$key  (default)")
      checked+=(1)
    elif [[ -n "$annotation" ]]; then
      labels+=("$key  ($annotation)")
      checked+=(0)
    else
      labels+=("$key")
      checked+=(0)
    fi
  done

  local cursor=0

  printf '\n%s\n\n' "$title"

  # Hide the cursor; restore it on any exit path.
  printf '\033[?25l'
  # shellcheck disable=SC2064
  trap "printf '\033[?25h'" RETURN

  # We draw the same N lines every iteration:
  #   - n option lines
  #   - 1 blank separator
  #   - 1 hint line
  # …each ending in \n. So to redraw we move the cursor up exactly
  # (n + 2) lines before the next draw. This is deterministic and
  # doesn't depend on iffy DECSC/DECRC behavior in iTerm/tmux.
  local lines_per_frame=$(( n + 2 ))
  local first_draw=1

  while true; do
    if (( first_draw == 0 )); then
      printf '\033[%dA\033[J' "$lines_per_frame"
    fi
    first_draw=0

    for (( i=0; i<n; i++ )); do
      local mark=' '
      [[ "${checked[$i]}" == "1" ]] && mark='x'
      if (( i == cursor )); then
        printf "  \033[1;36m>\033[0m [%s] %s\n" "$mark" "${labels[$i]}"
      else
        printf "    [%s] %s\n" "$mark" "${labels[$i]}"
      fi
    done
    echo ""
    printf "  \033[2m\xe2\x86\x91/\xe2\x86\x93 move \xc2\xb7 SPACE toggle \xc2\xb7 ENTER confirm \xc2\xb7 q skip\033[0m\n"

    # Read one keypress. An arrow key arrives as a 3-byte escape sequence
    # (\033 + [ + A/B/C/D) sent in a single burst, so when we read the
    # lead ESC the rest is already buffered.
    #
    # macOS ships bash 3.2 whose `read -t` only accepts INTEGER seconds —
    # `read -t 0.1` errors with "invalid timeout specification". We use
    # `-t 1` instead; with the bytes already buffered, this resolves
    # instantly. The 1-second wait only kicks in if the user pressed
    # plain ESC with no follow-up, which is fine (the loop continues).
    local k1="" k2="" k3=""
    IFS= read -rsn1 k1 || continue
    if [[ "$k1" == $'\033' ]]; then
      IFS= read -rsn1 -t 1 k2 2>/dev/null || true
      IFS= read -rsn1 -t 1 k3 2>/dev/null || true
    fi
    local key="$k1$k2$k3"

    case "$key" in
      $'\033[A'|$'\033OA'|k|K)
        (( cursor > 0 )) && cursor=$(( cursor - 1 ))
        ;;
      $'\033[B'|$'\033OB'|j|J)
        (( cursor < n - 1 )) && cursor=$(( cursor + 1 ))
        ;;
      ' ')
        if [[ "${checked[$cursor]}" == "1" ]]; then
          checked[$cursor]=0
        else
          checked[$cursor]=1
        fi
        ;;
      ''|$'\n'|$'\r')
        multi_select_result=()
        for (( i=0; i<n; i++ )); do
          [[ "${checked[$i]}" == "1" ]] && multi_select_result+=("${keys[$i]}")
        done
        printf '\033[?25h'
        return 0
        ;;
      q|Q)
        printf '\033[?25h'
        multi_select_result=()
        return 1
        ;;
    esac
  done
}

# Test whether GitHub SSH access works. Two retries with a 3s backoff to
# absorb transient network blips. Returns 0 on success, 1 otherwise.
# Used by lib/preflight.sh and lib/repos.sh; pre-setup.sh has its own copy.
#
# `ssh -T git@github.com` exits 1 on success ("doesn't provide shell access"),
# so we capture stdout/stderr to a var and grep separately rather than pipe.
# A piped form would be broken by `set -o pipefail` in the caller.
github_ssh_ok() {
  local attempt output
  for attempt in 1 2 3; do
    output=$(ssh -T \
                 -o StrictHostKeyChecking=yes \
                 -o ConnectTimeout=5 \
                 git@github.com 2>&1 || true)
    if echo "$output" | grep -q "successfully authenticated"; then
      return 0
    fi
    [[ $attempt -lt 3 ]] && sleep 3
  done
  return 1
}
