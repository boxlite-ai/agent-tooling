#!/usr/bin/env bash
# Records the human's typed design decision. Always exits 0.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
say() { printf 'design-decision: %s\n' "$1"; exit 0; }
for dependency in jq git perl date; do command -v "$dependency" >/dev/null 2>&1 || say "missing $dependency; nothing recorded"; done
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || say 'prompt exceeds inspection limit; nothing recorded'
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/user-question.sh
source "$plugin/.agents/lib/user-question.sh" || say 'question library unavailable; nothing recorded'
reply="$(user_question reply "$plugin" "$payload" 2>/dev/null)" || say 'use a typed decision with its request ID; nothing recorded'
[[ "$(jq -r .prefix <<<"$reply")" == design-decision: ]] || exit 0
id="$(jq -er .id <<<"$reply")" || say 'request ID unavailable; nothing recorded'
line="$(jq -er .text <<<"$reply")" || say 'unreadable prompt; nothing recorded'
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || say 'no repository; nothing recorded'
state="$repo/.agents/state/design-decision-request.json"
[[ -e "$state" || -L "$state" ]] || say 'no research decision is pending; nothing recorded'
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh" || say 'state library unavailable; nothing recorded'
# shellcheck source=../lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh" || say 'decision library unavailable; nothing recorded'
request="$(timed_user_prompt_read "$state" 2>&1)" || say "$request; nothing recorded"
jq -e --arg id "$id" --arg repo "$repo" --arg branch "$(git -C "$repo" branch --show-current 2>/dev/null)" \
  --arg head "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" \
  --arg session "$(jq -r '.session_id // "" | strings' <<<"$payload")" \
  '.id == $id and .spec.prefix == "design-decision:" and (.spec.binding | .root == $repo
    and .branch == $branch and .head == $head and .session == $session)' <<<"$request" >/dev/null 2>&1 \
  || say 'the reply does not match the pending request, session, branch, or HEAD; nothing recorded'
timed_user_prompt prompt-reply "$state" "$id" "$line" >/dev/null 2>&1 \
  || say "use the first line \"$(user_question design-format "$plugin" "$id")\" while a decision is open; nothing recorded"
say "recorded \"$line\"; the next edit attempt applies it"
