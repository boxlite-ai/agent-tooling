#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# StopFailure hook: record WHY a turn died on the API, and tell the human.
# Tests: bash .agents/hooks/record-api-failure.test.sh
#
# Claude Code fires StopFailure INSTEAD OF Stop when an API error ended the turn, and
# the host documents the event as fire-and-forget: "hook output and exit codes are
# ignored", and the dispatcher discards the result. So this hook cannot block, cannot
# resume, and must never try. It exists for the two things it still can do:
#
#   1. Record the error KIND. The payload's `error` field is a closed enum, and it is
#      the ONLY place that enum is exposed: a `claude -p --output-format json` result
#      reports terminal_reason "api_error" with no kind attached (the error variant's
#      `errors` array is free text). Without this record an out-of-process supervisor
#      cannot tell a revoked token from an overloaded server, so it either gives up on
#      transient faults or retries permanent ones — resume-on-network-error.sh reads
#      this file to avoid both.
#   2. Notify the human. Because hook output is discarded, the notification is written
#      straight to the controlling terminal instead of returned to the host.
#
# Everything here is best-effort by construction: a failure to record or notify must
# never add a second failure on top of the one being reported, so every path exits 0.
set -uo pipefail

state_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/verdict-audit-state.sh"
# perl is not used directly here; the sourced library's atomic publish needs it, and a
# missing one would otherwise fail deep inside the write with nowhere to report it.
for required_command in jq perl; do
  command -v "$required_command" >/dev/null 2>&1 || exit 0
done
[[ -r "$state_lib" ]] || exit 0
# shellcheck source=../lib/verdict-audit-state.sh
source "$state_lib" || exit 0

payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '
  if type == "object" and (.hook_event_name | type) == "string"
  then .hook_event_name else "" end
' 2>/dev/null || true)"
[[ "$event" == "StopFailure" ]] || exit 0

# Validated at the boundary against the host's own enum. An unrecognised kind becomes
# `unknown` rather than being passed through: downstream policy keys off this value, and
# a value outside the enum must not silently land in a retry decision.
#
# Membership is an exact per-element comparison, never a substring test against a
# space-joined list: `rate_limit overloaded` is a substring of such a list while being
# no member of it, so a glob test would publish that string verbatim.
known_kinds=(authentication_failed oauth_org_not_allowed account_on_hold billing_error
             rate_limit overloaded invalid_request model_not_found server_error
             unknown max_output_tokens)
kind_is_member() {  # $1 = candidate, $2.. = members
  local candidate="$1" member
  shift
  for member in "$@"; do
    [[ "$candidate" == "$member" ]] && return 0
  done
  return 1
}

error_kind="$(printf '%s' "$payload" | jq -r '.error // "" | tostring' 2>/dev/null || true)"
kind_is_member "$error_kind" "${known_kinds[@]}" || error_kind=unknown

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
state_dir="$project_dir/.agents/state"
record_path="$state_dir/last-api-failure.json"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Publish through the shared primitive so a supervisor polling this path never reads a
# half-written record. Hand-rolling the staging/rename dance here would also mean
# hand-rolling its cleanup, and unlinking a predictable pid-named path without an
# inode-identity check is exactly the class of bug that library exists to remove.
printf '%s' "$payload" | jq -c --arg kind "$error_kind" \
  --argjson at "$(date -u +%s)" '{
    error: $kind,
    error_details: (.error_details // "" | tostring),
    session_id: (.session_id // "" | tostring),
    recorded_at: $at
  }' 2>/dev/null \
  | verdict_audit_write_atomic "$record_path" 2>/dev/null || true

# The host ignores this hook's stdout, so a desktop notification has to be emitted by
# the hook itself. /dev/tty is the session's terminal even though stdout is a pipe;
# with no controlling terminal (CI, a daemon) the attempt must be silent.
#
# `[[ -w /dev/tty ]]` does NOT establish that: the device node is world-writable, so the
# test passes even when this process has no controlling terminal and only the open
# fails. The shell reports a failed redirection on ITS stderr before any command-level
# `2>/dev/null` can apply, so the group's stderr is redirected instead — a hook
# reporting a failure must not print a failure of its own.
{ printf '\033]9;claude: turn ended on API error (%s)\007' "$error_kind" >/dev/tty; } 2>/dev/null || true

exit 0
