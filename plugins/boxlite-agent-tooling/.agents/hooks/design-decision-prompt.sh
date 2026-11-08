#!/usr/bin/env bash
# Records a typed design decision or one correlated Codex question reply (design #372).
# The prompt hook calls this after filtering internal wakes; with the managed question's
# hook, it is the only writer of an accepted research decision. Always exits 0.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
say() { printf 'design-decision: %s\n' "$1"; exit 0; }
for dependency in jq git perl date; do command -v "$dependency" >/dev/null 2>&1 || say "missing $dependency; nothing recorded"; done
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || say 'prompt exceeds inspection limit; nothing recorded'
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/user-question.sh
source "$plugin/.agents/lib/user-question.sh" || say 'question library unavailable; nothing recorded'
reply="$(user_question reply "$plugin" "$payload" 2>/dev/null | jq -ce '
  if has("item") then
    .item | select(keys == ["answer","question","questionItemId"]) |
    select(all(.answer,.question,.questionItemId; type == "string" and length > 0 and utf8bytelength <= 4096)) |
    select(.answer | explode | all(. >= 32 and . != 127)) |
    {line:.answer, question:.question}
  else {line:.first_line} end' 2>/dev/null)" || say 'unreadable prompt; nothing recorded'
line="$(jq -r .line <<<"$reply")"
[[ "$line" == design-decision:* ]] || exit 0
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || say 'no repository; nothing recorded'
state="$repo/.agents/state/design-decision-request.json"
[[ -e "$state" || -L "$state" ]] || say 'no research decision is pending; nothing recorded'
# The item ID is opaque host metadata. The exact question carries our request ID.
if jq -e 'has("question")' <<<"$reply" >/dev/null; then
  # shellcheck source=../lib/hook-host.sh
  source "$plugin/.agents/lib/hook-host.sh" || say 'host unavailable; nothing recorded'
  [[ "$(hook_host_kind)" == codex ]] || say 'question reply is not from the Codex route; nothing recorded'
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh" || say 'state library unavailable; nothing recorded'
# shellcheck source=../lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh" || say 'decision library unavailable; nothing recorded'
snapshot="$(verdict_audit_read_regular_state "$state" 16384 json)" || say 'request state unreadable; nothing recorded'
request="${snapshot#*$'\n'}"
jq -e --arg repo "$repo" --arg branch "$(git -C "$repo" branch --show-current 2>/dev/null)" \
  --arg head "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" \
  --arg session "$(jq -r '.session_id // "" | strings' <<<"$payload")" \
  '.spec.prefix == "design-decision:" and (.spec.binding | .root == $repo
    and .branch == $branch and .head == $head and .session == $session)' <<<"$request" >/dev/null 2>&1 \
  || say 'the pending decision belongs to another session, branch, or HEAD; nothing recorded'
if jq -e 'has("question")' <<<"$reply" >/dev/null; then
  question="$(_timed_user_prompt_question "$request")" || say 'question unavailable; nothing recorded'
  jq -e --argjson question "$question" '.question == $question.questions[0].question' \
    <<<"$reply" >/dev/null || say 'question does not match the pending request; nothing recorded'
fi
timed_user_prompt prompt-reply "$state" "$(jq -r .id <<<"$request")" "$line" >/dev/null 2>&1 \
  || say "use the first line \"$(user_question design-format "$plugin")\" while a decision is open; nothing recorded"
say "recorded \"$line\"; the next edit attempt applies it"
