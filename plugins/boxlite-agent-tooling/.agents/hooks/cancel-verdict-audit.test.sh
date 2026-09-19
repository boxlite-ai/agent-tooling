#!/usr/bin/env bash
# Tests for the UserPromptSubmit cancellation edge around run-verdict-audit.sh.
#
# Contract:
#   - a prompt in the audit's session cancels the runner and its whole process tree
#   - a prompt from another session cannot cancel a session-scoped lock owner
#   - malformed/stale/forged lock state never becomes an arbitrary-pid signal primitive
#   - a dossier written during cancellation is removed as output from an abandoned turn
#
# Run with: bash .agents/hooks/cancel-verdict-audit.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/.agents/hooks/run-verdict-audit.sh"
HOOK="$REPO_ROOT/.agents/hooks/cancel-verdict-audit.sh"
CONTROL="$REPO_ROOT/.agents/hooks/auditor-control.sh"
RESUME="$REPO_ROOT/.agents/hooks/resume-after-api-failure.sh"
PREFLIGHT="$REPO_ROOT/.agents/hooks/preflight-verdict-check.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {  # desc got want
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got=$2 want=$3)"; fi
}

kill_test_pids() {  # signal pid...
  local signal="$1" pid; shift
  for pid in "$@"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill "-$signal" "$pid" 2>/dev/null || true
  done
}

dependency_bin="$(mktemp -d)"
ln -s "$(command -v bash)" "$dependency_bin/bash"
ln -s "$(command -v perl)" "$dependency_bin/perl"
missing_jq_err="$(PATH="$dependency_bin" bash "$HOOK" \
  <<<'{"hook_event_name":"UserPromptSubmit","session_id":"session-a"}' 2>&1)"
missing_jq_rc=$?
check_eq "missing jq fails closed with an actionable cancellation-hook error" \
  "rc=$missing_jq_rc named=$([[ "$missing_jq_err" == *"required dependency not found: jq"* ]] && echo yes || echo no)" \
  "rc=2 named=yes"
rm -rf "$dependency_bin"

setup() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  printf 'x\n' > "$d/f"
  printf '.agents/state/\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  mkdir -p "$d/.agents/state"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"tests pass"}]}}\n' \
    > "$d/transcript.jsonl"
  printf '%s' "$d"
}

prompt_hook() {  # repo session turn
  local repo="$1" session="$2" turn="$3"
  jq -nc --arg s "$session" --arg t "$turn" --arg p "ok" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,turn_id:$t,prompt:$p}' \
    | ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" )
}

session_scope_of() {  # repo session
  printf 'git-%s' "$(printf '%s' "$2" | git -C "$1" hash-object --stdin)"
}
session_state_path() {  # repo basename session
  printf '%s/.agents/state/%s.%s' "$1" "$2" "$(session_scope_of "$1" "$3")"
}

# The prompt Claude Code submits when an asyncRewake hook exits 2, captured from a live
# 2.1.278 session: the envelope carries only the host's own summary, and the hook's stderr
# follows it inside a system-reminder, so that is where a hook's marker lands.
rewake_prompt() {  # hook-name hook-stderr
  printf '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error from command "%s": %s\n\n</system-reminder>' \
    "$1" "$2"
}

process_state() {
  local pid="$1" state
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid'; return; }
  state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$state" || "$state" == Z* ]] && printf 'gone' || printf 'alive'
}

tree_hash_of() {
  local repo="$1" idx; idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree 2>/dev/null
  rm -f "$idx"
}

echo "## Fresh and unsafe state fail closed without losing prompt scope"
R="$(setup)"
rm -rf "$R/.agents/state"
absent_out="$(prompt_hook "$R" session-a turn-a 2>"$R/absent.err")"; absent_rc=$?
fresh_epoch="$(session_state_path "$R" verdict-prompt-epoch session-a)"
absent_state="rc=$absent_rc stdout=${absent_out:-} stderr=$(cat "$R/absent.err") dir=$([[ -d "$R/.agents/state" ]] && echo present || echo absent) epoch=$([[ -s "$fresh_epoch" ]] && echo present || echo absent)"
check_eq "the first prompt creates runtime state and a prompt epoch" "$absent_state" \
  "rc=0 stdout= stderr= dir=present epoch=present"

echo "## Claude auditor wake notifications are generation-bound"
wake_start="$(jq -nc --arg s session-a --arg id wake-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
wake_rc=0
printf '%s' "$wake_start" | (
  cd "$R" && env -u PLUGIN_ROOT CLAUDE_PROJECT_DIR="$R" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$CONTROL"
) > "$R/wake.out" 2> "$R/wake.err" || wake_rc=$?
wake_marker="$(sed -n 's/.*\(\[auditor-wake:[0-9a-f][0-9a-f]*\]\).*/\1/p' "$R/wake.err" | head -1)"
wake_request="$(session_state_path "$R" verdict-request session-a)"
printf 'keep\n' > "$wake_request"
wake_epoch_before="$(cat "$fresh_epoch")"
wake_prompt="$(rewake_prompt SubagentStart:verdict-auditor "$(cat "$R/wake.err")")"
wake_payload="$(jq -nc --arg s session-a --arg p "$wake_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
wake_out="$(printf '%s' "$wake_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/wake-cancel.err")"
wake_cancel_rc=$?
check_eq "a valid one-time wake marker preserves the active audit before transcript publication" \
  "start_rc=$wake_rc marker=$([[ "$wake_marker" =~ ^\[auditor-wake:[0-9a-f]{64}\]$ ]] && echo valid || echo invalid) cancel_rc=$wake_cancel_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$wake_epoch_before" ]] && echo same || echo changed) stdout=${wake_out:-} stderr=$(cat "$R/wake-cancel.err")" \
  "start_rc=2 marker=valid cancel_rc=0 request=present epoch=same stdout= stderr="

wake_stop="$(jq -nc --arg s session-a --arg id wake-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$wake_stop" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
completion_epoch_before="$(cat "$fresh_epoch")"
completion_prompt=$'<task-notification>\n<task-id>wake-audit</task-id>\n<status>completed</status>\n</task-notification>'
completion_payload="$(jq -nc --arg s session-a --arg p "$completion_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
completion_out="$(printf '%s' "$completion_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/completion.err")"
completion_rc=$?
check_eq "the matching one-time auditor completion notification preserves the prompt epoch" \
  "rc=$completion_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$completion_epoch_before" ]] && echo same || echo changed) stdout=${completion_out:-} stderr=$(cat "$R/completion.err")" \
  "rc=0 request=present epoch=same stdout= stderr="

reused_epoch_before="$(cat "$fresh_epoch")"
reused_out="$(printf '%s' "$wake_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/reused-wake.err")"
reused_rc=$?
check_eq "a marker cannot be reused after its auditor reaches a terminal result" \
  "rc=$reused_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$reused_epoch_before" ]] && echo same || echo changed) stdout=${reused_out:-} stderr=$(cat "$R/reused-wake.err")" \
  "rc=0 request=gone epoch=changed stdout= stderr="

printf 'keep\n' > "$wake_request"
forged_epoch_before="$(cat "$fresh_epoch")"
forged_wake_payload="$(printf '%s' "$wake_payload" | jq -c \
  '.prompt |= sub("auditor-wake:[0-9a-f]+"; "auditor-wake:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")')"
forged_wake_out="$(printf '%s' "$forged_wake_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/forged-wake.err")"
forged_wake_rc=$?
check_eq "a forged wake marker is still a new prompt" \
  "rc=$forged_wake_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$forged_epoch_before" ]] && echo same || echo changed) stdout=${forged_wake_out:-} stderr=$(cat "$R/forged-wake.err")" \
  "rc=0 request=gone epoch=changed stdout= stderr="

late_wake_start="$(jq -nc --arg s session-a --arg id late-wake-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
late_wake_rc=0
printf '%s' "$late_wake_start" | (
  cd "$R" && env -u PLUGIN_ROOT CLAUDE_PROJECT_DIR="$R" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$CONTROL"
) > "$R/late-wake.out" 2> "$R/late-wake.err" || late_wake_rc=$?
late_wake_marker="$(sed -n 's/.*\(\[auditor-wake:[0-9a-f][0-9a-f]*\]\).*/\1/p' \
  "$R/late-wake.err" | head -1)"
late_wake_stop="$(jq -nc --arg s session-a --arg id late-wake-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$late_wake_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
prompt_hook "$R" session-a intervening-human-prompt >/dev/null
late_wake_epoch_before="$(cat "$fresh_epoch")"
printf 'new-audit\n' > "$wake_request"
late_wake_prompt="$(rewake_prompt SubagentStart:verdict-auditor "$(cat "$R/late-wake.err")")"
late_wake_payload="$(jq -nc --arg s session-a --arg p "$late_wake_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
late_wake_out="$(printf '%s' "$late_wake_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/late-wake-cancel.err")"
late_wake_cancel_rc=$?
check_eq "a queued wake remains internal after terminal state and a newer human prompt" \
  "start_rc=$late_wake_rc marker=$([[ "$late_wake_marker" =~ ^\[auditor-wake:[0-9a-f]{64}\]$ ]] && echo valid || echo invalid) cancel_rc=$late_wake_cancel_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$late_wake_epoch_before" ]] && echo same || echo changed) stdout=${late_wake_out:-} stderr=$(cat "$R/late-wake-cancel.err")" \
  "start_rc=2 marker=valid cancel_rc=0 request=present epoch=same stdout= stderr="

late_completion_start="$(jq -nc --arg s session-a --arg id late-completion-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
printf '%s' "$late_completion_start" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=0 \
      bash "$CONTROL") >/dev/null
late_completion_stop="$(jq -nc --arg s session-a --arg id late-completion-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$late_completion_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
prompt_hook "$R" session-a another-human-prompt >/dev/null
late_completion_epoch_before="$(cat "$fresh_epoch")"
printf 'newer-audit\n' > "$wake_request"
late_completion_prompt=$'<task-notification>\n<task-id>late-completion-audit</task-id>\n<status>completed</status>\n</task-notification>'
late_completion_payload="$(jq -nc --arg s session-a --arg p "$late_completion_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
late_completion_out="$(printf '%s' "$late_completion_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") \
      2>"$R/late-completion-cancel.err")"
late_completion_rc=$?
check_eq "a queued completion remains internal after a newer human prompt" \
  "rc=$late_completion_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$late_completion_epoch_before" ]] && echo same || echo changed) stdout=${late_completion_out:-} stderr=$(cat "$R/late-completion-cancel.err")" \
  "rc=0 request=present epoch=same stdout= stderr="

pre_escalation_start="$(jq -nc --arg s session-a --arg id pre-escalation-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
printf '%s' "$pre_escalation_start" | (
  cd "$R" && env -u PLUGIN_ROOT CLAUDE_PROJECT_DIR="$R" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" AUDITOR_PROMPT_AFTER_SECONDS=2 bash "$CONTROL"
) > "$R/pre-escalation.out" 2> "$R/pre-escalation.err" &
pre_escalation_start_pid=$!
pre_escalation_active="$R/.agents/state/auditor-control/active.$(session_scope_of "$R" session-a).verdict-auditor.json"
for _ in $(seq 1 100); do
  [[ -s "$pre_escalation_active" ]] && break
  sleep 0.01
done
prompt_hook "$R" session-a prompt-before-escalation >/dev/null
pre_escalation_epoch_before="$(cat "$fresh_epoch")"
printf 'newest-audit\n' > "$wake_request"
pre_escalation_stop="$(jq -nc --arg s session-a --arg id pre-escalation-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$pre_escalation_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
pre_escalation_prompt=$'<task-notification>\n<task-id>pre-escalation-audit</task-id>\n<status>completed</status>\n</task-notification>'
pre_escalation_payload="$(jq -nc --arg s session-a --arg p "$pre_escalation_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
pre_escalation_out="$(printf '%s' "$pre_escalation_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") \
      2>"$R/pre-escalation-completion.err")"
pre_escalation_rc=$?
wait "$pre_escalation_start_pid" 2>/dev/null || true
check_eq "a pre-escalation audit completing after a newer prompt stays internal" \
  "rc=$pre_escalation_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$pre_escalation_epoch_before" ]] && echo same || echo changed) stdout=${pre_escalation_out:-} stderr=$(cat "$R/pre-escalation-completion.err")" \
  "rc=0 request=present epoch=same stdout= stderr="

repeated_start="$(jq -nc --arg s session-a --arg id repeated-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
repeated_stop="$(jq -nc --arg s session-a --arg id repeated-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
for _ in 1 2; do
  printf '%s' "$repeated_start" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=0 \
        bash "$CONTROL") >/dev/null
  printf '%s' "$repeated_stop" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
done
repeated_prompt=$'<task-notification>\n<task-id>repeated-audit</task-id>\n<status>completed</status>\n</task-notification>'
repeated_payload="$(jq -nc --arg s session-a --arg p "$repeated_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
repeated_epoch_before="$(cat "$fresh_epoch")"
printf 'repeated-new-audit\n' > "$wake_request"
for _ in 1 2; do
  printf '%s' "$repeated_payload" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") >/dev/null
done
check_eq "each repeated stop retains one completion-notification credit" \
  "request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$repeated_epoch_before" ]] && echo same || echo changed)" \
  "request=present epoch=same"

control_scope="$(session_scope_of "$R" session-a)"
overlap_old_start="$(jq -nc --arg s session-a --arg id overlap-old \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
overlap_new_start="$(jq -nc --arg s session-a --arg id overlap-new \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
printf '%s' "$overlap_old_start" | (
  cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=2 bash "$CONTROL"
) >/dev/null & overlap_old_pid=$!
overlap_active="$R/.agents/state/auditor-control/active.$control_scope.verdict-auditor.json"
for _ in $(seq 1 100); do
  [[ "$(jq -r '.generation // ""' "$overlap_active" 2>/dev/null)" == overlap-old ]] && break
  sleep 0.01
done
printf '%s' "$overlap_new_start" | (
  cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=2 bash "$CONTROL"
) >/dev/null & overlap_new_pid=$!
for _ in $(seq 1 100); do
  [[ "$(jq -r '.generation // ""' "$overlap_active" 2>/dev/null)" == overlap-new ]] && break
  sleep 0.01
done
overlap_old_stop="$(jq -nc --arg s session-a --arg id overlap-old \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$overlap_old_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
printf 'overlap-new-request\n' > "$wake_request"
overlap_epoch_before="$(cat "$fresh_epoch")"
overlap_prompt=$'<task-notification>\n<task-id>overlap-old</task-id>\n<status>completed</status>\n</task-notification>'
overlap_payload="$(jq -nc --arg s session-a --arg p "$overlap_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
printf '%s' "$overlap_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") >/dev/null
check_eq "a replaced pre-escalation generation retains its completion credit" \
  "request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$overlap_epoch_before" ]] && echo same || echo changed)" \
  "request=present epoch=same"
overlap_new_stop="$(jq -nc --arg s session-a --arg id overlap-new \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$overlap_new_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
wait "$overlap_old_pid" "$overlap_new_pid" 2>/dev/null || true

printf 'forged-completion-request\n' > "$wake_request"
forged_completion_epoch_before="$(cat "$fresh_epoch")"
forged_completion_generation=forged-completion
forged_completion_file="$R/.agents/state/auditor-control/completion.$control_scope.not-an-auditor.$forged_completion_generation.json"
jq -nc --arg scope "$control_scope" --arg generation "$forged_completion_generation" \
  --argjson now "$(date +%s)" \
  '{auditor:"not-an-auditor",generation:$generation,session_scope:$scope,
    created_at:$now,remaining:1}' > "$forged_completion_file"
forged_completion_prompt="$(printf '<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n</task-notification>' \
  "$forged_completion_generation")"
forged_completion_payload="$(jq -nc --arg s session-a --arg p "$forged_completion_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
printf '%s' "$forged_completion_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") >/dev/null
check_eq "an unknown-auditor completion cache cannot suppress a real prompt" \
  "request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$forged_completion_epoch_before" ]] && echo same || echo changed)" \
  "request=gone epoch=changed"

tailed_start="$(jq -nc --arg s session-a --arg id tailed-audit \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
tailed_stop="$(jq -nc --arg s session-a --arg id tailed-audit \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
printf '%s' "$tailed_start" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=0 \
      bash "$CONTROL") >/dev/null
printf '%s' "$tailed_stop" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") >/dev/null
printf 'tailed-audit-request\n' > "$wake_request"
tailed_epoch_before="$(cat "$fresh_epoch")"
tailed_prompt=$'<task-notification>\n<task-id>tailed-audit</task-id>\n<status>completed</status>\n</task-notification>\nreal user request'
tailed_payload="$(jq -nc --arg s session-a --arg p "$tailed_prompt" \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
tailed_out="$(printf '%s' "$tailed_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK") 2>"$R/tailed.err")"
tailed_rc=$?
check_eq "text after a task-notification envelope remains a real user prompt" \
  "rc=$tailed_rc request=$([[ -e "$wake_request" ]] && echo present || echo gone) epoch=$([[ "$(cat "$fresh_epoch")" == "$tailed_epoch_before" ]] && echo same || echo changed) stdout=${tailed_out:-} stderr=$(cat "$R/tailed.err")" \
  "rc=0 request=gone epoch=changed stdout= stderr="

control_scope="$(session_scope_of "$R" session-a)"
malformed_active="$R/.agents/state/auditor-control/active.$control_scope.verdict-auditor.json"
printf '{not-json\n' > "$malformed_active"
malformed_epoch_before="$(cat "$fresh_epoch")"
malformed_out="$(prompt_hook "$R" session-a malformed-control-state 2>"$R/malformed-control.err")"
malformed_rc=$?
rm -f "$malformed_active"
check_eq "malformed non-authorizing auditor cache cannot block a real user prompt" \
  "rc=$malformed_rc epoch=$([[ "$(cat "$fresh_epoch")" == "$malformed_epoch_before" ]] && echo same || echo changed) stdout=${malformed_out:-} stderr=$(cat "$R/malformed-control.err")" \
  "rc=0 epoch=changed stdout= stderr="

unsafe_escalation="$R/.agents/state/auditor-control/escalation.$control_scope.verdict-auditor.unsafe.json"
mkfifo "$R/unsafe-escalation-fifo"
ln -s "$R/unsafe-escalation-fifo" "$unsafe_escalation"
unsafe_escalation_payload="$(jq -nc --arg s session-a \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:"ok"}')"
unsafe_escalation_started="$(date +%s)"
printf '%s' "$unsafe_escalation_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  perl -e 'alarm 5; exec @ARGV' bash "$HOOK") >/dev/null 2>"$R/unsafe-escalation.err"
unsafe_escalation_rc=$?
unsafe_escalation_elapsed="$(( $(date +%s) - unsafe_escalation_started ))"
unsafe_escalation_state="rc=$unsafe_escalation_rc bounded=no stderr=$(cat "$R/unsafe-escalation.err")"
(( unsafe_escalation_elapsed <= 2 )) \
  && unsafe_escalation_state="rc=$unsafe_escalation_rc bounded=yes stderr=$(cat "$R/unsafe-escalation.err")"
check_eq "unsafe non-authorizing escalation cache cannot stall a real user prompt" \
  "$unsafe_escalation_state" "rc=0 bounded=yes stderr="
rm -f "$unsafe_escalation" "$R/unsafe-escalation-fifo"

mkdir -p "$R/.agents/state"
out="$(prompt_hook "$R" session-a turn-a 2>"$R/hook.err")"; rc=$?
check_eq "no lock -> exit 0" "$rc" 0
check_eq "no lock -> silent" "stdout=${out:-} stderr=$(cat "$R/hook.err")" "stdout= stderr="

# A hook event is one JSON object. Present-but-invalid session identity and concatenated
# documents fail closed instead of being reinterpreted as an unscoped no-op.
numeric_payload='{"hook_event_name":"UserPromptSubmit","session_id":7,"prompt":"ok"}'
printf '%s' "$numeric_payload" \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) >/dev/null 2>&1
check_eq "numeric session id fails closed" "$?" 1
multi_payload='{"hook_event_name":"UserPromptSubmit","session_id":"session-a"}{"hook_event_name":"UserPromptSubmit","session_id":"session-a"}'
printf '%s' "$multi_payload" \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) >/dev/null 2>&1
check_eq "multiple hook payload documents fail closed" "$?" 1

# An event without a usable session has no owner to cancel. Treating it as the legacy
# scope would let malformed/unrelated hook input erase a manual audit's state.
    for legacy_name in verdict-request last-verdict.json last-verdict.prev.json verdict-last-uuid; do
  printf 'keep\n' > "$R/.agents/state/$legacy_name"
done
missing_out="$(jq -nc '{hook_event_name:"UserPromptSubmit",prompt:"ok"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) 2>"$R/missing.err")"; missing_rc=$?
legacy_state="rc=$missing_rc files=$(for legacy_name in verdict-request last-verdict.json last-verdict.prev.json verdict-last-uuid; do [[ -e "$R/.agents/state/$legacy_name" ]] && printf present, || printf gone,; done)"
legacy_state="$legacy_state stdout=${missing_out:-} stderr=$(cat "$R/missing.err")"
check_eq "missing session id cannot mutate legacy audit state" "$legacy_state" \
  "rc=0 files=present,present,present,present, stdout= stderr="
rm -f "$R/.agents/state/verdict-request" "$R/.agents/state/last-verdict.json" \
  "$R/.agents/state/last-verdict.prev.json" "$R/.agents/state/verdict-last-uuid"

# jq's @tsv renderer escapes control characters. Hashing that transport text would map a
# real tab to the same scope as the two literal characters "\t", letting one session
# revoke another while failing to revoke itself. The hook must hash the raw JSON string.
raw_session=$'session\tid'
escaped_session='session\tid'
raw_request="$(session_state_path "$R" verdict-request "$raw_session")"
escaped_request="$(session_state_path "$R" verdict-request "$escaped_session")"
printf 'raw\n' > "$raw_request"
printf 'escaped\n' > "$escaped_request"
prompt_hook "$R" "$raw_session" turn-a >/dev/null 2>&1
escaped_scope_state="raw=$([[ -e "$raw_request" ]] && echo present || echo gone)"
escaped_scope_state="$escaped_scope_state escaped=$([[ -e "$escaped_request" ]] && echo present || echo gone)"
check_eq "control characters do not alias another session's cancellation scope" \
  "$escaped_scope_state" "raw=gone escaped=present"
rm -f "$raw_request" "$escaped_request"

trailing_newline_session=$'session\n'
plain_session='session'
newline_request="$(session_state_path "$R" verdict-request "$trailing_newline_session")"
plain_request="$(session_state_path "$R" verdict-request "$plain_session")"
printf 'newline\n' > "$newline_request"
printf 'plain\n' > "$plain_request"
prompt_hook "$R" "$trailing_newline_session" turn-a >/dev/null 2>&1
newline_scope_state="newline=$([[ -e "$newline_request" ]] && echo present || echo gone)"
newline_scope_state="$newline_scope_state plain=$([[ -e "$plain_request" ]] && echo present || echo gone)"
check_eq "a trailing newline remains part of the cancellation scope" \
  "$newline_scope_state" "newline=gone plain=present"
rm -f "$newline_request" "$plain_request"

newline_only_session=$'\n'
newline_only_request="$(session_state_path "$R" verdict-request "$newline_only_session")"
legacy_request="$R/.agents/state/verdict-request"
printf 'newline-only\n' > "$newline_only_request"
printf 'legacy\n' > "$legacy_request"
prompt_hook "$R" "$newline_only_session" turn-a >/dev/null 2>&1
newline_only_state="newline=$([[ -e "$newline_only_request" ]] && echo present || echo gone)"
newline_only_state="$newline_only_state legacy=$([[ -e "$legacy_request" ]] && echo present || echo gone)"
check_eq "a newline-only session cannot collapse into the legacy scope" \
  "$newline_only_state" "newline=gone legacy=present"
rm -f "$newline_only_request" "$legacy_request"

# Cancellation-marker cleanup must enumerate a literal directory. A shell glob built from
# a repository path containing `[]` can match a sibling repository instead of its owner.
literal_base="$R"
literal_repo="${literal_base}[1]"
foreign_repo="${literal_base}1"
mv "$R" "$literal_repo"
R="$literal_repo"
mkdir -p "$foreign_repo/.agents/state"
literal_cancel_prefix="$(session_state_path "$R" verdict-canceled session-a)"
foreign_scope="$(session_scope_of "$R" session-a)"
foreign_cancel_prefix="$foreign_repo/.agents/state/verdict-canceled.$foreign_scope"
printf 'owned\n' > "${literal_cancel_prefix}.501-502-3"
printf 'foreign\n' > "${foreign_cancel_prefix}.501-502-3"
prompt_hook "$R" session-a turn-literal >/dev/null 2>&1; literal_rc=$?
literal_marker_state="rc=$literal_rc own=$([[ -e "${literal_cancel_prefix}.501-502-3" ]] && echo present || echo gone)"
literal_marker_state="$literal_marker_state foreign=$([[ -e "${foreign_cancel_prefix}.501-502-3" ]] && echo present || echo gone)"
check_eq "cancellation marker cleanup treats bracketed repo paths literally" \
  "$literal_marker_state" "rc=0 own=gone foreign=present"
rm -rf "$foreign_repo"

# Revocation must not strand a real user prompt behind a broken/non-monitoring runner.
# The publication lease normally releases within the runner's two-second cancellation
# teardown; bound the exceptional wait and rely on the missing request to reject any
# later output instead of hanging the conversation indefinitely.
bounded_request="$(session_state_path "$R" verdict-request session-a)"
bounded_dossier="$(session_state_path "$R" last-verdict.json session-a)"
bounded_publish_mutex="${bounded_request}.publish.mutex"
printf '501-502-3 %s cksum-1-1\n' "$(( $(date +%s) + 600 ))" > "$bounded_request"
printf '{"generation":"501-502-3","verdict":"PASS"}\n' > "$bounded_dossier"
perl -MFcntl=:flock -e '
  my ($path, $ready) = @ARGV;
  open(my $fh, ">>", $path) or die $!;
  flock($fh, LOCK_EX) or die $!;
  open(my $mark, ">", $ready) or die $!;
  close($mark);
  sleep 30;
' "$bounded_publish_mutex" "$R/bounded-publish-ready" & bounded_holder_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -e "$R/bounded-publish-ready" ]] && break; sleep 0.01; done
( sleep 6; kill -TERM "$bounded_holder_pid" 2>/dev/null || true ) & bounded_watchdog=$!
bounded_started="$(date +%s)"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1; bounded_rc=$?
bounded_elapsed="$(( $(date +%s) - bounded_started ))"
kill "$bounded_watchdog" 2>/dev/null || true; wait "$bounded_watchdog" 2>/dev/null || true
bounded_holder_state="$(process_state "$bounded_holder_pid")"
bounded_state="rc=$bounded_rc elapsed_ok=no holder=$bounded_holder_state request=$([[ -e "$bounded_request" ]] && echo present || echo gone) dossier=$([[ -e "$bounded_dossier" ]] && echo present || echo gone)"
(( bounded_elapsed <= 4 )) && bounded_state="${bounded_state/elapsed_ok=no/elapsed_ok=yes}"
check_eq "a wedged publication lease cannot indefinitely block new user input" \
  "$bounded_state" "rc=0 elapsed_ok=yes holder=alive request=gone dossier=gone"
kill -TERM "$bounded_holder_pid" 2>/dev/null || true; wait "$bounded_holder_pid" 2>/dev/null || true

# A Stop gate can hold the short decision mutex while computing/validating a selected
# dossier. User input still returns successfully after the bounded wait because visible
# authority was revoked before contention began.
decision_wait_request="$(session_state_path "$R" verdict-request session-a)"
decision_wait_dossier="$(session_state_path "$R" last-verdict.json session-a)"
decision_wait_mutex="${decision_wait_request}.decision.mutex"
printf '506-507-4 %s cksum-1-1\n' "$(( $(date +%s) + 600 ))" > "$decision_wait_request"
printf '{"generation":"506-507-4","verdict":"PASS"}\n' > "$decision_wait_dossier"
perl -MFcntl=:flock -e '
  my ($path, $ready) = @ARGV;
  open(my $fh, ">>", $path) or exit 2;
  flock($fh, LOCK_EX) or exit 2;
  open(my $mark, ">", $ready) or exit 2;
  close($mark);
  sleep 30;
' "$decision_wait_mutex" "$R/decision-wait-ready" & decision_wait_holder=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -e "$R/decision-wait-ready" ]] && break
  sleep 0.01
done
decision_wait_started="$(date +%s)"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1; decision_wait_rc=$?
decision_wait_elapsed="$(( $(date +%s) - decision_wait_started ))"
decision_wait_state="rc=$decision_wait_rc bounded=no"
(( decision_wait_elapsed <= 4 )) && decision_wait_state="rc=$decision_wait_rc bounded=yes"
decision_wait_state="$decision_wait_state request=$([[ -e "$decision_wait_request" ]] && echo present || echo gone)"
decision_wait_state="$decision_wait_state dossier=$([[ -e "$decision_wait_dossier" ]] && echo present || echo gone)"
check_eq "decision contention cannot fail or strand a new user prompt" \
  "$decision_wait_state" "rc=0 bounded=yes request=gone dossier=gone"
kill -TERM "$decision_wait_holder" 2>/dev/null || true; wait "$decision_wait_holder" 2>/dev/null || true

# The timeout must cover OPEN as well as flock. Shell `exec >>path` blocks before Perl's
# alarm when the gitignored mutex path is a FIFO (or a symlink to one), wedging the user
# prompt forever. Run under an outer alarm so the regression fails quickly, not by hanging.
fifo_request="$(session_state_path "$R" verdict-request session-a)"
fifo_dossier="$(session_state_path "$R" last-verdict.json session-a)"
fifo_publish_mutex="${fifo_request}.publish.mutex"
printf '511-512-4 %s cksum-1-1\n' "$(( $(date +%s) + 600 ))" > "$fifo_request"
printf '{"generation":"511-512-4","verdict":"PASS"}\n' > "$fifo_dossier"
rm -f "$fifo_publish_mutex"
mkfifo "$R/publish-mutex-fifo"
ln -s "$R/publish-mutex-fifo" "$fifo_publish_mutex"
fifo_payload="$(jq -nc --arg s session-a \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:"ok"}')"
printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) >/dev/null 2>&1
fifo_rc=$?
fifo_state="rc=$fifo_rc request=$([[ -e "$fifo_request" ]] && echo present || echo gone)"
fifo_state="$fifo_state dossier=$([[ -e "$fifo_dossier" ]] && echo present || echo gone)"
check_eq "a FIFO publication-mutex path cannot block prompt cancellation" \
  "$fifo_state" "rc=0 request=gone dossier=gone"
rm -f "$fifo_publish_mutex" "$R/publish-mutex-fifo"

# Even if the short decision mutex itself is unsafe, visible authority is revoked before
# that fallible open. Nonzero is acceptable; leaving request/PASS state behind is not.
unsafe_decision_request="$(session_state_path "$R" verdict-request session-a)"
unsafe_decision_dossier="$(session_state_path "$R" last-verdict.json session-a)"
unsafe_decision_mutex="${unsafe_decision_request}.decision.mutex"
printf '521-522-5 %s cksum-1-1\n' "$(( $(date +%s) + 600 ))" \
  > "$unsafe_decision_request"
printf '{"generation":"521-522-5","verdict":"PASS"}\n' > "$unsafe_decision_dossier"
mkfifo "$R/decision-mutex-fifo"
rm -f "$unsafe_decision_mutex"
ln -s "$R/decision-mutex-fifo" "$unsafe_decision_mutex"
unsafe_decision_payload="$(jq -nc --arg s session-a \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:"ok"}')"
printf '%s' "$unsafe_decision_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) >/dev/null 2>&1
unsafe_decision_rc=$?
unsafe_decision_state="rc=$unsafe_decision_rc request=$([[ -e "$unsafe_decision_request" ]] && echo present || echo gone)"
unsafe_decision_state="$unsafe_decision_state dossier=$([[ -e "$unsafe_decision_dossier" ]] && echo present || echo gone)"
check_eq "unsafe decision mutex still revokes visible audit authority" \
  "$unsafe_decision_state" "rc=1 request=gone dossier=gone"
rm -f "$unsafe_decision_mutex" "$R/decision-mutex-fifo"

# A forged lock names a real, same-uid process but not run-verdict-audit.sh. If command
# identity is not checked, USR1 becomes an arbitrary-process kill primitive.
sentinel_hit="$R/forged-was-signalled"
sentinel_ready="$R/forged-ready"
bash -c 'trap '\''touch "$1"; exit 0'\'' USR1; touch "$2"; : "$3"; while :; do sleep 0.05; done' \
  _ "$sentinel_hit" "$sentinel_ready" "$RUNNER" &
sentinel_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -e "$sentinel_ready" ]] && break; sleep 0.01; done
now="$(date +%s)"
unsafe_scope="$(session_scope_of "$R" session-a)"
unsafe_lock_path="$(session_state_path "$R" verdict-audit.lock session-a)"
unsafe_owner_token="${sentinel_pid}-${now}-1"
printf '%s %s 0 %s %s 501-502-3' "$sentinel_pid" "$((now + 60))" "$unsafe_scope" \
  "$unsafe_owner_token" \
  > "$unsafe_lock_path"
# Merely mentioning the runner path in inert argv must not turn the hook into a signal
# primitive, regardless of fabricated workspace lock state.
prompt_hook "$R" session-a turn-a >/dev/null 2>&1; forged_rc=$?
for (( poll_index=0; poll_index<30; poll_index++ )); do [[ -e "$sentinel_hit" ]] && break; sleep 0.02; done
forged_state="rc=$forged_rc process=$(process_state "$sentinel_pid") hit=$([[ -e "$sentinel_hit" ]] && echo yes || echo no)"
check_eq "forged live PID is not signalled" "$forged_state" "rc=0 process=alive hit=no"
kill -TERM "$sentinel_pid" 2>/dev/null || true; wait "$sentinel_pid" 2>/dev/null || true

for body in "" "0 1 0 - - x" "not-a-pid 1 0 - - x"; do
  printf '%s' "$body" > "$unsafe_lock_path"
  prompt_hook "$R" session-a turn-a >/dev/null 2>&1
  check_eq "malformed lock '${body:-<empty>}' -> exit 0" "$?" 0
done
rm -rf "$R"

echo
echo "## A prompt invalidates a just-finished audit even after its runner exited"
# The lock disappears at runner exit, but the artifact/request remain until Stop consumes
# them. That interval is precisely where a real steer can supersede the audited turn.
R="$(setup)"; generation="701-702-3"
request_path="$(session_state_path "$R" verdict-request session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
previous_path="$(session_state_path "$R" last-verdict.prev.json session-a)"
printf '%s %s %s\n' "$generation" "$(( $(date +%s) + 600 ))" "cksum-1-1" > "$request_path"
jq -nc --arg g "$generation" \
  '{branch:"main",head:"h",tree_hash:"t",generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$dossier_path"
printf 'parked findings from abandoned work\n' > "$previous_path"
finished_out="$(prompt_hook "$R" session-a turn-a 2>"$R/finished.err")"; finished_rc=$?
finished_state="rc=$finished_rc request=$([[ -e "$request_path" ]] && echo present || echo gone)"
finished_state="$finished_state dossier=$([[ -e "$dossier_path" ]] && echo present || echo gone)"
finished_state="$finished_state previous=$([[ -e "$previous_path" ]] && echo present || echo gone)"
finished_state="$finished_state stdout=${finished_out:-} stderr=$(cat "$R/finished.err")"
check_eq "new input revokes the completed generation before it can authorize new claims" \
  "$finished_state" "rc=0 request=gone dossier=gone previous=gone stdout= stderr="
rm -rf "$R"

echo
echo "## An abandoned auditor writing after cancellation has no authority"
R="$(setup)"; generation="711-712-4"
request_path="$(session_state_path "$R" verdict-request session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
printf '%s %s %s\n' "$generation" "$(( $(date +%s) + 600 ))" "cksum-1-1" > "$request_path"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
late_dossier="$(jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}')"
printf '%s\n' "$late_dossier" > "$dossier_path"
# Also place the pre-session path so this test is mutation-sensitive against the old
# global gate: it would consume this PASS and allow the superseding turn.
printf '%s\n' "$late_dossier" > "$R/.agents/state/last-verdict.json"
late_out="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_AUDITOR_CMD='exit 2' \
      CODEX_BIN=/nonexistent PATH=/opt/homebrew/bin:/usr/bin:/bin \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='cat >/dev/null; echo YES' \
      bash "$PREFLIGHT" ) 2>/dev/null)"
late_state="decision=$(printf '%s' "$late_out" | jq -r '.decision // "allow"')"
late_state="$late_state dossier=$([[ -e "$dossier_path" ]] && echo present || echo gone)"
new_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
if [[ "$new_generation" == "$generation" ]]; then
  generation_state=old
elif [[ "$new_generation" == MISSING ]]; then
  generation_state=missing
else
  generation_state=fresh
fi
late_state="$late_state request=$generation_state"
check_eq "a late abandoned PASS is rejected after its generation was revoked" \
  "$late_state" "decision=block dossier=gone request=fresh"
rm -rf "$R"

echo
echo "## Revocation before lock publication prevents the audit from starting"
R="$(setup)"; generation="731-732-5"
request_path="$(session_state_path "$R" verdict-request session-a)"
lock_path="$(session_state_path "$R" verdict-audit.lock session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
printf '%s %s cksum-1-1\n' "$generation" "$(( $(date +%s) + 600 ))" > "$request_path"
cat > "$R/startup-gap-env.sh" <<'STARTUP_GAP_ENV'
if [[ -z "${VERDICT_STARTUP_GAP_OWNER_PID:-}" ]]; then
  export VERDICT_STARTUP_GAP_OWNER_PID="$$"
  verdict_startup_gap_debug() {
    if [[ "$$" == "$VERDICT_STARTUP_GAP_OWNER_PID" && "$BASH_COMMAND" == take_audit_lock ]]; then
      touch "$CLAUDE_PROJECT_DIR/startup-gap"
      while [[ ! -e "$CLAUDE_PROJECT_DIR/release-startup-gap" ]]; do sleep 0.01; done
    fi
  }
  trap verdict_startup_gap_debug DEBUG
fi
STARTUP_GAP_ENV
STARTUP_STUB='cat >/dev/null
  touch "$CLAUDE_PROJECT_DIR/startup-auditor-ran"
  target="$VERDICT_AUDITOR_OUTPUT_FILE"
  mkdir -p "$(dirname "$target")"
  printf "{\"branch\":\"main\",\"head\":\"h\",\"tree_hash\":\"t\",\"generation\":\"%s\",\"verdict\":\"PASS\",\"proof\":[],\"findings\":[]}" \
    "$VERDICT_AUDITOR_GENERATION" > "$target"'
( cd "$R" && CLAUDE_PROJECT_DIR="$R" BASH_ENV="$R/startup-gap-env.sh" \
    VERDICT_AUDITOR_CMD="$STARTUP_STUB" \
    bash "$RUNNER" "$R/transcript.jsonl" session-a "$generation" \
      >"$R/startup.out" 2>"$R/startup.err" ) & startup_job=$!
for (( poll_index=0; poll_index<150; poll_index++ )); do [[ -e "$R/startup-gap" ]] && break; sleep 0.02; done
( prompt_hook "$R" session-a turn-a >/dev/null 2>&1 ) & startup_prompt_job=$!
( sleep 5; kill_test_pids KILL "$startup_job" "$startup_prompt_job" ) & watchdog=$!
for (( poll_index=0; poll_index<150; poll_index++ )); do
  [[ ! -e "$request_path" ]] && break
  sleep 0.02
done
touch "$R/release-startup-gap"
wait "$startup_job" 2>/dev/null; startup_rc=$?
wait "$startup_prompt_job" 2>/dev/null; startup_prompt_rc=$?
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
startup_state="rc=$startup_rc prompt_rc=$startup_prompt_rc ran=$([[ -e "$R/startup-auditor-ran" ]] && echo yes || echo no)"
startup_state="$startup_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
startup_state="$startup_state lock=$([[ -e "$lock_path" ]] && echo present || echo gone)"
startup_state="$startup_state dossier=$([[ -e "$dossier_path" ]] && echo present || echo gone)"
check_eq "pre-lock user input revokes the generation before model work begins" \
  "$startup_state" "rc=130 prompt_rc=0 ran=no request=gone lock=gone dossier=gone"
rm -rf "$R"

echo
echo "## A real prompt cancels only its session's live audit"
R="$(setup)"
# TERM reaches the auditor's entire process group. The auditor deliberately writes a
# late PASS from its TERM handler; the runner must remove it before reporting cancel.
CANCEL_STUB='target="${VERDICT_AUDITOR_OUTPUT_FILE:-$CLAUDE_PROJECT_DIR/.agents/state/last-verdict.json}"
  generation="${VERDICT_AUDITOR_GENERATION:-legacy}"
  trap '\''mkdir -p "$(dirname "$target")"; printf "{\"branch\":\"late\",\"head\":\"late\",\"tree_hash\":\"late\",\"generation\":\"%s\",\"verdict\":\"PASS\"}" "$generation" > "$target"; exit 143'\'' TERM INT
  sleep 30 & child=$!
  printf "%s %s\n" "$$" "$child" > "$CLAUDE_PROJECT_DIR/auditor-pids"
  wait "$child"'
generation="721-722-4"
lock_path="$(session_state_path "$R" verdict-audit.lock session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
request_path="$(session_state_path "$R" verdict-request session-a)"
printf '%s %s cksum-1-1\n' "$generation" "$(( $(date +%s) + 600 ))" > "$request_path"
( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_AUDITOR_CMD="$CANCEL_STUB" \
    bash "$RUNNER" "$R/transcript.jsonl" session-a "$generation" \
      >"$R/runner.out" 2>"$R/runner.err" ) &
runner_job=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -s "$lock_path" && -s "$R/auditor-pids" ]] && break
  sleep 0.02
done
runner_pid="$(awk '{print $1}' "$lock_path" 2>/dev/null || echo 0)"
read -r auditor_pid grandchild_pid < "$R/auditor-pids" 2>/dev/null || {
  auditor_pid=0; grandchild_pid=0;
}

wrong_out="$(prompt_hook "$R" session-b turn-a 2>"$R/wrong.err")"; wrong_rc=$?
wrong_state="rc=$wrong_rc runner=$(process_state "$runner_pid") stdout=${wrong_out:-} stderr=$(cat "$R/wrong.err")"
check_eq "another session cannot cancel the audit" "$wrong_state" "rc=0 runner=alive stdout= stderr="

same_out="$(prompt_hook "$R" session-a turn-a 2>"$R/same.err")"; same_rc=$?
# A broken cancellation path must not hang the suite for the stub's 30-second sleep.
( sleep 3
  for doomed_pid in "$runner_pid" "$auditor_pid" "$grandchild_pid"; do
    [[ "$doomed_pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$doomed_pid" 2>/dev/null || true
  done
) & watchdog=$!
wait "$runner_job" 2>/dev/null; runner_rc=$?
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true

same_state="hook_rc=$same_rc runner_rc=$runner_rc auditor=$(process_state "$auditor_pid") child=$(process_state "$grandchild_pid")"
[[ -e "$lock_path" ]] && same_state="$same_state lock=present" \
                                                   || same_state="$same_state lock=gone"
[[ -e "$dossier_path" ]] && same_state="$same_state dossier=present" \
                                                  || same_state="$same_state dossier=gone"
audit_temp="$(find "$R/.agents/state" -maxdepth 1 -name "$(basename "$dossier_path").audit-*" -print -quit 2>/dev/null)"
[[ -n "$audit_temp" ]] && same_state="$same_state temp=present" \
                           || same_state="$same_state temp=gone"
check_eq "same-session prompt cancels descendants and rejects the late dossier" \
  "$same_state" "hook_rc=0 runner_rc=130 auditor=gone child=gone lock=gone dossier=gone temp=gone"
check_eq "cancellation hook does not inject prompt context" \
  "stdout=${same_out:-} stderr=$(cat "$R/same.err")" "stdout= stderr="
case "$(cat "$R/runner.err" 2>/dev/null)" in
  *"cancelled"*"new user prompt"*) ok "runner explains the cancellation cause" ;;
  *) bad "runner explains the cancellation cause" ;;
esac
rm -rf "$R"

echo
echo "## Concurrent sessions retain independently cancellable owners"
R="$(setup)"
PARALLEL_STUB='cat >/dev/null
  trap "" HUP
  trap '\''exit 143'\'' TERM INT
  printf "%s\n" "$$" > "$CLAUDE_PROJECT_DIR/auditor-$AUDIT_LABEL"
  sleep 30'
printf '%s %s cksum-1-1\n' 801-802-3 "$(( $(date +%s) + 600 ))" \
  > "$(session_state_path "$R" verdict-request session-a)"
printf '%s %s cksum-1-1\n' 811-812-4 "$(( $(date +%s) + 600 ))" \
  > "$(session_state_path "$R" verdict-request session-b)"
( cd "$R" && exec env CLAUDE_PROJECT_DIR="$R" AUDIT_LABEL=a \
    VERDICT_AUDITOR_CMD="$PARALLEL_STUB" bash "$RUNNER" "$R/transcript.jsonl" session-a 801-802-3 \
      >"$R/runner-a.out" 2>"$R/runner-a.err" ) & runner_a_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -s "$R/auditor-a" ]] && break; sleep 0.02; done
( cd "$R" && exec env CLAUDE_PROJECT_DIR="$R" AUDIT_LABEL=b \
    VERDICT_AUDITOR_CMD="$PARALLEL_STUB" bash "$RUNNER" "$R/transcript.jsonl" session-b 811-812-4 \
      >"$R/runner-b.out" 2>"$R/runner-b.err" ) & runner_b_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -s "$R/auditor-b" ]] && break; sleep 0.02; done

prompt_hook "$R" session-a turn-a >/dev/null 2>&1
for (( poll_index=0; poll_index<100; poll_index++ )); do kill -0 "$runner_a_pid" 2>/dev/null || break; sleep 0.02; done
b_state="$(process_state "$runner_b_pid")"
if kill -0 "$runner_a_pid" 2>/dev/null; then kill -TERM "$runner_a_pid" 2>/dev/null || true; fi
wait "$runner_a_pid" 2>/dev/null; runner_a_rc=$?
kill -TERM "$runner_b_pid" 2>/dev/null || true; wait "$runner_b_pid" 2>/dev/null || true
check_eq "session A's steer cancels A while session B keeps running" \
  "a_rc=$runner_a_rc b=$b_state" "a_rc=130 b=alive"
rm -rf "$R"

echo
echo "## One session admits only one headless audit owner"
R="$(setup)"; generation="821-822-5"
printf '%s %s cksum-1-1\n' "$generation" "$(( $(date +%s) + 600 ))" \
  > "$(session_state_path "$R" verdict-request session-a)"
DUPLICATE_STUB='cat >/dev/null
  trap '\''exit 143'\'' TERM INT
  touch "$CLAUDE_PROJECT_DIR/duplicate-$AUDIT_LABEL-ran"
  sleep 30'
( cd "$R" && exec env CLAUDE_PROJECT_DIR="$R" AUDIT_LABEL=a \
    VERDICT_AUDITOR_CMD="$DUPLICATE_STUB" bash "$RUNNER" "$R/transcript.jsonl" \
      session-a "$generation" >"$R/duplicate-a.out" 2>"$R/duplicate-a.err" ) & duplicate_a_job=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -e "$R/duplicate-a-ran" ]] && break; sleep 0.02; done
( cd "$R" && exec env CLAUDE_PROJECT_DIR="$R" AUDIT_LABEL=b \
    VERDICT_AUDITOR_CMD="$DUPLICATE_STUB" bash "$RUNNER" "$R/transcript.jsonl" \
      session-a "$generation" >"$R/duplicate-b.out" 2>"$R/duplicate-b.err" ) & duplicate_b_job=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  kill -0 "$duplicate_b_job" 2>/dev/null || break
  [[ -e "$R/duplicate-b-ran" ]] && break
  sleep 0.02
done
if kill -0 "$duplicate_b_job" 2>/dev/null; then duplicate_b_state=running; else duplicate_b_state=exited; fi
if [[ "$duplicate_b_state" == exited ]]; then
  wait "$duplicate_b_job" 2>/dev/null; duplicate_b_rc=$?
else
  duplicate_b_rc=running
fi
prompt_hook "$R" session-a turn-a >/dev/null 2>&1
( sleep 3; kill -KILL "$duplicate_a_job" "$duplicate_b_job" 2>/dev/null || true ) & watchdog=$!
wait "$duplicate_a_job" 2>/dev/null; duplicate_a_rc=$?
if [[ "$duplicate_b_state" == running ]]; then
  wait "$duplicate_b_job" 2>/dev/null; duplicate_b_rc=$?
fi
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
duplicate_state="a_rc=$duplicate_a_rc b_rc=$duplicate_b_rc"
duplicate_state="$duplicate_state a_ran=$([[ -e "$R/duplicate-a-ran" ]] && echo yes || echo no)"
duplicate_state="$duplicate_state b_ran=$([[ -e "$R/duplicate-b-ran" ]] && echo yes || echo no)"
check_eq "a duplicate runner cannot displace the session's cancellable owner" \
  "$duplicate_state" "a_rc=130 b_rc=2 a_ran=yes b_ran=no"
rm -rf "$R"

echo
echo "## Only the wake itself is internal; text riding along makes a real prompt"
R="$(setup)"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1
outcome_request="$(session_state_path "$R" verdict-request session-a)"
outcome_epoch="$(session_state_path "$R" verdict-prompt-epoch session-a)"
# Submit one prompt over a live audit request; report what it left of the request and epoch.
submit_outcome() {  # repo prompt label
  local repo="$1" prompt="$2" label="$3" epoch_before out rc
  printf 'keep\n' > "$outcome_request"
  epoch_before="$(cat "$outcome_epoch")"
  out="$(jq -nc --arg s session-a --arg p "$prompt" \
      '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}' \
    | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$HOOK") 2>"$repo/$label.err")"
  rc=$?
  printf 'rc=%s request=%s epoch=%s stdout=%s stderr=%s' "$rc" \
    "$([[ -e "$outcome_request" ]] && echo present || echo gone)" \
    "$([[ "$(cat "$outcome_epoch")" == "$epoch_before" ]] && echo same || echo changed)" \
    "$out" "$(cat "$repo/$label.err")"
}
# Escalate a fresh auditor and return the prompt the host would submit for its wake.
mint_wake() {  # repo agent-id
  jq -nc --arg id "$2" \
      '{hook_event_name:"SubagentStart",session_id:"session-a",agent_id:$id,agent_type:"verdict-auditor"}' \
    | (cd "$1" && env -u PLUGIN_ROOT CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
        AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$CONTROL") >/dev/null 2>"$1/$2.err"
  rewake_prompt SubagentStart:verdict-auditor "$(cat "$1/$2.err")"
}
# Each refusal is followed by the same wake alone, which must still be internal: the
# nonce was valid and unspent, so the text riding along is what made the prompt real.
tail_wake="$(mint_wake "$R" ride-tail)"
check_eq "text after a valid wake is a new prompt" \
  "$(submit_outcome "$R" "$tail_wake"$'\nand also rename the module' ride-tail)" \
  "rc=0 request=gone epoch=changed stdout= stderr="
check_eq "the wake refused for trailing text still holds an unspent nonce" \
  "$(submit_outcome "$R" "$tail_wake" ride-tail-alone)" \
  "rc=0 request=present epoch=same stdout= stderr="
second_wake="$(mint_wake "$R" ride-second)"
check_eq "a second reminder after a valid wake is a new prompt" \
  "$(submit_outcome "$R" "$second_wake"$'\n<system-reminder>\nand also rename the module\n</system-reminder>' ride-second)" \
  "rc=0 request=gone epoch=changed stdout= stderr="
check_eq "the wake refused for a second reminder still holds an unspent nonce" \
  "$(submit_outcome "$R" "$second_wake" ride-second-alone)" \
  "rc=0 request=present epoch=same stdout= stderr="
reworded_wake="$(mint_wake "$R" ride-reworded \
  | sed 's/Stop hook blocking error from command/Async hook woke the model from command/')"
check_eq "a wake stays internal when the host rewords its reminder" \
  "$(submit_outcome "$R" "$reworded_wake" ride-reworded)" \
  "rc=0 request=present epoch=same stdout= stderr="
rm -rf "$R"

echo
echo "## A resume after an API error continues its prompt, once"
R="$(setup)"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1
outcome_request="$(session_state_path "$R" verdict-request session-a)"
outcome_epoch="$(session_state_path "$R" verdict-prompt-epoch session-a)"
# Run the StopFailure hook for a dropped stream and return the prompt the host submits.
resume_wake() {  # repo -> prompt on stdout; status is the hook's exit code
  local repo="$1" rc=0
  printf '%s' '{"hook_event_name":"StopFailure","session_id":"session-a","error":"server_error"}' \
    | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$RESUME") >/dev/null \
      2>"$repo/resume.err" || rc=$?
  rewake_prompt StopFailure:server_error "$(cat "$repo/resume.err")"
  return "$rc"
}
resume_prompt="$(resume_wake "$R")"
resume_rc=$?
check_eq "the StopFailure hook wakes the host for a dropped stream" "$resume_rc" 2
check_eq "a resume wake keeps the running audit and the prompt epoch" \
  "$(submit_outcome "$R" "$resume_prompt" resume)" \
  "rc=0 request=present epoch=same stdout= stderr="
check_eq "a spent resume wake replayed is a new prompt" \
  "$(submit_outcome "$R" "$resume_prompt" resume-replay)" \
  "rc=0 request=gone epoch=changed stdout= stderr="
forged_resume_prompt="$(resume_wake "$R" \
  | sed 's/api-resume-wake:[0-9a-f]*/api-resume-wake:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/')"
check_eq "a forged resume marker is a new prompt" \
  "$(submit_outcome "$R" "$forged_resume_prompt" resume-forged)" \
  "rc=0 request=gone epoch=changed stdout= stderr="
rm -rf "$R"

echo
echo "## Prompt cancellation removes generation-owned native prior snapshots"
R="$(setup)"
prior_prefix="$(session_state_path "$R" verdict-previous-dossier.json session-a).input-"
printf '%s\n' old > "${prior_prefix}101-102-3"
printf '%s\n' newer > "${prior_prefix}201-202-4"
prompt_hook "$R" session-a turn-a >/dev/null 2>&1
remaining_prior_inputs="$(compgen -G "${prior_prefix}*" | head -n 1 || true)"
check_eq "a new prompt removes every generation-owned native prior snapshot" \
  "${remaining_prior_inputs:-none}" none
rm -rf "$R"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
