#!/usr/bin/env bash
# Design-audit deadline (design #309): host payloads cross the real hook and library.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
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
ok 'past the deadline: the research alias passes' \
  "$(call "$(tool design-auditor Bash 'bash design-doc.sh research < verdict.json')")" '0:'
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
# The gate's side: one deadline per design content, from DESIGN_AUDITOR_TIMEOUT.
lib() { # environment assignments..., -- , design_doc_audit_task arguments
  env "$@" bash -c 'for lib in verdict-audit-state reply-summary concise-writing design-doc; do
      source "'"$plugin"'/.agents/lib/$lib.sh" || exit 2; done
    design_doc_audit_task "'"$scratch/repo"'" url digest'
}
first="$(lib DESIGN_AUDITOR_TIMEOUT=900)"
now="$(date +%s)"
(( first >= now + 898 && first <= now + 900 )); ok 'the deadline is 900 seconds out' "$?" 0
ok 'another edit attempt keeps the deadline' "$(lib DESIGN_AUDITOR_TIMEOUT=60)" "$first"
jq '.deadline = 1' "$task_file" > "$scratch/expired" && mv "$scratch/expired" "$task_file"
second="$(lib DESIGN_AUDITOR_TIMEOUT=60)"
(( second >= now + 58 && second <= now + 61 )); ok 'an expired deadline starts a new audit' "$?" 0
lib DESIGN_AUDITOR_TIMEOUT=soon >/dev/null 2>&1; ok 'a malformed timeout is refused' "$?" 1
for manifest in hooks.json codex-hooks.json; do
  ok "$manifest wires the deadline to tool calls and stops" "$(jq '[(.hooks.PreToolUse[]
    | select(.matcher as $m | "Read" | test($m))), .hooks.SubagentStop[] | .hooks[].command
    | select(contains("audit-deadline.sh"))] | length' "$plugin/hooks/$manifest")" 2
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
