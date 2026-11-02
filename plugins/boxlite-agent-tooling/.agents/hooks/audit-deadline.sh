#!/usr/bin/env bash
# PreToolUse and SubagentStop: the timed-subagent deadline for native auditors (#309, #328).
# Past its deadline, every tool call except the auditor's record step is answered "record
# your verdict now". This hook blocks one verdict-less design-auditor stop; auditor-control.sh
# closes commit/push stops with the same rule (subagent_timed_stop). Other agents pass.
set -uo pipefail
payload="$(head -c 1048577)"
[[ "$payload" == *auditor* || "$payload" == *'"default"'* ]] || exit 0
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)" || exit 0
plugin_root="${lib%/.agents/lib}"
for name in subagent subagent-identity verdict-audit-state auditor-override-state commit-push-stop; do
  # shellcheck source=/dev/null
  source "$lib/$name.sh" || exit 0
done
auditor="$(subagent_identity_auditor "$payload")" || exit 0
event="$(jq -r '.hook_event_name // ""' <<<"$payload")"
cwd="$(jq -r '.cwd // "" | strings' <<<"$payload")"
case "$auditor" in
  design-auditor)
    git_dir="$(git -C "${cwd:-$PWD}" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
    task_path="$git_dir/agent-tooling-design-audit-task.json"
    [[ -f "$task_path" && ! -L "$task_path" ]] || exit 0
    task="$(jq -ce 'select((.deadline | type) == "number" and (.state_hash | type) == "string")' \
      "$task_path" 2>/dev/null)" || exit 0
    allow_command='design-doc\.sh"?[[:space:]]+(verdict|research)([[:space:]]|$)'
    allow_path=""
    record="Pipe {content_sha256, verdict, findings, advisories} to bash \"$plugin_root/scripts/design-doc.sh\" verdict; checks you have not run are high: unchecked." ;;
  commit-push-auditor)
    [[ "$event" == PreToolUse ]] || exit 0
    repo="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 0
    task="$(verdict_audit_read_single_record \
      "$(auditor_override_control_dir "$repo")/audit-task.$scope.commit-push-auditor.json" 2>/dev/null \
      | jq -ce 'select((.deadline | type) == "number" and (.dossier_path | type) == "string"
                       and (.attempt_id | type) == "string")' 2>/dev/null)" || exit 0
    allow_command=""
    allow_path="$(jq -r .dossier_path <<<"$task")"
    record="$(commit_push_stop_record "$(jq -r .attempt_id <<<"$task")" "$allow_path")" ;;
  *) exit 0 ;;
esac
deadline="$(jq -r .deadline <<<"$task")"
case "$event" in
  PreToolUse)
    (( $(date +%s) >= deadline )) || exit 0
    tool="$(jq -r '.tool_name // ""' <<<"$payload")"
    command="$(jq -r '.tool_input.command // "" | strings' <<<"$payload")"
    if [[ -n "$allow_command" && "$tool" == Bash && "$command" =~ $allow_command ]]; then
      exit 0
    fi
    if [[ -n "$allow_path" ]]; then
      file="$(jq -r '.tool_input.file_path // "" | strings' <<<"$payload")"
      [[ "$file" != "$allow_path" && "$command" != *"$allow_path"* ]] || exit 0
    fi
    subagent_timed_message passed "$record" >&2
    exit 2 ;;
  SubagentStop)
    resumed="$(jq -r '.stop_hook_active == true' <<<"$payload")"
    [[ "$resumed" != true ]] || exit 0
    state_path="$git_dir/agent-tooling-design-audit.json"
    current=""
    [[ ! -f "$state_path" ]] \
      || current="$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$state_path")"
    # A changed audit state means this auditor recorded its verdict.
    if [[ "$current" != "$(jq -r .state_hash <<<"$task")" ]]; then
      rm -f "$task_path"
      exit 0
    fi
    reason="$(subagent_timed_stop "$deadline" missing "$resumed" "$record")"
    [[ -z "$reason" ]] || jq -nc --arg reason "$reason" '{decision:"block",reason:$reason}' ;;
esac
exit 0
