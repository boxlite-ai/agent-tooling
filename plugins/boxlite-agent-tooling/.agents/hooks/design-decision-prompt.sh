#!/usr/bin/env bash
# Records a design decision the human typed as the first prompt line (design #309).
# The prompt hook calls this after filtering internal wakes; with the managed question's
# hook, it is the only writer of an accepted research decision. Always exits 0.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
say() { printf 'design-decision: %s\n' "$1"; exit 0; }
for dependency in jq git perl date; do command -v "$dependency" >/dev/null 2>&1 || say "missing $dependency; nothing recorded"; done
payload="$(head -c 1048577)"
line="$(jq -r '(.prompt // "") | strings | gsub("\r";"") | split("\n")
  | map(select(test("[^[:space:]]"))) | .[0] // "" | sub("^\\s+";"") | sub("\\s+$";"")' \
  <<<"$payload" 2>/dev/null)" || say 'unreadable prompt; nothing recorded'
[[ "$line" == design-decision:* ]] || exit 0
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || say 'no repository; nothing recorded'
state="$repo/.agents/state/design-decision-request.json"
[[ -e "$state" || -L "$state" ]] || say 'no research decision is pending; nothing recorded'
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh" || say 'state library unavailable; nothing recorded'
# shellcheck source=../lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh" || say 'decision library unavailable; nothing recorded'
snapshot="$(verdict_audit_read_regular_state "$state" 16384 json)" || say 'request state unreadable; nothing recorded'
request="${snapshot#*$'\n'}"
jq -e --arg repo "$repo" --arg branch "$(git -C "$repo" branch --show-current 2>/dev/null)" \
  --arg session "$(jq -r '.session_id // "" | strings' <<<"$payload")" \
  '.spec.prefix == "design-decision:" and (.spec.binding | .root == $repo
    and .branch == $branch and .session == $session)' <<<"$request" >/dev/null 2>&1 \
  || say 'the pending decision belongs to another session or branch; nothing recorded'
timed_user_prompt prompt-reply "$state" "$(jq -r .id <<<"$request")" "$line" >/dev/null 2>&1 \
  || say 'use the first line "design-decision: <Redesign|Reflect again|Overrule> <reason>" while a decision is open; nothing recorded'
say "recorded \"$line\"; the next edit attempt applies it"
