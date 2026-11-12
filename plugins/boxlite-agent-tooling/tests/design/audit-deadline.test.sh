#!/usr/bin/env bash
# Timed-subagent deadline (designs #309, #328): host payloads cross the real hook and libraries.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
hook="$plugin/.agents/hooks/audit-deadline.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/repo"
git_dir="$(git -C "$scratch/repo" rev-parse --absolute-git-dir)"
task_file="$git_dir/agent-tooling-design-audit-task.json"
pass=0 fail=0
ok() { # description, observed, wanted
  if [[ "$2" == "$3" ]]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s: got %s, wanted %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
has() { # description, text, substrings it must contain
  local description="$1" text="$2" part
  shift 2
  for part in "$@"; do
    [[ "$text" == *"$part"* ]] || { ok "$description" "$text" "text containing $part"; return; }
  done
  ok "$description" yes yes
}
call() { # payload JSON -> "<exit status>:<stdout><stderr>"
  local status=0 output
  output="$(bash "$hook" <<<"$1" 2>&1)" || status=$?
  printf '%s:%s' "$status" "$output"
}
tool() { # agent type, tool, command -> PreToolUse payload
  jq -nc --arg agent "$1" --arg tool "$2" --arg command "$3" --arg cwd "$scratch/repo" \
    '{hook_event_name:"PreToolUse", tool_name:$tool, tool_input:{command:$command}, cwd:$cwd}
     + if $agent == "" then {} else {agent_type:$agent} end'
}
# Native design completion cannot publish; design-worker.test.sh owns deadline coverage.
for agent in design-auditor design-advisor; do
  ok "$agent has no native publication deadline route" "$(call "$(tool "$agent" Read '')")" '0:'
done
# The commit/push auditor works to the deadline in its attempt link (design #328).
session=commit-session
scope="git-$(printf '%s' "$session" | git -C "$scratch/repo" hash-object --stdin)"
link="$scratch/repo/.agents/state/auditor-control/audit-task.$scope.commit-push-auditor.json"
dossier="$scratch/repo/.agents/state/last-audit.json"
mkdir -p "${link%/*}"
attempt() { # seconds until the deadline
  jq -nc --argjson deadline "$(( $(date +%s) + $1 ))" --arg dossier "$dossier" \
    '{context:{}, attempt_id:"attempt-1", dossier_path:$dossier, deadline:$deadline}' > "$link"
}
commit_tool() { # tool, input JSON -> PreToolUse payload from the commit/push auditor
  jq -nc --arg tool "$1" --argjson input "$2" --arg cwd "$scratch/repo" --arg session "$session" \
    '{hook_event_name:"PreToolUse", session_id:$session, tool_name:$tool, tool_input:$input,
      cwd:$cwd, agent_type:"boxlite-agent-tooling:commit-push-auditor"}'
}
ok 'commit/push: no link, the auditor works freely' \
  "$(call "$(commit_tool Read '{"file_path":"/etc/hosts"}')")" '0:'
attempt 600
ok 'commit/push: before the deadline a read passes' \
  "$(call "$(commit_tool Read '{"file_path":"/etc/hosts"}')")" '0:'
attempt -1
result="$(call "$(commit_tool Read '{"file_path":"/etc/hosts"}')")"
ok 'commit/push: past the deadline a read is answered' "${result%%:*}" 2
has 'commit/push: the answer names the attempt and dossier' "$result" \
  'Deadline passed: record your verdict now' 'attempt-1' "$dossier"
ok 'commit/push: past the deadline a dossier write passes' "$(call "$(commit_tool Write \
  "$(jq -nc --arg path "$dossier" '{file_path:$path, content:"{}"}')")")" '0:'
ok 'commit/push: past the deadline a shell write of the dossier passes' "$(call "$(commit_tool Bash \
  "$(jq -nc --arg command "jq -n {} > $dossier" '{command:$command}')")")" '0:'
ok 'commit/push: past the deadline other shell calls are answered' \
  "$(call "$(commit_tool Bash '{"command":"rg -n claim ."}')" | cut -c1-2)" '2:'
ok 'commit/push: its stops are left to auditor-control' "$(call "$(jq -nc --arg cwd "$scratch/repo" \
  --arg session "$session" '{hook_event_name:"SubagentStop", session_id:$session, cwd:$cwd,
  agent_type:"boxlite-agent-tooling:commit-push-auditor", stop_hook_active:false}')")" '0:'
codex_commit() { # agent path -> PreToolUse Read payload from a Codex subagent
  local transcript="$scratch/codex-commit-$RANDOM.jsonl"
  jq -nc --arg parent "$session" --arg path "$1" \
    '{type:"session_meta",payload:{id:"codex-commit-1",session_id:$parent,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$parent,depth:1,agent_path:$path}}}}}' > "$transcript"
  jq -nc --arg transcript "$transcript" --arg cwd "$scratch/repo" --arg session "$session" \
    '{hook_event_name:"PreToolUse", session_id:$session, agent_id:"codex-commit-1", agent_type:"default",
      tool_name:"Read", tool_input:{}, cwd:$cwd, transcript_path:$transcript}'
}
ok 'Codex: the commit/push auditor is answered past the deadline' \
  "$(call "$(codex_commit /root/commit_push_auditor)" | cut -c1-2)" '2:'
ok 'Codex: a verdict auditor without a deadline task works freely' \
  "$(call "$(codex_commit /root/verdict_auditor)")" '0:'
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
