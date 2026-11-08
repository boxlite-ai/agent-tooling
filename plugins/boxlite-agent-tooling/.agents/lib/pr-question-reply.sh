#!/usr/bin/env bash
# Called by UserPromptSubmit after internal wakes have been filtered.
pr_question_reply() { # payload, checkout, plugin root
  local payload="$1" repo="$2" plugin="$3" reply prefix path request id session result
  reply="$(user_question reply "$plugin" "$payload")" || return 1
  prefix="$(jq -er .prefix <<<"$reply")" || return 1
  case "$prefix" in
    reviewed:) path=pr-review-request.json ;;
    pr-size-exception:) path=pr-size-request.json ;;
    *) return 1 ;;
  esac
  [[ ! -L "$repo/.agents" && ! -L "$repo/.agents/state" ]] || return 1
  path="$repo/.agents/state/$path"
  # shellcheck source=timed-user-prompt.sh
  source "$plugin/.agents/lib/timed-user-prompt.sh" || return 1
  request="$(timed_user_prompt_read "$path")" || return 1
  id="$(jq -er .id <<<"$reply")" || return 1
  session="$(jq -ce .session_id <<<"$payload")" || return 1
  jq -e --arg prefix "$prefix" --arg id "$id" --arg repo "$repo" --argjson session "$session" \
    --arg branch "$(git -C "$repo" branch --show-current)" --arg head "$(git -C "$repo" rev-parse HEAD)" '
    .id == $id and .spec.prefix == $prefix and (.spec.binding |
      (.root // .repo) == $repo and .session == $session and .branch == $branch and .head == $head)
  ' <<<"$request" >/dev/null || return 1
  result="$(timed_user_prompt prompt-reply "$path" "$id" "$(jq -er .text <<<"$reply")")" || return 1
  if [[ "$(jq -r .status <<<"$result")" == declined ]]; then
    printf 'PR size choice recorded. Follow the split fallback.\n'
  else
    printf 'PR confirmation recorded. Retry the same guarded command.\n'
  fi
}
