#!/usr/bin/env bash
# Records a human's typed dismissal of one open ledger finding (design #563):
# the whole prompt is `ledger-dismiss: <label> <reason>`. The caller runs this only after
# its internal-prompt filters. Prints the outcome as context; always exits 0.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
say() { printf 'ledger-dismiss: %s\n' "$1"; exit 0; }
for dependency in jq git perl date; do command -v "$dependency" >/dev/null 2>&1 || say "missing $dependency; nothing recorded"; done
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || say 'prompt exceeds inspection limit; nothing recorded'
prompt="$(jq -r 'if (.prompt | type) == "string" then .prompt else "" end' <<<"$payload")" \
  || say 'unreadable prompt; nothing recorded'
# One line only: trailing blank lines are tolerated, any other text is not a directive.
prompt="$(perl -0777 -pe 's/\A\s+//; s/\s+\z//' <<<"$prompt")"
if [[ "$prompt" == *$'\n'* \
    || ! "$prompt" =~ ^ledger-dismiss:[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]].*)$ ]]; then
  say 'use one line: ledger-dismiss: <label> <reason>; nothing recorded'
fi
label="${BASH_REMATCH[1]}" reason="${BASH_REMATCH[2]}"
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
  || say 'no repository; nothing recorded'
branch="$(git -C "$repo" branch --show-current 2>/dev/null)"
[[ -n "$branch" ]] || say 'no current branch; nothing recorded'
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh" || say 'state library unavailable; nothing recorded'
# shellcheck source=../lib/audit-ledger.sh
source "$plugin/.agents/lib/audit-ledger.sh" || say 'ledger library unavailable; nothing recorded'
why="$(audit_ledger_dismiss "$repo" "$branch" "$label" "$reason")" || say "${why:-dismissal failed}; nothing recorded"
say "dismissed $label on branch $branch; it no longer needs listing in replies or the PR"
