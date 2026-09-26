#!/usr/bin/env bash
# Stop hook: confirmations and final-response checks run in sequence, so they
# never race as separate Stop hooks would:
#   Every nonempty human-facing reply needs TL;DR; explicit empty replies stay empty.
#   0. A pending timed confirmation resumes the agent; expiry selects its fallback.
#   1. A small reply answering the previous Stop's ask ends the turn when no tool ran
#      since the ask: it restates a turn the verdict check already judged.
#   2. preflight-verdict-check.sh judges the turn. Its block, error or allow is the
#      answer, except that
#   3. an allow that followed a judgment, on a last reply with a dense block, continues the
#      turn once with the shared prompt in .agents/prompts/concise-writing.md.
# The reply-summary rule and its record live in .agents/lib/reply-summary.sh. Both
# decisions here join the verdict check's per-session decision log.
#
# stdin is the host's Stop payload, handed unchanged to the verdict check. stdout,
# stderr and the exit status are the verdict check's, except that step 1 ends silently
# and step 3 replaces an allow with the ask. Missing dependencies fail closed.
#
# Tests: bash .agents/hooks/stop-gate.test.sh
set -uo pipefail

hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tooling_root="$(cd "$hooks_dir/../.." && pwd)"
verdict_check="$hooks_dir/preflight-verdict-check.sh"
raw_payload="$(cat)"

run_verdict_check_alone() {
  printf '%s' "$raw_payload" | bash "$verdict_check"
  exit $?
}

for required_command in jq perl git; do
  command -v "$required_command" >/dev/null 2>&1 || { printf 'stop-gate: missing %s\n' "$required_command" >&2; exit 2; }
done
for library in verdict-audit-state.sh reply-summary.sh concise-writing.sh subagent.sh hook-host.sh; do
  [[ -r "$tooling_root/.agents/lib/$library" ]] || { printf 'stop-gate: missing %s\n' "$library" >&2; exit 2; }
done
# shellcheck source=../lib/verdict-audit-state.sh
source "$tooling_root/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../lib/reply-summary.sh
source "$tooling_root/.agents/lib/reply-summary.sh"
# shellcheck source=../lib/concise-writing.sh
source "$tooling_root/.agents/lib/concise-writing.sh"
# shellcheck source=../lib/subagent.sh
source "$tooling_root/.agents/lib/subagent.sh"

# ── Input: the payload fields this gate reads; anything malformed is the verdict
#    check's to report ─────────────────────────────────────────────────────────
payload="$(printf '%s' "$raw_payload" | jq -ecs '
  if length == 1 and (.[0] | type) == "object" then .[0] else empty end
' 2>/dev/null)" || run_verdict_check_alone
payload_string() { printf '%s' "$payload" | jq -r "if (.$1 | type) == \"string\" then .$1 else \"\" end"; }
session_id="$(payload_string session_id)"
last_assistant_message="$(payload_string last_assistant_message)"
reply_is_supplied="$(printf '%s' "$payload" | jq -r '(.last_assistant_message | type) == "string"')"
transcript_path="$(payload_string transcript_path)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/stop-gate.XXXXXX")" || exit 2
trap 'rm -f "$scratch/payload" "$scratch/verdict-output" "$scratch/decisions" "$scratch/final-turn.json"; rmdir "$scratch" 2>/dev/null' EXIT
# An explicit empty reply is intentional silence, not missing host data.
if [[ "$reply_is_supplied" != true && -n "$transcript_path" ]]; then
  last_assistant_message="$(reply_summary_last_text "$transcript_path" "$scratch")" || {
    printf 'stop-gate: cannot read the final reply for the TL;DR check\n' >&2; exit 2;
  }
fi
if [[ -n "$last_assistant_message" ]] && ! summary_error="$(concise_writing_check_summary "$last_assistant_message" first 39)"; then
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

stop_hook_active="$(printf '%s' "$payload" | jq -r 'if .stop_hook_active == true then "true" else "false" end')"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)" \
   || ! repo_root="$(cd "$repo_root" && pwd -P)"; then
  run_verdict_check_alone
fi
session_scope="-"
if [[ -n "$session_id" ]]; then
  session_scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo_root" 2>/dev/null)" \
    || session_scope="-"
fi
# Without a session there is nowhere to remember an ask, so the verdict check decides.
[[ "$session_scope" != "-" ]] || run_verdict_check_alone

state_dir="$repo_root/.agents/state"
ask_file="$(verdict_audit_state_path "$state_dir/reply-summary-ask" "$session_scope")"
prompt_epoch_file="$(verdict_audit_state_path "$state_dir/verdict-prompt-epoch" "$session_scope")"
decision_log="$(verdict_audit_state_path "$state_dir/verdict-decisions.log" "$session_scope")"
message_id="cksum-$(printf '%s' "$last_assistant_message" | cksum | tr ' \t' '--')"

# The prompt epoch is an opaque token that UserPromptSubmit advances; a missing marker
# is the initial epoch. An ask binds to it, so a new prompt retires the ask.
read_prompt_epoch() {
  if [[ ! -e "$prompt_epoch_file" && ! -L "$prompt_epoch_file" ]]; then
    printf -
    return 0
  fi
  verdict_audit_read_single_record "$prompt_epoch_file" 2>/dev/null
}
entry_prompt_epoch="$(read_prompt_epoch)" || entry_prompt_epoch=""
prompt_epoch_is_current() {
  local current
  current="$(read_prompt_epoch)" || return 1
  [[ -n "$entry_prompt_epoch" && "$current" == "$entry_prompt_epoch" ]]
}

log_decision() {  # rung outcome
  mkdir -p "$(dirname "$decision_log")" 2>/dev/null || return 0
  verdict_audit_append_log_line "$decision_log" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ) $message_id $1 $2" 2>/dev/null || true
}

# A custom extractor means a transcript format the shared reader cannot parse.
final_turn_tool_count() {
  [[ -z "${VERDICT_EXTRACTOR_CMD:-}" ]] || return 1
  reply_summary_tool_count "$transcript_path" "$scratch"
}

# ── 1. The small reply the previous Stop asked for ───────────────────────────
# A block started a new transcript turn at the request, so that turn must hold no tool
# call at all; a context continuation still holds the judged turn, so its count must
# not have grown. Anything else is new work for the verdict check, never asked twice.
asked=false
asked_mode=""
asked_tools=""
if ask="$(reply_summary_take_ask "$ask_file")"; then
  read -r ask_epoch asked_mode asked_tools <<<"$ask"
  [[ "$ask_epoch" == "$entry_prompt_epoch" ]] && asked=true
fi
is_restatement() {
  local tools
  [[ "$asked" == true && "$stop_hook_active" == true ]] || return 1
  [[ -n "$last_assistant_message" ]] || return 1
  reply_summary_fits_restatement "$last_assistant_message" || return 1
  tools="$(final_turn_tool_count)" || return 1
  case "$asked_mode" in
    block)   [[ "$tools" == 0 ]] ;;
    context) [[ "$asked_tools" =~ ^[0-9]+$ && "$tools" == "$asked_tools" ]] ;;
    *)       return 1 ;;
  esac
}
if is_restatement; then
  # A summary request cannot close an unresolved audit cycle.
  # shellcheck source=../lib/audit-reflection.sh
  source "$tooling_root/.agents/lib/audit-reflection.sh"
  # shellcheck source=../lib/audit-reflection-gate.sh
  source "$tooling_root/.agents/lib/audit-reflection-gate.sh"
  reflection_epoch="$entry_prompt_epoch"
  [[ "$reflection_epoch" != "-" ]] || reflection_epoch=0
  reflection_context="$(jq -nc --arg root "$repo_root" --arg session "$session_scope" \
    --arg epoch "$reflection_epoch" --arg branch "$(git -C "$repo_root" branch --show-current)" \
    '{repo_root:$root,session:$session,epoch:$epoch,branch:(if $branch == "" then "HEAD" else $branch end),gate:"verdict"}')"
  history="$(audit_reflection_gate "$reflection_context" inspect)" || run_verdict_check_alone
  if [[ "$(jq -r .unresolved <<<"$history")" == true ]] \
     || [[ "$(jq -r .pending <<<"$history")" == true ]]; then
    run_verdict_check_alone
  fi
  log_decision summary restatement-allow
  exit 0
fi

# ── 2. The verdict check ─────────────────────────────────────────────────────
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
if (( verdict_status != 0 )); then
  printf '%s' "$verdict_output"
  exit "$verdict_status"
fi

# ── 3. Ask once for a small closing reply ────────────────────────────────────
# Only the allows that follow a judgment, or a user's override, ask; an unjudged or
# superseded allow, an audit still running, and every block pass through. Soft mode
# means the gate never continues a turn, so it asks for nothing either.
# Claude Code takes the request as additionalContext, which continues the turn without
# a hook-error notice (code.claude.com/docs/en/hooks, "Stop decision control"). Its
# transcript records it as an attachment, not a user message, and the next Stop carries
# stop_hook_active=true: observed on Claude Code 2.1.278. Any other caller gets
# decision:block, which every host honors and records as a user message.
ask_is_due() {
  local length_status=0
  [[ "$asked" != true && "${VERDICT_GATE_HARD_BLOCK:-1}" != "0" ]] || return 1
  case "$(tail -n 1 "$scratch/decisions" 2>/dev/null)" in
    "override overridden-allow"|"dossier PASS-allow"|"dossier IN_PROGRESS-allow") ;;
    "triage NO-allow"|"regex none-allow") ;;
    *) return 1 ;;
  esac
  [[ -z "$verdict_output" ]] \
    || printf '%s' "$verdict_output" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 \
    || return 1
  reply_summary_is_dense "$last_assistant_message" || length_status=$?
  (( length_status == 0 ))
}
ask_for_reply_summary() {
  local mode=block tools note request
  # Load before recording the ask: a broken template must not leave a continuation
  # record for a request that never reached the agent.
  request="$(concise_writing_prompt "$tooling_root")" || return 1
  [[ "$(hook_host_kind)" == claude ]] && mode=context
  tools="$(final_turn_tool_count)" || tools="-"
  reply_summary_record_ask "$ask_file" "$entry_prompt_epoch" "$mode" "$tools" \
    2>/dev/null || return 1
  # Checked after the record is written, so a prompt that arrived at any point before
  # now supersedes this Stop and takes the ask back with it.
  if ! prompt_epoch_is_current; then
    reply_summary_retract_ask "$ask_file" "$entry_prompt_epoch" "$mode" "$tools" || true
    return 1
  fi
  log_decision summary ask-continue
  note="$(printf '%s' "$verdict_output" | jq -r '.systemMessage // empty' 2>/dev/null)"
  if [[ "$mode" == context ]]; then
    jq -nc --arg c "$request" --arg m "$note" \
      '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$c}}
       + (if $m == "" then {} else {systemMessage:$m} end)'
  else
    jq -nc --arg r "$request" --arg m "$note" \
      '{decision:"block", reason:$r}
       + (if $m == "" then {} else {systemMessage:$m} end)'
  fi
}
if ask_is_due && ask_for_reply_summary; then
  exit 0
fi
printf '%s' "$verdict_output"
exit 0
