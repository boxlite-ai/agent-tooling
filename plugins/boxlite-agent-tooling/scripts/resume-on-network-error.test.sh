#!/usr/bin/env bash
# Behavioral tests at the public script boundary. `claude`, `curl` and `sleep` are
# PATH stubs, so the retry policy is exercised without a network or real waiting.
# Run with: bash plugins/boxlite-agent-tooling/scripts/resume-on-network-error.test.sh
#
# Every result the stub emits uses the host's real shapes: terminal_reason is a closed
# enum whose API member is the bare string `api_error`, and the error KIND never
# appears in result JSON — it reaches the supervisor only through the StopFailure
# hook's record. A fixture that invents `api_error_<kind>` would pass while guarding
# nothing, so the shapes here are worth checking against the host before editing them.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
subject="$script_dir/resume-on-network-error.sh"
[[ -r "$subject" ]] || { printf 'missing %s\n' "$subject" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/resume-test.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"
mkdir -p "$stub_dir" "$work/project/.agents/state"

# ── Stubs ────────────────────────────────────────────────────────────────────
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV"
index="$(cat "$STUB_COUNT" 2>/dev/null || echo 0)"
printf '%s' "$(( index + 1 ))" > "$STUB_COUNT"
outcome="$(sed -n "$(( index + 1 ))p" "$STUB_PLAN")"
[[ -n "$outcome" ]] || outcome=crash
case "$outcome" in
  success)   printf '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-1","terminal_reason":"completed","result":"finished"}\n' ;;
  api_error) printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-1","terminal_reason":"api_error","errors":[]}\n'; exit 1 ;;
  hook)      printf '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-1","terminal_reason":"stop_hook_prevented","errors":[]}\n'; exit 1 ;;
  max_turns) printf '{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"sess-1","terminal_reason":"max_turns","errors":[]}\n'; exit 1 ;;
  crash)     exit 1 ;;
esac
STUB

cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
[[ "$(cat "$STUB_NET" 2>/dev/null || echo up)" == up ]]
STUB

printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_dir/sleep"
chmod +x "$stub_dir/claude" "$stub_dir/curl" "$stub_dir/sleep"

export STUB_PLAN="$work/plan" STUB_COUNT="$work/count" STUB_ARGV="$work/argv" STUB_NET="$work/net"
export CLAUDE_PROJECT_DIR="$work/project"
export PATH="$stub_dir:$PATH"
failure_record="$CLAUDE_PROJECT_DIR/.agents/state/last-api-failure.json"

pass=0
fail=0
# Increment pass counter and print a PASS line.  # $1 = test name
ok()  { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$1"; }
# Increment fail counter and print a FAIL line.  # $1 = test name
bad() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$1"; }
# Compare expected and actual values, calling ok or bad and printing details on mismatch.  # $1 = name, $2 = expected, $3 = actual
check() {  # name expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else
    bad "$1"; printf '        expected %s\n        actual   %s\n' "$2" "$3"
  fi
}

# Write the record the StopFailure hook would have left. Absent kind = no record.
# Create a fake API failure record or remove it if kind is empty.  # $1 = kind (empty removes it), $2 = session id (default sess-1), $3 = recorded_at (default now); writes to failure_record
record_failure_kind() {  # $1 = kind (empty removes it), $2 = session id, $3 = recorded_at
  if [[ -z "$1" ]]; then rm -f "$failure_record"; return; fi
  printf '{"error":"%s","error_details":"","session_id":"%s","recorded_at":%s}\n' \
    "$1" "${2:-sess-1}" "${3:-$(date -u +%s)}" > "$failure_record"
}

# Invocations are counted from the stub's own counter, not by lines in the argv log:
# a caller-supplied prompt may span lines, so one call can contribute several.
# Run the subject script with a stubbed plan of outcomes.  # $@ = plan-lines (success, api_error, hook, max_turns, crash); sets rc, calls; writes stdout to $work/stdout, stderr to $work/stderr
run_subject() {  # plan-lines... ; sets rc, calls, stdout_file
  printf '%s\n' "$@" > "$STUB_PLAN"
  printf 0 > "$STUB_COUNT"; : > "$STUB_ARGV"
  bash "$subject" --max-restarts 3 --max-wait 200 'do the task' \
    >"$work/stdout" 2>"$work/stderr"
  rc=$?
  calls="$(cat "$STUB_COUNT" 2>/dev/null || echo 0)"
}

# ── Cases ────────────────────────────────────────────────────────────────────
printf 'resume-on-network-error\n'

printf up > "$STUB_NET"
record_failure_kind ""
run_subject success
check "clean success exits 0 after one run" "0 1" "$rc $calls"
if jq -e '.subtype == "success"' "$work/stdout" >/dev/null 2>&1; then
  ok "the final result JSON reaches stdout"
else
  bad "the final result JSON reaches stdout"
fi

# --output-format json is appended after pass-through args, so a caller who supplies
# their own cannot silently defeat classification.
if grep -q -- '--output-format json$' "$STUB_ARGV"; then
  ok "--output-format json is the last argument"
else
  bad "--output-format json is the last argument"
fi

record_failure_kind overloaded
run_subject api_error success
check "retryable kind (overloaded) restarts once, then succeeds" "0 2" "$rc $calls"
if grep -q -- '--resume sess-1' "$STUB_ARGV"; then
  ok "restart resumes the learned session id"
else
  bad "restart resumes the learned session id"
fi
if grep -qE -- '(^| )(-c|--continue)( |$)' "$STUB_ARGV"; then
  bad "restart never uses --continue"
else
  ok "restart never uses --continue"
fi

record_failure_kind rate_limit
run_subject api_error success
check "retryable kind (rate_limit) restarts" "0 2" "$rc $calls"

# The defect this suite exists to catch: a permanent fault must not spend the budget.
record_failure_kind authentication_failed
run_subject api_error api_error api_error api_error
check "authentication_failed is fatal, no restart" "1 1" "$rc $calls"

record_failure_kind billing_error
run_subject api_error api_error
check "billing_error is fatal, no restart" "1 1" "$rc $calls"

# No StopFailure record: the kind is unknowable, so guess briefly and stop.
record_failure_kind ""
run_subject api_error api_error api_error api_error
check "unrecorded kind stops after the small guess budget" "5 3" "$rc $calls"

# A record older than the freshness bound belongs to an earlier run of this session.
record_failure_kind overloaded sess-1 1
run_subject api_error api_error api_error api_error
check "stale record is ignored, not trusted" "5 3" "$rc $calls"

# The record lives at one project-wide path, so another run in the same project writes
# to it too. A fresh foreign record must not steer this run in EITHER direction: a
# foreign retryable kind would spend the whole budget, a foreign fatal kind would kill
# a run that never had that fault.
record_failure_kind overloaded other-session
run_subject api_error api_error api_error api_error
check "a fresh foreign record does not grant retries" "5 3" "$rc $calls"

record_failure_kind authentication_failed other-session
run_subject api_error api_error api_error api_error
check "a fresh foreign record does not kill the run" "5 3" "$rc $calls"

# Same session, comfortably inside the freshness window: this one IS this run's fault.
record_failure_kind authentication_failed sess-1
run_subject api_error api_error api_error api_error
check "a matching in-window record is honoured" "1 1" "$rc $calls"

# Membership must be exact. A run of real enum members is a substring of any
# space-joined list of them, so a glob test would read this as a known kind and act on
# it; it is a member of nothing and must fall through to the unknown budget.
record_failure_kind "authentication_failed billing_error"
run_subject api_error api_error api_error api_error
check "multi-member run is not a known kind" "5 3" "$rc $calls"

record_failure_kind "rate_limit overloaded"
run_subject api_error api_error api_error api_error
check "multi-member run does not read as retryable" "5 3" "$rc $calls"

record_failure_kind ""
run_subject hook
check "stop_hook_prevented is fatal, no restart" "1 1" "$rc $calls"

run_subject max_turns
check "max_turns is fatal, no restart" "1 1" "$rc $calls"

record_failure_kind overloaded
run_subject api_error api_error api_error api_error api_error
check "restart budget is enforced" "3 4" "$rc $calls"

# A crash with the API reachable is not a network problem; looping cannot fix it.
printf up > "$STUB_NET"
run_subject crash
check "crash while API is reachable is fatal" "1 1" "$rc $calls"

# The same crash with the API unreachable is exactly the case this script exists for.
printf down > "$STUB_NET"
run_subject crash crash
check "crash while API is unreachable stops on the wait deadline" "4 1" "$rc $calls"

printf up > "$STUB_NET"
bash "$subject" --max-restarts >/dev/null 2>&1
check "option without a value exits 2 instead of spinning" "2" "$?"

bash "$subject" >/dev/null 2>&1
check "missing prompt exits 2" "2" "$?"

bash "$subject" --probe-url 'file:///etc/passwd' 'task' >/dev/null 2>&1
check "non-http probe url is rejected" "2" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
