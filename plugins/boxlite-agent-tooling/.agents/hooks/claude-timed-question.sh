#!/usr/bin/env bash
# Capture managed AskUserQuestion replies at the host boundary, never from an option.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
fail() { printf 'claude-timed-question: %s\n' "$1" >&2; exit 2; }
for dependency in jq git perl date; do command -v "$dependency" >/dev/null || fail "missing $dependency"; done
payload="$(cat)"
[[ "$(jq -r '.tool_name // ""' <<<"$payload")" == AskUserQuestion ]] || exit 0
kind="$(jq -r '[.tool_input.questions[]?.question | select(type=="string") |
  if startswith("pr-size-exception:") then "pr-size" elif startswith("reviewed:") then "pr-review" else empty end][0] // ""' <<<"$payload")"
[[ -n "$kind" ]] || exit 0
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh"
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || fail 'cannot identify checkout'
state="$repo/.agents/state/$kind-request.json"
snapshot="$(verdict_audit_read_regular_state "$state" 16384 json)" || fail 'request state unavailable'
request="${snapshot#*$'\n'}"
id="$(jq -er .id <<<"$request")" || fail 'request id unavailable'
jq -e --arg repo "$repo" --arg head "$(git -C "$repo" rev-parse HEAD)" \
  --arg branch "$(git -C "$repo" branch --show-current)" --arg session "$(jq -r '.session_id // ""' <<<"$payload")" '
  .spec.binding | (.root // .repo) == $repo and .head == $head and .branch == $branch and .session == $session
' <<<"$request" >/dev/null || fail 'request no longer matches this session and diff'
question="$(timed_user_prompt question "$state" "$id")" || fail 'invalid request state'
jq -e --argjson question "$question" '
  if .hook_event_name == "PreToolUse" then .tool_input == $question
  else .tool_input.questions == $question.questions end' <<<"$payload" >/dev/null \
  || fail 'use the exact managed question; never provide answers in tool input'
tool_id="$(jq -er '.tool_use_id | select(type=="string")' <<<"$payload")" || fail 'missing tool call id'
case "$(jq -r .hook_event_name <<<"$payload")" in
  PreToolUse)
    if [[ ! "${CLAUDE_AFK_TIMEOUT_MS:-}" =~ ^[1-9][0-9]{0,5}$ ]] || (( CLAUDE_AFK_TIMEOUT_MS > 180000 )); then
      fail 'native timeout unavailable; launch with scripts/claude-with-timed-prompts.sh'
    fi
    timed_user_prompt present "$state" "$id" "$tool_id" >/dev/null || fail 'question expired or already asked' ;;
  PostToolUse)
    answer="$(jq -cer --arg key "$(jq -r '.questions[0].question' <<<"$question")" --arg id "$tool_id" '
      .tool_response | select(.afkTimeoutMs == null and .followUp != true) |
      ([.response,.annotations[$key].notes,.answers[$key]] |
       map(select(type=="string" and length>0)) | .[0]) |
      select(type=="string") | {tool_use_id:$id,answer:.}' <<<"$payload")" \
      || fail 'no typed reply; keep the request unapproved and follow its original deadline'
    request="$(timed_user_prompt native-reply "$state" "$id" "$answer")" \
      || fail 'no valid timely typed reply; never infer approval, follow the original deadline'
    if [[ "$kind" == pr-review ]]; then
      jq -c '{branch:.spec.binding.branch,head:.spec.binding.head,message:.response,request:.id}' <<<"$request" \
        | verdict_audit_write_atomic "$repo/.agents/state/pr-reviewed.json" || fail 'could not record review acknowledgment'
    fi ;;
  *) fail 'unsupported hook event' ;;
esac
