#!/usr/bin/env bash
# Stop hook: confirmations and final-response checks run in sequence, so they
# never race as separate Stop hooks would:
#   1. On the initial Stop, a nonempty last reply must start with a short TL;DR;
#      explicit empty replies stay empty. A reply that leads with one already gives
#      its short version, so the gate never asks for another.
#   2. A pending timed confirmation resumes the agent; expiry selects its fallback.
#   3. preflight-verdict-check.sh judges the turn. Its block, error or allow is the
#      answer.
#
# stdin is the host's Stop payload, handed unchanged to the verdict check. stdout,
# stderr and the exit status are the verdict check's, except that step 1 blocks with
# its correction. Missing dependencies fail closed.
#
# Tests: bash .agents/hooks/session/stop-gate.test.sh
set -uo pipefail

hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tooling_root="$(cd "$hooks_dir/../.." && pwd)"
verdict_check="$tooling_root/.agents/hooks/audit/preflight-verdict-check.sh"
raw_payload="$(cat)"

run_verdict_check_alone() {
  printf '%s' "$raw_payload" | bash "$verdict_check"
  exit $?
}

for required_command in jq perl; do
  command -v "$required_command" >/dev/null 2>&1 || { printf 'stop-gate: missing %s\n' "$required_command" >&2; exit 2; }
done
for library in verdict-audit-state.sh reply-summary.sh concise-writing.sh; do
  [[ -r "$tooling_root/.agents/lib/$library" ]] || { printf 'stop-gate: missing %s\n' "$library" >&2; exit 2; }
done
# shellcheck source=../lib/verdict-audit-state.sh
source "$tooling_root/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../lib/reply-summary.sh
source "$tooling_root/.agents/lib/reply-summary.sh"
# shellcheck source=../lib/concise-writing.sh
source "$tooling_root/.agents/lib/concise-writing.sh"

# ── Input: the payload fields this gate reads; anything malformed is the verdict
#    check's to report ─────────────────────────────────────────────────────────
payload="$(printf '%s' "$raw_payload" | jq -ecs '
  if length == 1 and (.[0] | type) == "object" then .[0] else empty end
' 2>/dev/null)" || run_verdict_check_alone
payload_string() { printf '%s' "$payload" | jq -r "if (.$1 | type) == \"string\" then .$1 else \"\" end"; }
last_assistant_message="$(payload_string last_assistant_message)"
reply_is_supplied="$(printf '%s' "$payload" | jq -r '(.last_assistant_message | type) == "string"')"
stop_hook_active="$(printf '%s' "$payload" | jq -r '.stop_hook_active == true')"
transcript_path="$(payload_string transcript_path)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/stop-gate.XXXXXX")" || exit 2
trap 'rm -f "$scratch/payload" "$scratch/verdict-output" "$scratch/decisions" "$scratch/final-turn.json"; rmdir "$scratch" 2>/dev/null' EXIT
# An explicit empty reply is intentional silence, not missing host data.
if [[ "$reply_is_supplied" != true && -n "$transcript_path" ]]; then
  last_assistant_message="$(reply_summary_last_text "$transcript_path" "$scratch")" || {
    printf 'stop-gate: cannot read the final reply for the TL;DR check\n' >&2; exit 2;
  }
fi
if [[ "$stop_hook_active" != true && -n "$last_assistant_message" ]] \
   && ! summary_error="$(concise_writing_check_summary "$last_assistant_message" first 39)"; then
  jq -nc --arg reason "$summary_error" '{decision:"block",reason:$reason}'
  exit 0
fi
timed_continuation="$tooling_root/scripts/continue-timed-prompts.sh"
[[ -r "$timed_continuation" ]] || { printf "stop-gate: timed continuation missing\n" >&2; exit 2; }
continuation="$(printf '%s' "$raw_payload" | bash "$timed_continuation")" || exit 2
if [[ -n "$continuation" ]]; then
  printf '%s\n' "$continuation"
  exit 0
fi

# ── The verdict check ────────────────────────────────────────────────────────
# A signal can reach this gate two ways, and the check must see both, as it did when it
# was the hook itself:
#   - to the whole process group: the check, its audit runner and the model under it
#     each get it and stop through their own traps. A background child of a shell
#     without job control would ignore SIGINT and SIGQUIT for good, so the check
#     starts with both restored.
#   - to this gate alone: this gate waits in the background-job `wait`, where its traps
#     run at once, and passes the signal on to the check.
# The traps are set before the check starts, so no signal lands in between.
verdict_pid=""
# shellcheck disable=SC2329 # invoked from the TERM and INT traps below
forward_signal() {  # signal exit-status
  if [[ -n "$verdict_pid" ]]; then
    kill "-$1" "$verdict_pid" 2>/dev/null
    wait "$verdict_pid" 2>/dev/null
  fi
  exit "$2"
}
trap 'forward_signal TERM 143' TERM
trap 'forward_signal INT 130' INT
printf '%s' "$raw_payload" > "$scratch/payload"
: > "$scratch/decisions"
VERDICT_DECISION_OUT="$scratch/decisions" \
  perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV; exit 127' \
  bash "$verdict_check" < "$scratch/payload" > "$scratch/verdict-output" &
verdict_pid=$!
wait "$verdict_pid"
verdict_status=$?
verdict_output="$(cat "$scratch/verdict-output")"
printf '%s' "$verdict_output"
exit "$verdict_status"
