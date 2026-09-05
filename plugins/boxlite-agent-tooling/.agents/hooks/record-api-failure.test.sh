#!/usr/bin/env bash
# Behavioral tests at the hook's stdin/exit boundary.
# Run with: bash plugins/boxlite-agent-tooling/.agents/hooks/record-api-failure.test.sh
#
# StopFailure is fire-and-forget: the host ignores this hook's output and exit code.
# So the only observable contract is the record it publishes, plus the promise that it
# never fails loudly — every case here asserts exit 0.
set -uo pipefail

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
subject="$hook_dir/record-api-failure.sh"
[[ -r "$subject" ]] || { printf 'missing %s\n' "$subject" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/record-api-failure-test.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
export CLAUDE_PROJECT_DIR="$work/project"
record="$CLAUDE_PROJECT_DIR/.agents/state/last-api-failure.json"

pass=0
fail=0
ok()  { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$1"; }
bad() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$1"; }
check() {  # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else
    bad "$1"; printf '        expected %s\n        actual   %s\n' "$2" "$3"
  fi
}

# stderr is captured, never discarded: swallowing it with 2>&1 is what let a failed
# /dev/tty redirection go unnoticed. Every case below can therefore assert silence.
feed() {  # payload -> sets rc; leaves the record and captured stderr in place
  printf '%s' "$1" | bash "$subject" >/dev/null 2>"$work/stderr"
  rc=$?
}
stderr_bytes() { wc -c < "$work/stderr" | tr -d ' '; }

printf 'record-api-failure\n'

# ── A recognised kind is recorded verbatim ───────────────────────────────────
rm -f "$record"
feed '{"hook_event_name":"StopFailure","error":"overloaded","error_details":"529","session_id":"s1"}'
check "recognised kind exits 0" "0" "$rc"
# This suite runs with no controlling terminal, so the notification path's open of
# /dev/tty fails here. A `[[ -w /dev/tty ]]` guard does not prevent that (the node is
# world-writable) and a command-level 2>/dev/null does not silence it (the shell
# reports a failed redirection on its own stderr). A hook reporting someone else's
# failure must never emit one of its own.
check "no controlling terminal produces no stderr" "0" "$(stderr_bytes)"
check "recognised kind is recorded" "overloaded" \
  "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"
check "error_details is carried" "529" \
  "$(jq -r '.error_details' "$record" 2>/dev/null || echo MISSING)"
check "session id is carried" "s1" \
  "$(jq -r '.session_id' "$record" 2>/dev/null || echo MISSING)"
if jq -e '.recorded_at | type == "number" and . > 0' "$record" >/dev/null 2>&1; then
  ok "recorded_at is a positive number the reader can age out"
else
  bad "recorded_at is a positive number the reader can age out"
fi

# Every member of the host enum must survive the boundary check, or a real permanent
# fault would be downgraded to `unknown` and retried.
for kind in authentication_failed oauth_org_not_allowed account_on_hold billing_error \
            rate_limit overloaded invalid_request model_not_found server_error \
            unknown max_output_tokens; do
  rm -f "$record"
  feed "{\"hook_event_name\":\"StopFailure\",\"error\":\"$kind\"}"
  check "enum member survives: $kind" "$kind" \
    "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"
done

# ── A kind outside the enum is pinned to unknown, not passed through ─────────
rm -f "$record"
feed '{"hook_event_name":"StopFailure","error":"teapot"}'
check "kind outside the enum becomes unknown" "unknown" \
  "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"

# A single-token stranger is the easy case. These are runs of real enum members, which
# a substring test against a space-joined list accepts while they are members of
# nothing — the bypass that would put an unvalidated string into a retry decision.
for bypass in "rate_limit overloaded" "account_on_hold billing_error" \
              "overloaded invalid_request" " overloaded" "overloaded "; do
  rm -f "$record"
  feed "{\"hook_event_name\":\"StopFailure\",\"error\":\"$bypass\"}"
  check "multi-member run is not a member: '$bypass'" "unknown" \
    "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"
done

rm -f "$record"
feed '{"hook_event_name":"StopFailure"}'
check "absent kind becomes unknown" "unknown" \
  "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"

# ── Other events and junk leave no record and never fail ─────────────────────
rm -f "$record"
feed '{"hook_event_name":"Stop","error":"overloaded"}'
check "a non-StopFailure event exits 0" "0" "$rc"
check "a non-StopFailure event writes no record" "absent" \
  "$([[ -e "$record" ]] && echo present || echo absent)"

rm -f "$record"
feed 'not json at all'
check "malformed input exits 0" "0" "$rc"
check "malformed input writes no record" "absent" \
  "$([[ -e "$record" ]] && echo present || echo absent)"

rm -f "$record"
feed ''
check "empty input exits 0" "0" "$rc"

# ── A previous record is replaced, not appended to ───────────────────────────
feed '{"hook_event_name":"StopFailure","error":"rate_limit"}'
feed '{"hook_event_name":"StopFailure","error":"server_error"}'
check "the newest failure replaces the previous record" "server_error" \
  "$(jq -r '.error' "$record" 2>/dev/null || echo MISSING)"
check "the record stays a single JSON object" "1" \
  "$(jq -s 'length' "$record" 2>/dev/null || echo 0)"
# The shared writer stages at "${destination}.tmp.$$-${RANDOM}" (verdict-audit-state.sh),
# so the glob has to match THAT name — a pattern for some other staging scheme counts
# zero whatever happens and can never fail.
check "no staging files are left behind" "0" \
  "$(find "$(dirname "$record")" -name 'last-api-failure.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
check "the published record is the only file in state" "1" \
  "$(find "$(dirname "$record")" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ── An unwritable state directory must not turn one failure into two ─────────
readonly_project="$work/readonly"
mkdir -p "$readonly_project/.agents/state"
chmod 500 "$readonly_project/.agents/state"
CLAUDE_PROJECT_DIR="$readonly_project" feed '{"hook_event_name":"StopFailure","error":"overloaded"}'
check "an unwritable state dir still exits 0" "0" "$rc"
check "an unwritable state dir produces no stderr" "0" "$(stderr_bytes)"
chmod 700 "$readonly_project/.agents/state"

# Silence is a property of every path, not just the happy one.
for quiet_payload in '{"hook_event_name":"StopFailure","error":"teapot"}' \
                     '{"hook_event_name":"Stop","error":"overloaded"}' \
                     'not json at all' \
                     ''; do
  feed "$quiet_payload"
  check "silent on stderr: ${quiet_payload:-<empty>}" "0" "$(stderr_bytes)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
