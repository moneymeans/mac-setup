# shellcheck shell=bash
# Sourced by setup.sh immediately after common.sh, before any stage runs.
#
# A step-outcome registry, so the end of a 30-minute run can tell the user
# what actually happened rather than reprinting the same optimistic list of
# stage names every time.
#
# The problem this solves: stages used to report only into scrollback. A
# stage could no-op (Docker.app never installed, so daemon-start was
# skipped with a warn 800 lines up) and the closing banner would still say
# "Docker Desktop (daemon running)" because that line was hardcoded. A new
# starter reads the last screen, not the scrollback, so a silent failure
# read as success and got discovered days later.
#
# Every stage now records exactly one outcome plus, when it isn't ok, the
# literal command that fixes it. The final report is generated from those
# records, so it cannot drift from reality the way a hardcoded list does.
#
# Usage (one call per stage, at the point the outcome is known):
#   step_ok   "Docker Desktop"  "daemon running"
#   step_warn "Docker Desktop"  "daemon didn't start" "open -a Docker"
#   step_fail "Docker Desktop"  "not installed"       "brew install --cask docker-desktop"
#   step_skip "Repo clone"      "--no-clone"
#
# The third argument (detail) is a short phrase shown next to the status.
# The fourth (remediation) is a command or URL the user can act on; it's
# required in spirit for warn/fail and ignored for ok/skip.
#
# bash 3.2: no associative arrays. We keep four parallel indexed arrays
# and a tab-separated encoding, which is safe because none of the fields
# may contain a tab (all are authored here, not user input).

: "${STEP_REPORT_INIT:=0}"
if (( STEP_REPORT_INIT == 0 )); then
  STEP_NAMES=()
  STEP_STATES=()
  STEP_DETAILS=()
  STEP_FIXES=()
  STEP_REPORT_INIT=1
fi

# Record an outcome. If the same step name was already recorded, the new
# outcome REPLACES the old one rather than appending a second row — a
# stage that warns early and then recovers (docker retrying its install)
# should show one honest final state, not a contradictory pair.
_step_record() {
  local state="$1" name="$2" detail="${3:-}" fix="${4:-}"
  local i
  for (( i=0; i<${#STEP_NAMES[@]}; i++ )); do
    if [[ "${STEP_NAMES[$i]}" == "$name" ]]; then
      STEP_STATES[$i]="$state"
      STEP_DETAILS[$i]="$detail"
      STEP_FIXES[$i]="$fix"
      return 0
    fi
  done
  STEP_NAMES+=("$name")
  STEP_STATES+=("$state")
  STEP_DETAILS+=("$detail")
  STEP_FIXES+=("$fix")
}

# ok    — the thing is installed/configured and was verified.
# warn  — it mostly worked, or is optional and unfinished. Run continues.
# fail  — it did not work and something downstream will suffer.
# skip  — deliberately not attempted (flag, env var, or user said no).
#
# warn/fail also set SETUP_HAD_WARNINGS via warn(), so the closing banner
# colour stays consistent with the report.
step_ok()   { _step_record ok   "$1" "${2:-}" ""; }
step_skip() { _step_record skip "$1" "${2:-}" ""; }
step_warn() { _step_record warn "$1" "${2:-}" "${3:-}"; SETUP_HAD_WARNINGS=1; }
step_fail() { _step_record fail "$1" "${2:-}" "${3:-}"; SETUP_HAD_WARNINGS=1; }

# Count steps in a given state. Used by setup.sh to pick the banner colour
# and by the report to decide whether to print the remediation section.
step_count() {
  local want="$1" i n=0
  for (( i=0; i<${#STEP_STATES[@]}; i++ )); do
    [[ "${STEP_STATES[$i]}" == "$want" ]] && n=$(( n + 1 ))
  done
  echo "$n"
}

# Print the full report: one line per recorded step in the order they ran,
# then a numbered "needs your attention" block listing only the warn/fail
# rows with their fix commands.
#
# Symbols are ASCII-plus-glyph rather than emoji: iTerm and Terminal both
# render these at a predictable single-cell width, so the columns line up.
step_report() {
  local i state name detail fix
  local pad width=0

  # Column width from the longest step name, so details align.
  for (( i=0; i<${#STEP_NAMES[@]}; i++ )); do
    (( ${#STEP_NAMES[$i]} > width )) && width=${#STEP_NAMES[$i]}
  done

  for (( i=0; i<${#STEP_NAMES[@]}; i++ )); do
    state="${STEP_STATES[$i]}"
    name="${STEP_NAMES[$i]}"
    detail="${STEP_DETAILS[$i]}"
    pad=$(( width - ${#name} ))
    local spaces=""
    (( pad > 0 )) && spaces="$(printf '%*s' "$pad" '')"

    case "$state" in
      ok)   printf "  ${GREEN}\xe2\x9c\x93${NC}  %s%s  %s\n" "$name" "$spaces" "$detail" ;;
      warn) printf "  ${YELLOW}\xe2\x9a\xa0${NC}  %s%s  ${YELLOW}%s${NC}\n" "$name" "$spaces" "$detail" ;;
      fail) printf "  ${RED}\xe2\x9c\x97${NC}  %s%s  ${RED}%s${NC}\n" "$name" "$spaces" "$detail" ;;
      skip) printf "  ${BLUE}\xe2\x80\x93${NC}  %s%s  ${BLUE}skipped${NC} %s\n" "$name" "$spaces" "$detail" ;;
    esac
  done

  local problems
  problems=$(( $(step_count warn) + $(step_count fail) ))
  if (( problems == 0 )); then
    return 0
  fi

  echo ""
  echo -e "${YELLOW}${problems} thing(s) need your attention — copy/paste to fix:${NC}"
  echo ""
  local n=0
  for (( i=0; i<${#STEP_NAMES[@]}; i++ )); do
    state="${STEP_STATES[$i]}"
    [[ "$state" == "warn" || "$state" == "fail" ]] || continue
    n=$(( n + 1 ))
    fix="${STEP_FIXES[$i]}"
    printf "  %d. %s — %s\n" "$n" "${STEP_NAMES[$i]}" "${STEP_DETAILS[$i]}"
    if [[ -n "$fix" ]]; then
      printf "     ${GREEN}%s${NC}\n" "$fix"
    fi
  done
  echo ""
  echo "  Stuck on any of these? Ask Claude Code — from this folder run:"
  echo -e "     ${GREEN}claude \"setup.sh reported these problems, help me fix them\"${NC}"
}
