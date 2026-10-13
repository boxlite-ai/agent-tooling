#!/usr/bin/env bash
# SubagentStop check for the commit/push attempt the preflight prepared.
# Requires verdict-audit-state.sh, auditor-override-state.sh, audit-reflection.sh,
# audit-reflection-gate.sh, and jq. Source this file; it performs no work on load.

# Print a block reason to keep the auditor running, or nothing to let it stop.
# A stop always leaves the attempt closed: recorded from a bound dossier, or ERROR.
commit_push_stop_check() {  # repo session-scope stop-hook-active
  local repo="$1" scope="$2" resumed="$3" link task context id dossier deadline
  local history snapshot document=""
  link="$(auditor_override_control_dir "$repo")/audit-task.$scope.commit-push-auditor.json"
  [[ -e "$link" || -L "$link" ]] || return 0
  task="$(verdict_audit_read_single_record "$link")" || return 2
  context="$(jq -ce '.context | objects' <<<"$task")" || return 2
  id="$(jq -er '.attempt_id | strings' <<<"$task")" || return 2
  dossier="$(jq -er '.dossier_path | strings' <<<"$task")" || return 2
  deadline="$(jq -er '.deadline | numbers' <<<"$task")" || return 2
  history="$(audit_reflection_gate "$context" inspect)" || return 2
  if ! jq -e --arg id "$id" 'any(.state.attempts[]; .id == $id and .outcome == null)' \
      <<<"$history" >/dev/null; then
    rm -f "$link"  # recorded at a retried git command, or superseded
    return 0
  fi
  if snapshot="$(verdict_audit_read_json_snapshot "$dossier" 2>/dev/null)" \
      && [[ "$snapshot" == *$'\n'* ]]; then
    document="$(jq -ce --arg id "$id" 'select(.history_review.attempt_id == $id)' \
      <<<"${snapshot#*$'\n'}" 2>/dev/null)" || document=""
  fi
  # One block per stop: Claude Code sets stop_hook_active once a hook has resumed it.
  if [[ "$resumed" != true ]] && (( $(date +%s) < deadline )); then
    if [[ -z "$document" ]]; then
      printf 'Write the dossier for attempt %s to %s before stopping; PASS or FAIL.\n' "$id" "$dossier"
      return 0
    fi
    if jq -e 'any(.findings[]?; startswith("unchecked:"))' <<<"$document" >/dev/null; then
      printf 'Time remains: run each unchecked check, then rewrite the dossier at %s.\n' "$dossier"
      return 0
    fi
  fi
  if [[ -n "$document" ]] \
      && audit_reflection_gate "$context" record "$id" "$document" >/dev/null 2>&1; then
    rm -f "$link"
    return 0
  fi
  audit_reflection_gate "$context" error "$id" \
    '"Auditor stopped without a bound, recordable dossier"' >/dev/null || return 2
  rm -f "$link"
}
