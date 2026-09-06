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

# The stub records each requested duration so the tests can assert the backoff schedule.
# shellcheck disable=SC2016 # $1 and $STUB_SLEEPS must reach the stub, not expand here.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$STUB_SLEEPS"\nexit 0\n' > "$stub_dir/sleep"
chmod +x "$stub_dir/claude" "$stub_dir/curl" "$stub_dir/sleep"

export STUB_PLAN="$work/plan" STUB_COUNT="$work/count" STUB_ARGV="$work/argv" STUB_NET="$work/net"
export STUB_SLEEPS="$work/sleeps"
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
  printf 0 > "$STUB_COUNT"; : > "$STUB_ARGV"; : > "$STUB_SLEEPS"
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

# ── The writer and the reader, joined ────────────────────────────────────────
# Every case above hand-writes the record, which proves the reader works against a
# fixture and nothing about the contract between the two files. These produce it by
# running the real hook, so renaming a field on either side turns them red instead of
# leaving both suites green with a record the supervisor can no longer read.
hook="$script_dir/../.agents/hooks/record-api-failure.sh"
if [[ -r "$hook" ]]; then
  ok "the StopFailure hook is readable"
else
  bad "the StopFailure hook is readable at $hook"
fi

record_via_hook() {  # $1 = kind, $2 = session id
  rm -f "$failure_record"
  printf '{"hook_event_name":"StopFailure","error":"%s","error_details":"529","session_id":"%s"}' \
    "$1" "$2" | bash "$hook" >/dev/null 2>&1
}

record_via_hook authentication_failed sess-1
run_subject api_error api_error api_error api_error
check "hook-written permanent fault stops the loop" "1 1" "$rc $calls"

# Deliberately the full-budget plan, not `api_error success`: an unreadable record also
# ends that shorter plan at exit 0 after 2 calls, so it would pass either way. Spending
# the whole budget (3 4) is reachable only when the kind really was read as retryable —
# an unreadable one stops at the unknown budget (5 3).
record_via_hook overloaded sess-1
run_subject api_error api_error api_error api_error
check "hook-written transient fault is retried" "3 4" "$rc $calls"

# The hook records the session it saw; a record from another one must not steer this run.
record_via_hook overloaded other-session
run_subject api_error api_error api_error api_error
check "hook-written record for another session is ignored" "5 3" "$rc $calls"

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

# --max-wait is a deadline, so the opening 5s backoff must be clipped when the whole
# budget is smaller than it. Measured from the stub's recorded sleep arguments; the
# default 200s budget used above is far too large to expose an overshoot.
printf down > "$STUB_NET"
printf '%s\n' api_error crash > "$STUB_PLAN"
printf 0 > "$STUB_COUNT"; : > "$STUB_ARGV"; : > "$STUB_SLEEPS"
record_failure_kind overloaded sess-1
bash "$subject" --max-restarts 3 --max-wait 3 'do the task' >/dev/null 2>&1
slept_total="$(awk '{ total += $1 } END { print total + 0 }' "$STUB_SLEEPS")"
slept_max="$(awk 'BEGIN { m = 0 } { if ($1 > m) m = $1 } END { print m + 0 }' "$STUB_SLEEPS")"
check "no single sleep exceeds --max-wait" "3" "$slept_max"
check "total wait does not exceed --max-wait" "3" "$slept_total"

# --max-wait is one budget for the whole run. With the API reachable each restart waits
# once, so a 30s budget is consumed across restarts (5 + 10 + 15-clipped) and the fourth
# finds nothing left. Under a per-restart budget each call would start from zero and the
# run would instead end on the restart budget, so this discriminates between the two.
printf up > "$STUB_NET"
record_failure_kind overloaded sess-1
printf '%s\n' api_error api_error api_error api_error api_error > "$STUB_PLAN"
printf 0 > "$STUB_COUNT"; : > "$STUB_ARGV"; : > "$STUB_SLEEPS"
bash "$subject" --max-restarts 9 --max-wait 30 'do the task' >/dev/null 2>&1
check "the wait budget spans restarts, not each one" "4" "$?"
check "total wait stops at the shared budget" "30" \
  "$(awk '{ total += $1 } END { print total + 0 }' "$STUB_SLEEPS")"
check "intervals keep growing across restarts" "5 10 15" \
  "$(tr '\n' ' ' < "$STUB_SLEEPS" | sed 's/ $//')"

# ── The defaults, exercised ──────────────────────────────────────────────────
# Every case above pins --max-wait small, so the shipped six-hour budget and the
# backoff ceiling are never reached and a wrong default cannot fail a test. This one
# runs with no overrides against a reachable API — the rate_limit shape, where each
# restart costs exactly one sleep — so the wait budget, not the restart cap, must end
# it. With max_restarts at 10 the run stopped after 1.21h regardless of the budget.
printf up > "$STUB_NET"
record_failure_kind overloaded sess-1
awk 'BEGIN { for (i = 0; i < 60; i++) print "api_error" }' > "$STUB_PLAN"
printf 0 > "$STUB_COUNT"; : > "$STUB_ARGV"; : > "$STUB_SLEEPS"
bash "$subject" 'do the task' >/dev/null 2>&1
check "the shipped defaults end on the wait budget, not the restart cap" "4" "$?"
check "the run waits the full six hours" "21600" \
  "$(awk '{ total += $1 } END { print total + 0 }' "$STUB_SLEEPS")"
# The ceiling is advertised in --help and the README, so overshooting it is a doc lie.
check "no interval exceeds the advertised ceiling" "1800" \
  "$(awk 'BEGIN { m = 0 } { if ($1 > m) m = $1 } END { print m + 0 }' "$STUB_SLEEPS")"

printf up > "$STUB_NET"
bash "$subject" --max-restarts >/dev/null 2>&1
check "option without a value exits 2 instead of spinning" "2" "$?"

bash "$subject" >/dev/null 2>&1
check "missing prompt exits 2" "2" "$?"

bash "$subject" --probe-url 'file:///etc/passwd' 'task' >/dev/null 2>&1
check "non-http probe url is rejected" "2" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
