#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Stop-hook continuation. Waits and splitting remain agent actions; deadlines are code.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in git jq perl date; do command -v "$dependency" >/dev/null || exit 2; done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/subagent.sh
source "$plugin/.agents/lib/subagent.sh"
# shellcheck source=../.agents/lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh"
payload="$(cat)"
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -e "$repo/.agents/state/pr-size-request.json" || -L "$repo/.agents/state/pr-size-request.json" \
  || -e "$repo/.agents/state/pr-review-request.json" || -L "$repo/.agents/state/pr-review-request.json" ]] || exit 0
session="$(jq -er '.session_id // "" | select(type=="string")' <<<"$payload")" || exit 2
head="$(git -C "$repo" rev-parse HEAD)" || exit 2
branch="$(git -C "$repo" branch --show-current)" || exit 2
for name in pr-size-request pr-review-request; do
  path="$repo/.agents/state/$name.json"
  [[ -e "$path" || -L "$path" ]] || continue
  snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || exit 2
  request="${snapshot#*$'\n'}"
  jq -e --arg repo "$repo" --arg head "$head" --arg branch "$branch" --arg session "$session" '
    .spec.binding | (.root // .repo) == $repo and .head == $head and .branch == $branch
      and .session == $session' <<<"$request" >/dev/null || continue
  id="$(jq -er .id <<<"$request")" || exit 2
  request="$(timed_user_prompt status "$path" "$id")" || exit 2
  status="$(jq -r .status <<<"$request")"
  case "$status" in
    pending)
      reason="$(timed_user_prompt_instruction "$plugin" "$request")" || exit 2
      reason="Continue the pending ${name%-request} confirmation. $reason" ;;
    expired)
      [[ "$(jq -r .fallback_delivered <<<"$request")" == false ]] || continue
      if [[ "$(jq -r .spec.fallback <<<"$request")" == split ]]; then
        reason='The three-minute PR size exception deadline expired. Continue now: reuse or create one tracking issue with a PR checklist and split the work into coherent tested PRs of at most 400 changed lines. Create separate issues only for work needing independent tracking. Only a new explicit human request permits renewal: remeasure through the guarded PR operation and follow its renewal instructions. Never renew autonomously or publish without a fresh exception.'
      else
        reason='The three-minute reviewed acknowledgment deadline expired. Leave the PR draft or uncreated and report that review is still required. No review acknowledgment was granted; continue other authorized work.'
      fi
      timed_user_prompt fallback "$path" "$id" >/dev/null || exit 2 ;;
    *) continue ;;
  esac
  jq -nc --arg reason "$reason" '{decision:"block",reason:$reason}'
  exit 0
done
