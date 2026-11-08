#!/usr/bin/env bash
# Called by UserPromptSubmit after internal wakes have been filtered.
pr_question_reply() { # payload, checkout, plugin root
  local payload="$1" repo="$2" plugin="$3" reply line prefix path snapshot request pr_reply_id size session result
  reply="$(user_question reply "$plugin" "$payload")" || return 1
  line="$(jq -er '.first_line // empty' <<<"$reply")" || return 1
  case "$line" in
    reviewed:*) prefix=reviewed:; path=pr-review-request.json ;;
    pr-size-exception:*)
      size="$(jq -ce -L "$plugin/.agents/lib" '
        include "user-question-policy";
        .text | capture("^pr-size-exception: (?<id>[0-9a-f]{32}) (?<answer>[^\\r\\n]+)$") as $choice |
        select(test(user_question_bound_choice_pattern("pr-size-exception:"; $choice.id))) | $choice
      ' <<<"$reply")" || return 1
      prefix=pr-size-exception:
      path=pr-size-request.json
      ;;
    *) return 1 ;;
  esac
  [[ ! -L "$repo/.agents" && ! -L "$repo/.agents/state" ]] || return 1
  path="$repo/.agents/state/$path"
  snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || return 1
  request="${snapshot#*$'\n'}"
  session="$(jq -ce .session_id <<<"$payload")" || return 1
  jq -e --arg prefix "$prefix" --arg repo "$repo" --argjson session "$session" \
    --arg branch "$(git -C "$repo" branch --show-current)" --arg head "$(git -C "$repo" rev-parse HEAD)" '
    .spec.prefix == $prefix and (.spec.binding |
      (.root // .repo) == $repo and .session == $session and .branch == $branch and .head == $head)
  ' <<<"$request" >/dev/null || return 1
  pr_reply_id="$(jq -er .id <<<"$request")" || return 1
  if [[ "$prefix" == pr-size-exception: ]]; then
    [[ "$(jq -er .id <<<"$size")" == "$pr_reply_id" ]] || return 1
    line="$(jq -er .answer <<<"$size")" || return 1
  fi
  # shellcheck source=timed-user-prompt.sh
  source "$plugin/.agents/lib/timed-user-prompt.sh" || return 1
  result="$(timed_user_prompt prompt-reply "$path" "$pr_reply_id" "$line")" || return 1
  if [[ "$(jq -r .status <<<"$result")" == declined ]]; then
    printf 'PR size choice recorded. Follow the split fallback.\n'
  else
    printf 'PR confirmation recorded. Retry the same guarded command.\n'
  fi
}
