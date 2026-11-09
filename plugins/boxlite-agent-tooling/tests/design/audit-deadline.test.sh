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
stop() { # stop_hook_active -> SubagentStop payload from the design auditor
  jq -nc --argjson active "$1" --arg cwd "$scratch/repo" \
    '{hook_event_name:"SubagentStop", agent_type:"boxlite-agent-tooling:design-auditor",
      stop_hook_active:$active, cwd:$cwd}'
}
task() { # seconds until the deadline, recorded state hash
  jq -nc --argjson deadline "$(( $(date +%s) + $1 ))" --arg state "${2:-}" \
    '{url:"u", content_sha256:"c", deadline:$deadline, state_hash:$state}' > "$task_file"
}
auditor=boxlite-agent-tooling:design-auditor
verdict="bash \"$plugin/scripts/design-doc.sh\" verdict <<<'{}'"
ok 'no task: the auditor works freely' "$(call "$(tool "$auditor" Read '')")" '0:'
task 600
ok 'before the deadline: tool calls pass' "$(call "$(tool "$auditor" WebSearch '')")" '0:'
task -1
result="$(call "$(tool "$auditor" Read '')")"
ok 'past the deadline: a read is answered' "${result%%:*}" 2
has 'the answer says record now' "$result" 'Deadline passed: record your verdict now'
ok 'past the deadline: the verdict command passes' "$(call "$(tool "$auditor" Bash "$verdict")")" '0:'
ok 'past the deadline: a research command is answered' \
  "$(call "$(tool design-auditor Bash 'bash design-doc.sh research < verdict.json')" | cut -c1-2)" '2:'
ok 'past the deadline: other commands are answered' "$(call "$(tool "$auditor" Bash 'rg -n claim .')" | cut -c1-2)" '2:'
ok 'other agents never wait on it' "$(call "$(tool general-purpose Read '')")" '0:'
ok 'the main agent never waits on it' "$(call "$(tool '' Read '')")" '0:'
result="$(call "$(stop false)")"
ok 'a verdict-less stop past the deadline exits cleanly' "${result%%:*}" 0
has 'a verdict-less stop past the deadline is blocked' "$result" '"decision":"block"' 'Deadline passed'
task 600
result="$(call "$(stop false)")"
ok 'a verdict-less stop before the deadline exits cleanly' "${result%%:*}" 0
has 'a verdict-less stop before the deadline is blocked' "$result" '"decision":"block"' \
  'Record your verdict before stopping'
ok 'a resumed stop is never blocked twice' "$(call "$(stop true)")" '0:'
printf '{"verdict":"PASS"}\n' > "$git_dir/agent-tooling-design-audit.json"
ok 'a stop after the verdict passes' "$(call "$(stop false)")" '0:'
if [[ -e "$task_file" ]]; then ok 'the recorded audit closes its task' open closed
else ok 'the recorded audit closes its task' closed closed; fi
# Codex reports spawned agents as `default` and names them in the subagent transcript.
codex_payload() { # event, agent path, transcript session -> payload from a Codex subagent
  local transcript="$scratch/codex-$RANDOM.jsonl"
  jq -nc --arg parent "$3" --arg path "$2" \
    '{type:"session_meta",payload:{id:"codex-agent-1",session_id:$parent,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$parent,depth:1,agent_path:$path}}}}}' > "$transcript"
  jq -nc --arg event "$1" --arg transcript "$transcript" --arg cwd "$scratch/repo" \
    '{hook_event_name:$event, session_id:"codex-session", agent_id:"codex-agent-1",
      agent_type:"default", tool_name:"Read", tool_input:{}, cwd:$cwd, stop_hook_active:false}
     + if $event == "SubagentStop" then {agent_transcript_path:$transcript}
       else {transcript_path:$transcript} end'
}
rm -f "$git_dir/agent-tooling-design-audit.json"
task -1
ok 'Codex: the design auditor is answered past the deadline' \
  "$(call "$(codex_payload PreToolUse /root/design_auditor codex-session)" | cut -c1-2)" '2:'
ok 'Codex: another subagent works freely' "$(call "$(codex_payload PreToolUse /root/worker codex-session)")" '0:'
ok 'Codex: a transcript bound to another session is not trusted' \
  "$(call "$(codex_payload PreToolUse /root/design_auditor other-session)")" '0:'
has 'Codex: a verdict-less stop is blocked' "$(call "$(codex_payload SubagentStop /root/design_auditor codex-session)")" \
  '"decision":"block"' 'Deadline passed'
# The design advisor works to its own deadline; its record step is advice (design #335).
advice_task_file="$git_dir/agent-tooling-design-advice-task.json"
advice_task() { # seconds until the deadline
  jq -nc --argjson deadline "$(( $(date +%s) + $1 ))" \
    '{url:"u", content_sha256:"c", deadline:$deadline, state_hash:""}' > "$advice_task_file"
}
advisor=boxlite-agent-tooling:design-advisor
advisor_stop() {
  jq -nc --arg cwd "$scratch/repo" '{hook_event_name:"SubagentStop",
    agent_type:"boxlite-agent-tooling:design-advisor", stop_hook_active:false, cwd:$cwd}'
}
ok 'advisor: no task, it works freely' "$(call "$(tool "$advisor" Read '')")" '0:'
advice_task -1
result="$(call "$(tool "$advisor" Read '')")"
ok 'advisor: past the deadline a read is answered' "${result%%:*}" 2
has 'advisor: the answer names the advice step' "$result" 'Deadline passed' 'scripts/design-doc.sh" advice'
ok 'advisor: past the deadline the advice command passes' \
  "$(call "$(tool "$advisor" Bash "bash \"$plugin/scripts/design-doc.sh\" advice <<<'{}'")")" '0:'
ok 'advisor: past the deadline a verdict command is answered' \
  "$(call "$(tool "$advisor" Bash "bash design-doc.sh verdict <<<'{}'")" | cut -c1-2)" '2:'
has 'advisor: an advice-less stop is blocked' "$(call "$(advisor_stop)")" '"decision":"block"' 'Deadline passed'
printf '{"advice":[]}\n' > "$git_dir/agent-tooling-design-advice.json"
ok 'advisor: a stop after its advice passes' "$(call "$(advisor_stop)")" '0:'
rm -f "$git_dir/agent-tooling-design-advice.json"
advice_task -1
ok 'Codex: the design advisor is answered past the deadline' \
  "$(call "$(codex_payload PreToolUse /root/design_advisor codex-session)" | cut -c1-2)" '2:'
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
# The gate's side: one deadline per design content, from DESIGN_AUDITOR_TIMEOUT.
lib() { # environment assignments..., -- , design_doc_audit_task arguments
  env "$@" bash -c 'for lib in verdict-audit-state reply-summary concise-writing subagent design-doc; do
      source "'"$plugin"'/.agents/lib/$lib.sh" || exit 2; done
    design_doc_audit_task "'"$scratch/repo"'" url digest'
}
first="$(lib DESIGN_AUDITOR_TIMEOUT=900)"
now="$(date +%s)"
(( first >= now + 898 && first <= now + 900 )); ok 'the deadline is 900 seconds out' "$?" 0
ok 'another edit attempt keeps the deadline' "$(lib DESIGN_AUDITOR_TIMEOUT=60)" "$first"
jq '.deadline = 1' "$task_file" > "$scratch/expired" && mv "$scratch/expired" "$task_file"
second="$(lib DESIGN_AUDITOR_TIMEOUT=60)"
ok 'repeated preflight preserves an expired unfinished deadline' "$second" 1
lib DESIGN_AUDITOR_TIMEOUT=soon >/dev/null 2>&1; ok 'a malformed timeout is refused' "$?" 1
for manifest in hooks.json codex-hooks.json; do
  ok "$manifest wires the deadline to tool calls and stops" "$(jq '[(.hooks.PreToolUse[]
    | select(.matcher as $m | "Read" | test($m))), .hooks.SubagentStop[] | .hooks[].command
    | select(contains("audit-deadline.sh"))] | length' "$plugin/hooks/$manifest")" 2
done
# Every tool a timed agent's spec lists must reach the deadline hook (designs #328, #335).
for spec in design-auditor design-advisor commit-push-auditor verdict-auditor; do
  tools="$(sed -n 's/^tools: //p' "$plugin/.claude/agents/$spec.md" | tr -d ' ')"
  for manifest in hooks.json codex-hooks.json generic-hooks.json; do
    missed="$(jq -r --arg tools "$tools" '
      [.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("audit-deadline.sh")))
       | .matcher] as $matchers
      | [$tools | split(",")[] | select(. as $tool | any($matchers[]; . as $re | $tool | test($re)) | not)]
      | join(",")' "$plugin/hooks/$manifest")"
    ok "$spec tools reach the deadline hook in $manifest" "${missed:-none}" none
  done
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
