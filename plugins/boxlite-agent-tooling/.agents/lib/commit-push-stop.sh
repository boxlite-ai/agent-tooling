#!/usr/bin/env bash
# SubagentStop closure for native dossier attempts prepared by runtime hooks.
# Requires subagent.sh, verdict-audit-state.sh, auditor-override-state.sh,
# audit-reflection.sh, audit-reflection-gate.sh, and jq. Source this file; it performs no
# work on load.

# A native dossier auditor's record step.
audit_attempt_stop_record() {  # attempt id, dossier path
  printf 'Write the dossier for attempt %s to %s. At the runtime deadline: confirmed blockers FAIL; otherwise PASS, with each unchecked check and its reason in advisories.' "$1" "$2"
}

# Print a block reason to keep the auditor running, or nothing to let it stop.
# A stop always leaves the attempt closed: recorded from a bound dossier, or ERROR.
audit_attempt_stop_check() {  # repo session-scope stop-hook-active [auditor] [host-agent-id]
  local repo="$1" scope="$2" resumed="$3" link task context id dossier deadline
  local history snapshot document="" state=missing reason
  local auditor="${4:-commit-push-auditor}" retained
  link="$(auditor_override_control_dir "$repo")/audit-task.$scope.$auditor.json"
  [[ -e "$link" || -L "$link" ]] || return 0
  task="$(verdict_audit_read_single_record "$link")" || return 2
  if [[ "$auditor" == verdict-auditor ]] || jq -e 'has("host_agent_id")' <<<"$task" >/dev/null; then
    [[ -n "${5:-}" && "$(jq -r .host_agent_id <<<"$task")" == "$5" ]] || return 0
  fi
  context="$(jq -ce '.context | objects' <<<"$task")" || return 2
  id="$(jq -er '.attempt_id | strings' <<<"$task")" || return 2
  dossier="$(jq -er '.dossier_path | strings' <<<"$task")" || return 2
  deadline="$(jq -er '.deadline | numbers' <<<"$task")" || return 2
  history="$(audit_reflection_gate "$context" inspect)" || return 2
  if ! jq -e --arg id "$id" 'any(.state.attempts[]; .id == $id and .outcome == null)' \
      <<<"$history" >/dev/null; then
    verdict_audit_remove_record_if_matches "$link" "$task" || return 2
    return 0
  fi
  if [[ "$auditor" == verdict-auditor ]]; then
    retained="$(audit_request_context_read "$repo" "$scope" 2>/dev/null)" || retained=null
    if ! jq -e --argjson retained "$retained" \
        '.generation == ($retained.request // "" | split(" ")[0])' <<<"$task" >/dev/null; then
      audit_reflection_gate "$context" error "$id" '"Native verdict request revoked or changed"' >/dev/null || return 2
      verdict_audit_remove_record_if_matches "$link" "$task" || return 2
      return 0
    fi
  fi
  if snapshot="$(verdict_audit_read_json_snapshot "$dossier" 2>/dev/null)" \
      && [[ "$snapshot" == *$'\n'* ]]; then
    document="$(jq -ce --arg id "$id" 'select(.history_review.attempt_id == $id)' \
      <<<"${snapshot#*$'\n'}" 2>/dev/null)" || document=""
  fi
  if [[ -n "$document" ]]; then
    if [[ "$auditor" == verdict-auditor ]]; then
      document="$(printf '%s' "$document" | verdict_audit_normalize_dossier 2>/dev/null)" || document=""
    fi
  fi
  if [[ -n "$document" ]]; then
    state=recorded
    if jq -e 'any(.findings[]?; startswith("unchecked:") or startswith("high: unchecked:"))' \
        <<<"$document" >/dev/null; then
      state=unchecked
    fi
  fi
  # One block per stop: Claude Code sets stop_hook_active once a hook has resumed it.
  reason="$(subagent_timed_stop "$deadline" "$state" "$resumed" \
    "$(audit_attempt_stop_record "$id" "$dossier")")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason"
    return 0
  fi
  if [[ -n "$document" ]] \
      && audit_reflection_gate "$context" record "$id" "$document" >/dev/null 2>&1; then
    verdict_audit_remove_record_if_matches "$link" "$task" || return 2
    return 0
  fi
  audit_reflection_gate "$context" error "$id" \
    '"Auditor stopped without a bound, recordable dossier"' >/dev/null || return 2
  verdict_audit_remove_record_if_matches "$link" "$task"
}
