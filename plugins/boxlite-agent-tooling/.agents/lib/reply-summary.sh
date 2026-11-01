#!/usr/bin/env bash
# Compatibility entry point for text measurements; transcript recovery stays here.
# Requires verdict-audit-state.sh for recovery. Sourcing does not read policy data.
# Bash 3.2 can exit inside a failed nested source before its caller handles status.
[[ -f "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts/check.sh" &&
   -r "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts/check.sh" ]] || {
  printf 'boxlite-writing: checker unavailable\n' >&2; return 2;
}
# shellcheck source=../skills/boxlite-writing/scripts/check.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts" && pwd -P)/check.sh" || return 2

# The same snapshot bound the verdict check puts on the transcript it reads.
reply_summary_snapshot_max_bytes=262144

# The transcript's final turn, read by the verdict check's own bounded snapshot
# reader. The snapshot goes to a fresh path in the caller's scratch directory.
_reply_summary_snapshot() {  # transcript-path scratch-dir -> bounded JSON
  local snapshot="$2/final-turn.json" identity state
  [[ -n "${1-}" && -f "$1" && ! -L "$1" && -d "${2-}" ]] || return 1
  # shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh, which callers source.
  identity="$(verdict_audit_snapshot_final_turn_identity "$1" "$snapshot" \
    "$verdict_audit_final_turn_max_bytes" "$reply_summary_snapshot_max_bytes" \
    2>/dev/null)" || return 1
  state="$(verdict_audit_read_regular_state "$snapshot" \
    "$reply_summary_snapshot_max_bytes" json "$identity" 2>/dev/null)" || return 1
  verdict_audit_unlink_if_identity "$snapshot" "$identity" 2>/dev/null || true
  [[ "$state" == *$'\n'* ]] || return 1
  printf '%s' "${state#*$'\n'}"
}

reply_summary_last_text() { # transcript-path scratch-dir -> last assistant text
  _reply_summary_snapshot "$1" "$2" | jq -er 'select(.truncated == false) |
    [.records[] | select(.kind == "assistant") | .texts | join("\n")] | last // ""'
}
