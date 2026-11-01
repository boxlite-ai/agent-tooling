#!/usr/bin/env bash
# PreToolUse and SubagentStop: time the design auditor like the other audits (design #309).
# Past its deadline, every tool call except recording the verdict is answered with
# "record your verdict now", and one stop without a verdict is blocked. Other agents pass.
# Claude Code names the auditor in agent_type; Codex reports `default` and names it in
# the subagent transcript's spawn metadata (.agents/lib/subagent-identity.sh).
set -uo pipefail
payload="$(head -c 1048577)"
[[ "$payload" == *design-auditor* || "$payload" == *'"default"'* ]] || exit 0
agent="$(jq -r '.agent_type // "" | strings' <<<"$payload" 2>/dev/null)" || exit 0
case "$agent" in
  design-auditor|boxlite-agent-tooling:design-auditor) ;;
  default)
    # shellcheck source=../lib/subagent-identity.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)/subagent-identity.sh" || exit 0
    transcript="$(jq -r 'if (.agent_transcript_path | type) == "string" then .agent_transcript_path
      elif (.transcript_path | type) == "string" then .transcript_path else "" end' <<<"$payload")"
    [[ -n "$transcript" ]] || exit 0
    agent="$(subagent_identity_codex_path "$payload" "$transcript")" || exit 0
    case "${agent##*/}" in
      design-auditor|design-auditor_*|design_auditor|design_auditor_*) ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
cwd="$(jq -r '.cwd // "" | strings' <<<"$payload")"
git_dir="$(git -C "${cwd:-$PWD}" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
task_path="$git_dir/agent-tooling-design-audit-task.json"
[[ -f "$task_path" && ! -L "$task_path" ]] || exit 0
task="$(jq -ce 'select((.deadline | type) == "number" and (.state_hash | type) == "string")' \
  "$task_path" 2>/dev/null)" || exit 0
deadline="$(jq -r .deadline <<<"$task")"
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
record="Pipe {content_sha256, verdict, findings, advisories} to bash \"$plugin_root/scripts/design-doc.sh\" verdict; checks you have not run are high: unchecked."
now="$(date +%s)"
case "$(jq -r '.hook_event_name // ""' <<<"$payload")" in
  PreToolUse)
    (( now >= deadline )) || exit 0
    command="$(jq -r '.tool_input.command // "" | strings' <<<"$payload")"
    pattern='design-doc\.sh"?[[:space:]]+(verdict|research)([[:space:]]|$)'
    if [[ "$(jq -r '.tool_name // ""' <<<"$payload")" == Bash && "$command" =~ $pattern ]]; then
      exit 0
    fi
    printf 'Deadline passed: record your verdict now. %s\n' "$record" >&2
    exit 2 ;;
  SubagentStop)
    [[ "$(jq -r '.stop_hook_active == true' <<<"$payload")" != true ]] || exit 0
    state="$git_dir/agent-tooling-design-audit.json"
    current=""
    [[ ! -f "$state" ]] || current="$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$state")"
    # A changed audit state means this auditor recorded its verdict.
    if [[ "$current" != "$(jq -r .state_hash <<<"$task")" ]]; then
      rm -f "$task_path"
      exit 0
    fi
    reason="Record your verdict before stopping. $record"
    (( now < deadline )) || reason="Deadline passed: record your verdict now. $record"
    jq -nc --arg reason "$reason" '{decision:"block",reason:$reason}' ;;
esac
exit 0
