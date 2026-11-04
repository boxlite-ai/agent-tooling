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
names=(pr-size-request pr-review-request design-decision-request)
scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || scope=""
names+=("commit-audit-decision-request-$scope" "push-audit-decision-request-$scope")
present=false
for name in "${names[@]}"; do
  [[ ! -e "$repo/.agents/state/$name.json" && ! -L "$repo/.agents/state/$name.json" ]] || present=true
done
[[ "$present" == true ]] || exit 0
session="$(jq -er '.session_id // "" | select(type=="string")' <<<"$payload")" || exit 2
head="$(git -C "$repo" rev-parse HEAD)" || exit 2
branch="$(git -C "$repo" branch --show-current)" || exit 2
for name in "${names[@]}"; do
  path="$repo/.agents/state/$name.json"
  [[ -e "$path" || -L "$path" ]] || continue
  snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || exit 2
  request="${snapshot#*$'\n'}"
  request_session="$session"
  if [[ "$(jq -r .spec.fallback <<<"$request")" == reflect-again ]]; then
    # shellcheck source=../.agents/lib/git-audit-decision.sh
    source "$plugin/.agents/lib/git-audit-decision.sh"
    git_audit_decision_current "$request" || continue
    request_session="$scope"
  fi
  jq -e --arg repo "$repo" --arg head "$head" --arg branch "$branch" --arg session "$request_session" '
    . as $request | .spec.binding | (.root // .repo) == $repo and .head == $head
      and .branch == (if $request.spec.fallback == "reflect-again" and $branch == "" then "HEAD" else $branch end)
      and .session == $session' <<<"$request" >/dev/null || continue
  id="$(jq -er .id <<<"$request")" || exit 2
  request="$(timed_user_prompt status "$path" "$id")" || exit 2
  status="$(jq -r .status <<<"$request")"
  case "$status" in
    pending)
      reason="$(timed_user_prompt_instruction "$plugin" "$request")" || exit 2
      reason="$(subagent_prompt questions/timed-continue-pending "$plugin" \
        "name=${name%-request}" "instruction=$reason")" || exit 2 ;;
    declined)
      [[ "$(jq -r .fallback_delivered <<<"$request")" == false ]] || continue
      reason="$(subagent_prompt pr/pr-size-declined "$plugin" \
        "request_id=$id" "state=$path" "tooling=$plugin")" || exit 2
      timed_user_prompt fallback "$path" "$id" >/dev/null || exit 2 ;;
    expired)
      [[ "$(jq -r .fallback_delivered <<<"$request")" == false ]] || continue
      case "$(jq -r .spec.fallback <<<"$request")" in
        split) reason="$(subagent_prompt questions/timed-continue-expired-size "$plugin")" || exit 2 ;;
        keep-blocked) reason="$(subagent_prompt questions/timed-continue-expired-design "$plugin")" || exit 2 ;;
        reflect-again) reason="$(subagent_prompt questions/timed-continue-expired-git-audit "$plugin")" || exit 2 ;;
        *) reason="$(subagent_prompt questions/timed-continue-expired-review "$plugin")" || exit 2 ;;
      esac
      timed_user_prompt fallback "$path" "$id" >/dev/null || exit 2 ;;
    *) continue ;;
  esac
  jq -nc --arg reason "$reason" '{decision:"block",reason:$reason}'
  exit 0
done
