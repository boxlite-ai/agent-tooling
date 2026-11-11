#!/usr/bin/env bash
# Native dossier-worker ownership and deadlines. Design workers use their own supervisor.
set -uo pipefail
payload="$(head -c 1048577)"
[[ "$payload" == *auditor* || "$payload" == *advisor* || "$payload" == *'"default"'* ]] || exit 0
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)" || exit 0
plugin_root="${lib%/.agents/lib}"
publish_start() { # repository; the existing lifecycle owner serializes this transition
  if ! CLAUDE_PROJECT_DIR="$1" bash "$plugin_root/.agents/hooks/auditor-control.sh" \
      publish-start <<< "$payload"; then
    printf 'audit-deadline: native auditor ownership could not be published\n' >&2
    exit 2
  fi
  exit 0
}
for name in subagent subagent-identity verdict-audit-state auditor-override-state commit-push-stop; do
  # shellcheck source=/dev/null
  source "$lib/$name.sh" || exit 0
done
auditor="$(subagent_identity_auditor "$payload")" || exit 0
event="$(jq -r '.hook_event_name // ""' <<<"$payload")"
cwd="$(jq -r '.cwd // "" | strings' <<<"$payload")"
case "$auditor" in
  design-auditor|design-advisor) exit 0 ;; # Owned design workers have independent supervisors.
  commit-push-auditor)
    [[ "$event" == PreToolUse || "$event" == SubagentStart ]] || exit 0
    repo="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 0
    task="$(verdict_audit_read_single_record \
      "$(auditor_override_control_dir "$repo")/audit-task.$scope.commit-push-auditor.json" 2>/dev/null \
      | jq -ce 'select((.deadline | type) == "number" and (.dossier_path | type) == "string"
                       and (.attempt_id | type) == "string")' 2>/dev/null)" || exit 0
    [[ "$event" != SubagentStart ]] || publish_start "$repo"
    allow_path="$(jq -r .dossier_path <<<"$task")"
    record="$(audit_attempt_stop_record "$(jq -r .attempt_id <<<"$task")" "$allow_path")" ;;
  verdict-auditor)
    repo="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    repo="$(cd "$repo" && pwd -P)" || exit 0
    scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 0
    for name in audit-request audit-reflection audit-reflection-gate verdict-audit-task; do
      # shellcheck source=/dev/null
      source "$lib/$name.sh" || exit 2
    done
    if [[ "$event" == SubagentStop ]]; then
      reason="$(audit_attempt_stop_check "$repo" "$scope" \
        "$(jq -r '.stop_hook_active == true' <<<"$payload")" verdict-auditor \
        "$(jq -r '.agent_id // ""' <<<"$payload")")" || exit 2
      [[ -z "$reason" ]] || jq -nc --arg reason "$reason" '{decision:"block",reason:$reason}'
      exit 0
    fi
    status=0
    task="$(verdict_audit_task_prepare "$repo" "$scope" \
      "$(jq -r '.agent_id // ""' <<<"$payload")" "$event")" || status=$?
    (( status != 1 )) || exit 0  # No live request grants no deadline authority.
    (( status == 0 )) || { printf 'audit-deadline: native verdict task could not be prepared\n' >&2; exit 2; }
    [[ "$event" != SubagentStart ]] || publish_start "$repo"
    allow_path="$(jq -r .dossier_path <<<"$task")"
    record="$(audit_attempt_stop_record "$(jq -r .attempt_id <<<"$task")" "$allow_path")" ;;
  *) exit 0 ;;
esac
deadline="$(jq -r .deadline <<<"$task")"
case "$event" in
  PreToolUse)
    (( $(date +%s) >= deadline )) || exit 0
    tool="$(jq -r '.tool_name // ""' <<<"$payload")"
    [[ "$tool" != TaskStop ]] || exit 0
    command="$(jq -r '.tool_input.command // "" | strings' <<<"$payload")"
    if [[ -n "$allow_path" ]]; then
      file="$(jq -r '.tool_input.file_path // "" | strings' <<<"$payload")"
      [[ "$file" != "$allow_path" && "$command" != *"$allow_path"* ]] || exit 0
    fi
    subagent_timed_message passed "$record" >&2
    exit 2 ;;

esac
exit 0
