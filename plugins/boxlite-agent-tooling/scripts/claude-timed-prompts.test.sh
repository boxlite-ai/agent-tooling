#!/usr/bin/env bash
# shellcheck disable=SC2016 # bash -c fixtures expand these literals in the child.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
cd "$scratch/repo"
repo="$(pwd -P)"
export CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_AFK_TIMEOUT_MS=180000
export BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1
unset PLUGIN_ROOT
mkdir -p .agents/state "$scratch/bin"
cli="$plugin/scripts/timed-user-prompt.sh"
state="$repo/.agents/state/pr-size-request.json"
spec="$(jq -nc --arg root "$repo" --arg head "$(git rev-parse HEAD)" \
  '{binding:{root:$root,head:$head,branch:"feature",session:"native"},prefix:"pr-size-exception:",fallback:"split",minimum_words:12}')"
bash "$cli" request "$state" "$spec" >/dev/null
# Requests persisted before the native adapter retain their identity and deadline.
prior_id="$(jq -r .id "$state")"
prior_deadline="$(jq -r .deadline "$state")"
jq 'del(.question_tool_id)' "$state" > "$scratch/prior-request"
mv "$scratch/prior-request" "$state"
prior="$(bash "$cli" status "$state" "$prior_id")"
jq -e --arg id "$prior_id" --argjson deadline "$prior_deadline" \
  '.id==$id and .deadline==$deadline and .question_tool_id==""' <<<"$prior" >/dev/null
out="$(printf '%s' '{"session_id":"native"}' | bash "$plugin/scripts/continue-timed-prompts.sh")"
[[ "$out" == *AskUserQuestion* ]] || { printf 'FAIL: Claude timed prompt did not select AskUserQuestion\n' >&2; exit 1; }

hook="$plugin/.agents/hooks/claude-timed-question.sh"
id="$(jq -r .id "$state")"
question="$(bash "$cli" question "$state" "$id")"
key="$(jq -r '.questions[0].question' <<<"$question")"
tool_id=native-1
call_hook() {
  jq -nc --arg event "$1" --arg tool "$tool_id" --argjson input "$question" --argjson response "${2:-null}" \
    '{hook_event_name:$event,tool_name:"AskUserQuestion",session_id:"native",tool_use_id:$tool,tool_input:$input,tool_response:$response}' \
    | bash "$hook"
}
reject() { if "$@" >"$scratch/out" 2>"$scratch/err"; then printf 'FAIL: unexpected approval\n' >&2; exit 1; fi; }
reply() { jq -nc --arg key "$key" --arg value "$1" '{answers:{($key):$value}}'; }
deadline="$(jq -r .deadline "$state")"
saved_question="$question"
question="$(jq '.answers={}' <<<"$question")"
reject call_hook PreToolUse
question="$saved_question"
reject env -u BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS bash -c 'printf "%s" "$1" | bash "$2"' _ \
  "$(jq -nc --argjson input "$question" '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",session_id:"native",tool_use_id:"remote-session",tool_input:$input}')" "$hook"
jq -e --argjson deadline "$deadline" '.question_tool_id=="" and .status=="pending" and .deadline==$deadline' "$state" >/dev/null
[[ ! -e .agents/state/pr-reviewed.json ]]
reject env -u CLAUDE_AFK_TIMEOUT_MS bash -c 'printf "%s" "$1" | bash "$2"' _ \
  "$(jq -nc --argjson input "$question" '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",session_id:"native",tool_use_id:"missing-timeout",tool_input:$input}')" "$hook"
call_hook PreToolUse
tool_id=native-2
reject call_hook PreToolUse
tool_id=native-1
reject call_hook PostToolUse "$(reply 'Split work')"
reason='pr-size-exception: The generated dependency lockfile must land with its manifest because either half leaves dependency resolution inconsistent.'
reject call_hook PostToolUse "$(reply "$reason" | jq '.afkTimeoutMs=180000')"
reject call_hook PostToolUse "$(reply "$reason" | jq '.followUp=true')"
reject bash "$cli" respond "$state" "$id" "$reason"
[[ "$(jq -r .status "$state")" == pending ]]
[[ "$(jq -r .deadline "$state")" == "$deadline" ]]
tool_id=unrelated-call
reject call_hook PostToolUse "$(reply "$reason")"
tool_id=native-1
call_hook PostToolUse "$(reply "$reason")"
[[ "$(jq -r .response "$state")" == "$reason" ]]
reject call_hook PostToolUse "$(reply "$reason")"

# A native review response produces the marker consumed by the existing PR gate.
state="$repo/.agents/state/pr-review-request.json"
spec="$(jq '.prefix="reviewed:" | .fallback="keep-draft" | .minimum_words=1 |
  .binding.repo=.binding.root | del(.binding.root)' <<<"$spec")"
bash "$cli" request "$state" "$spec" >/dev/null
id="$(jq -r .id "$state")"
question="$(bash "$cli" question "$state" "$id")"
key="$(jq -r '.questions[0].question' <<<"$question")"
call_hook PreToolUse
call_hook PostToolUse '{"answers":{},"response":"reviewed: deadlines bind the typed reply to the presented diff"}'
jq -e --arg id "$id" '.request==$id and (.message|startswith("reviewed: deadlines"))' .agents/state/pr-reviewed.json >/dev/null
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == repo ]]; then
  printf '%s' '{"nameWithOwner":"example/repo","defaultBranchRef":{"name":"main"}}'
elif [[ "$*" == 'api --hostname github.com markdown -f mode=gfm -f text='* ]]; then
  [[ "${8#text=}" == *https://github.com/example/repo/issues/123* ]] || exit 2
  printf '<h2>How it works</h2><p>The handler retries a failed call once.</p><a href="https://github.com/example/repo/issues/123">Design</a>'
elif [[ "$1" == api ]]; then
  printf '{"html_url":"https://github.com/example/repo/issues/123","body":"## TL;DR\\n\\nDesign and validation."}'
else
  jq -nc --arg head "$(git rev-parse HEAD)" \
    '{baseRefOid:$head,headRefOid:$head,headRefName:"feature",additions:1,deletions:0,body:"## TL;DR\n\nFixture summary.\n\n## How it works\n\nRetry failed calls once.\n\nhttps://github.com/example/repo/issues/123"}'
fi
GH
chmod +x "$scratch/bin/gh"
PATH="$scratch/bin:$PATH" bash "$plugin/scripts/design-doc.sh" bind https://github.com/example/repo/issues/123 >/dev/null
out="$(printf '%s' '{"session_id":"native","tool_input":{"command":"gh pr ready"}}' \
  | PATH="$scratch/bin:$PATH" bash "$plugin/.agents/hooks/preflight-pr-review.sh")"
[[ -z "$out" && "$(jq -r .status "$state")" == consumed ]]
bash "$cli" request "$state" "$spec" >/dev/null
id="$(jq -r .id "$state")"
question="$(bash "$cli" question "$state" "$id")"
key="$(jq -r '.questions[0].question' <<<"$question")"
call_hook PreToolUse
jq '.created_at-=181 | .deadline-=181' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
reject call_hook PostToolUse "$(reply 'reviewed: late response')"
[[ "$(jq -r .id "$state")" == "$id" ]]

# A first real PR denial carries a bounded native question, not only the Stop path.
rm "$state"
out="$(printf '%s' '{"session_id":"native","tool_input":{"command":"gh pr ready"}}' \
  | PATH="$scratch/bin:$PATH" bash "$plugin/.agents/hooks/preflight-pr-review.sh")"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("AskUserQuestion") and utf8bytelength<=1200)' <<<"$out" >/dev/null

# Routing is host-scoped; Codex keeps non-blocking input and missing setup avoids a modal.
routing="$repo/.agents/state/routing.json"
bash "$cli" request "$routing" "$spec" >/dev/null
out="$(PLUGIN_ROOT="$plugin" env -u CLAUDE_PLUGIN_ROOT bash -c 'source "$1/.agents/lib/subagent.sh"; source "$1/.agents/lib/timed-user-prompt.sh"; timed_user_prompt_instruction "$1" "$(cat "$2")"' _ "$plugin" "$routing")"
[[ "$out" == *request_user_input_async* && "$out" != *AskUserQuestion* ]]
out="$(env -u CLAUDE_AFK_TIMEOUT_MS bash -c 'source "$1/.agents/lib/subagent.sh"; source "$1/.agents/lib/timed-user-prompt.sh"; timed_user_prompt_instruction "$1" "$(cat "$2")"' _ "$plugin" "$routing")"
[[ "$out" == *'plain text'* && "$out" != *'Call AskUserQuestion'* ]]
cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '%s\n' "${CLAUDE_TEST_VERSION:-2.1.278}"; exit 0; fi
printf '%s\n' "$CLAUDE_AFK_TIMEOUT_MS" "$@"
CLAUDE
chmod +x "$scratch/bin/claude"
out="$(PATH="$scratch/bin:$PATH" bash "$plugin/scripts/claude-with-timed-prompts.sh" --resume 'session with spaces')"
[[ "$out" == $'180000\n--settings\n{"remoteControlAtStartup":false,"disableRemoteControl":true}\n--resume\nsession with spaces\n--plugin-dir\n'"$plugin" ]]
reject env PATH="$scratch/bin:$PATH" CLAUDE_TEST_VERSION=2.1.197 bash "$plugin/scripts/claude-with-timed-prompts.sh"
printf 'Claude timed prompts: host route, native reply, timeout, replay, review marker, and launcher passed\n'
