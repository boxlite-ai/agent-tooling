#!/usr/bin/env bash
# Native verdict tasks derive authority from a live request, never a host agent ID.
# Requires subagent, verdict-audit-state, audit-request, audit-reflection{-gate},
# and auditor-override-state. Source only.
verdict_audit_task_prepare() { # repository, scope, host agent ID, event -> task JSON
  local repo="$1" scope="$2" agent="$3" event="$4" retained generation epoch context binding
  local history input id request timeout task path current existing active
  retained="$(audit_request_context_read "$repo" "$scope" 2>/dev/null)" || return 1
  generation="$(jq -r '.request | split(" ")[0]' <<<"$retained")" || return 2
  [[ "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  path="$(auditor_override_control_dir "$repo")/audit-task.$scope.verdict-auditor.json"
  existing="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || existing=null
  if [[ "$existing" != null ]]; then
    # A delayed event cannot take over a different host or a newer request.
    if [[ "$(jq -r .host_agent_id <<<"$existing")" == "$agent" ]]; then
      [[ "$(jq -r .generation <<<"$existing")" == "$generation" ]] || return 1
      # Reuse without publishing: a concurrent replacement must not be overwritten.
      printf '%s\n' "$existing"
      return 0
    else
      [[ "$event" == SubagentStart ]] || return 1
    fi
  elif [[ "$event" != SubagentStart ]]; then
    active="$(verdict_audit_read_single_record "${path%/*}/active.$scope.verdict-auditor.json" 2>/dev/null)" || return 1
    jq -e --arg agent "$agent" --arg scope "$scope" --argjson retained "$retained" \
      '.generation == $agent and .session_scope == $scope and .auditor == "verdict-auditor"
       and .state == "running" and .prompt_epoch == $retained.origin_epoch' <<<"$active" >/dev/null || return 1
  fi
  epoch="$(jq -r .origin_epoch <<<"$retained")"; [[ "$epoch" != - ]] || epoch=0
  binding="$(jq -c --arg generation "$generation" '{branch,head,tree_hash,generation:$generation}' <<<"$retained")" || return 2
  context="$(jq -nc --arg root "$repo" --arg scope "$scope" --arg epoch "$epoch" \
    --arg branch "$(jq -r '.branch | if . == "" then "HEAD" else . end' <<<"$retained")" \
    '{repo_root:$root,session:$scope,epoch:$epoch,branch:$branch,gate:"verdict"}')" || return 2
  history="$(audit_reflection_gate "$context" inspect)" || return 2
  input="$(jq -c --argjson binding "$binding" '
    .state.attempts[-1] | if .input.binding == $binding and (.outcome == null or .outcome.verdict == "PASS")
    then .input else null end' <<<"$history")" || return 2
  if [[ "$input" == null ]]; then
    timeout="$(subagent_timed_timeout VERDICT_AUDITOR_TIMEOUT "${VERDICT_AUDITOR_TIMEOUT:-180}" 3480)" || return 2
    audit_reflection_cancel_open "$context" 'Superseded by the live verdict request' "$binding" || return 2
    input="$(jq -nc --argjson binding "$binding" --argjson deadline "$(( $(date +%s) + timeout ))" \
      --arg request "$(jq -r .request <<<"$retained")" \
      '{binding:$binding,snapshot:{request:$request,tree:$binding.tree_hash},deadline:$deadline}')" || return 2
    id=""
  else
    id="$(jq -r .id <<<"$input")"
  fi
  request="$(audit_reflection_gate "$context" prepare "$id" "$input")" || return 2
  [[ "$(jq -r '.deadline // empty' <<<"$request")" != "" ]] || return 1
  # Recheck after preparation; a revoked/replaced request cannot gain a task link.
  current="$(audit_request_context_read "$repo" "$scope" 2>/dev/null)" || return 1
  [[ "$current" == "$retained" ]] || return 1
  mkdir -p "${path%/*}" || return 2
  task="$(jq -nc --argjson context "$context" --argjson request "$request" \
    --arg generation "$generation" --arg agent "$agent" \
    --arg dossier "$repo/.agents/state/last-verdict.json.$scope.audit-$generation" \
    '{context:$context,attempt_id:$request.attempt_id,history_path:$request.history_path,
      dossier_path:$dossier,deadline:($request.deadline // 0),generation:$generation,host_agent_id:$agent}')" || return 2
  printf '%s\n' "$task" | verdict_audit_write_atomic "$path" || return 2
  printf '%s\n' "$task"
}
