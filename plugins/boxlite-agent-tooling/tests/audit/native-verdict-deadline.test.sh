#!/usr/bin/env bash
# Exercise host events, real request binding, history recording, and task cleanup.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for library in verdict-audit-state audit-request audit-reflection audit-reflection-gate; do
  # shellcheck source=/dev/null
  source "$plugin/.agents/lib/$library.sh"
done
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
repo="$scratch/repo"; mkdir "$repo"
git -C "$repo" init -q
printf '.agents/\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" -c core.hooksPath=/dev/null -c user.name=test -c user.email=t@t.test commit -qm base
mkdir -p "$repo/.agents/state"
hook="$plugin/.agents/hooks/audit-deadline.sh"
for host in claude codex; do
  scope="$(verdict_audit_scope_identity "$host-session" "$repo")"
  epoch=101-201-1; generation=301-401-1
  printf '%s\n' "$epoch" >"$repo/.agents/state/verdict-prompt-epoch.$scope"
  create_request() {
    local request="$generation $(( $(date +%s) + 3600 )) cksum-1-1"
    printf '%s\n' "$request" >"$repo/.agents/state/verdict-request.$scope"
    audit_request_context_write "$repo" "$scope" "$request" "$epoch"
  }
  create_request
  jq -nc --arg parent "$host-session" '{type:"session_meta",payload:{id:"host-agent-uuid",
    session_id:$parent,thread_source:"subagent",source:{subagent:{thread_spawn:{
      parent_thread_id:$parent,agent_path:"/root/verdict_auditor"}}}}}' >"$scratch/agent.jsonl"
  payload="$(jq -nc --arg cwd "$repo" --arg session "$host-session" --arg host "$host" \
    --arg transcript "$scratch/agent.jsonl" '{cwd:$cwd,session_id:$session,agent_id:"host-agent-uuid",
      agent_type:(if $host == "claude" then "boxlite-agent-tooling:verdict-auditor" else "default" end),
      transcript_path:$transcript,agent_transcript_path:$transcript,stop_hook_active:false}')"
  event() { jq -c --arg event "$1" --arg tool "${2:-Read}" \
    '. + {hook_event_name:$event,tool_name:$tool,tool_input:{}}' <<<"$payload"; }
  env VERDICT_AUDITOR_TIMEOUT=2 bash "$hook" <<<"$(event SubagentStart)"
  link="$repo/.agents/state/auditor-control/audit-task.$scope.verdict-auditor.json"
  [[ -f "$link" ]] || { printf 'FAIL: %s native request never acquired its runtime task\n' "$host" >&2; exit 1; }
  task="$(cat "$link")"; deadline="$(jq -r .deadline <<<"$task")"
  jq -e --arg generation "$generation" '.generation == $generation and .host_agent_id != $generation' <<<"$task" >/dev/null
  env VERDICT_AUDITOR_TIMEOUT=900 bash "$hook" <<<"$(event SubagentStart)"
  [[ "$(jq -r .deadline "$link")" == "$deadline" ]]
  perl -e 'my $wait=$ARGV[0]-time+1; sleep $wait if $wait>0' "$deadline"
  status=0; bash "$hook" <<<"$(event PreToolUse)" >"$scratch/out" 2>"$scratch/err" || status=$?
  [[ "$status" == 2 && "$(cat "$scratch/err")" == *'otherwise PASS'* ]]
  bash "$hook" <<<"$(event PreToolUse TaskStop)"
  dossier="$(jq -r .dossier_path <<<"$task")"; history="$(jq -r .history_path <<<"$task")"
  jq '.attempts[-1].input.binding + {verdict:"PASS",findings:[],
    proof:[{claim:"tests passed",kind:"tests-pass",evidence:"not verified",method:"transcript",
      status:"blocked",blocker:"runtime deadline; execution records remain unread"}],
    advisories:["unchecked at deadline: execution records; verify command and exit status"]}' "$history" >"$dossier"
  bash "$plugin/tests/audit/fixtures/audit-history-result.sh" "$task" "$dossier" bind
  jq '.history_review.coverage |= {reviewed:[],unread:.reviewed}' "$dossier" >"$scratch/unread"
  mv "$scratch/unread" "$dossier"
  bash "$hook" <<<"$(event PreToolUse Write | jq --arg path "$dossier" '.tool_input.file_path=$path')"
  bash "$plugin/scripts/validate-audit-dossier.sh" verdict "$history" "$dossier" >/dev/null
  context="$(jq -c .context <<<"$task")"; id="$(jq -r .attempt_id <<<"$task")"
  document="$(cat "$dossier")"
  if [[ "$host" == codex ]]; then
    # The parent can consume before the native stop. Preserve recorded provenance.
    audit_reflection_gate "$context" record "$id" "$document" >/dev/null
    rm "$repo/.agents/state/verdict-request.$scope"
  fi
  bash "$hook" <<<"$(event SubagentStop)"
  [[ ! -e "$link" ]]
  recorded="$(audit_reflection_gate "$context" inspect)"
  jq -e --argjson deadline "$deadline" '.state.attempts[-1].outcome |
    .verdict == "PASS" and .deadline_review.deadline == $deadline
    and .evidence.proof[0].status == "blocked"' <<<"$recorded" >/dev/null
  audit_reflection_gate "$context" record "$id" "$document" >/dev/null
  [[ "$(audit_reflection_gate "$context" inspect)" == "$recorded" ]]
  if audit_reflection_gate "$context" record "$id" "$(jq '.generation="stale"' <<<"$document")" \
      >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: changed-generation replay accepted\n' >&2; exit 1
  fi
  generation=301-401-2; create_request
  old_payload="$payload"
  jq -c '.payload.id="new-host-agent"' "$scratch/agent.jsonl" >"$scratch/new-agent.jsonl"
  payload="$(jq --arg transcript "$scratch/new-agent.jsonl" '.agent_id="new-host-agent" |
    .transcript_path=$transcript | .agent_transcript_path=$transcript' <<<"$payload")"
  new_payload="$payload"
  env VERDICT_AUDITOR_TIMEOUT=2 bash "$hook" <<<"$(event SubagentStart)"
  task="$(cat "$link")"
  payload="$old_payload"
  bash "$hook" <<<"$(event PreToolUse)"
  bash "$hook" <<<"$(event SubagentStop)"
  [[ "$(cat "$link")" == "$task" ]] || {
    printf 'FAIL: stale host agent replaced or closed the current native task\n' >&2; exit 1;
  }
  payload="$new_payload"
  bash "$hook" <<<"$(event SubagentStop)" | jq -e '.decision == "block"' >/dev/null
  bash "$hook" <<<"$(event SubagentStop | jq '.stop_hook_active=true')"
  audit_reflection_gate "$(jq -c .context <<<"$task")" inspect \
    | jq -e '.state.attempts[-1].outcome.verdict == "ERROR"' >/dev/null
  env VERDICT_AUDITOR_TIMEOUT=2 bash "$hook" <<<"$(event SubagentStart)"
  [[ "$(jq -r .attempt_id "$link")" != "$(jq -r .attempt_id <<<"$task")" ]] || {
    printf 'FAIL: native retry reused a closed ERROR attempt\n' >&2; exit 1;
  }
  bash "$hook" <<<"$(event SubagentStop | jq '.stop_hook_active=true')"
  rm "$repo/.agents/state/verdict-request.$scope"
  bash "$hook" <<<"$(event SubagentStart)"
  [[ ! -e "$link" ]]
  printf 'PASS: %s native deadline, request identity, cleanup, replay and missing-report ERROR\n' "$host"
done
