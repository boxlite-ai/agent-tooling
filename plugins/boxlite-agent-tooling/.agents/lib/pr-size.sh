#!/usr/bin/env bash
# Source-only PR size facade. Requires pr-target, jq, subagent, and timed-user-prompt.

_pr_size_snapshot() { # resolved target -> target identity plus code additions
  local target="$1" repository host head base response filter
  repository="$(jq -r .repo <<<"$target")"; host="$(jq -r .host <<<"$target")"
  head="$(jq -r .head <<<"$target")"; base="$(jq -r .base <<<"$target")"
  # All publication paths use one file-level comparison and the same classifier.
  # GitHub returns at most 300 files; the filter rejects possibly truncated input.
  response="$(_pr_target_gh api --hostname "$host" "repos/$repository/compare/$base...$head")" || return 2
  filter="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-size.jq" || return 2
  response="$(jq -ce --arg head "$head" --arg base "$base" -f "$filter" <<<"$response")" || return 2
  jq -cS --argjson target "$(pr_target_binding "$target")" '$target + .' <<<"$response"
}

pr_size_check() { # context JSON {root,project,session,tooling}, resolved target, subcommand argv...
  local context="$1" target="$2" snapshot status=0 spec record request_id state lines message project tooling
  shift 2
  project="$(jq -er .project <<<"$context")" || return 2
  tooling="$(jq -er .tooling <<<"$context")" || return 2
  [[ "$(jq -r .undo <<<"$target")" != true ]] || return 0
  snapshot="$(_pr_size_snapshot "$target")" || status=$?
  if (( status )); then
    printf 'Cannot determine the exact PR size. Use a direct command in its checkout, push the current branch first, and resolve API or target errors before retrying.\n'
    return 1
  fi
  lines="$(jq -r .lines <<<"$snapshot")"
  (( lines > 400 )) || return 0
  mkdir -p "$project/.agents/state" || return 2
  state="$project/.agents/state/pr-size-request.json"
  spec="$(jq -nc --argjson snapshot "$snapshot" --argjson context "$context" '
    {binding:($snapshot+{root:$context.root,session:$context.session}),
     prefix:"pr-size-exception:",fallback:"split",minimum_words:12}')" || return 2
  record="$(timed_user_prompt request "$state" "$spec")" || return 2
  request_id="$(jq -r .id <<<"$record")"
  status="$(jq -r .status <<<"$record")"
  if [[ "$status" == accepted ]]; then
    # Re-read after authorization; an API response or ref movement cannot borrow it.
    target="$(pr_target_resolve "$@")" || return 2
    [[ "$(_pr_size_snapshot "$target")" == "$snapshot" ]] || return 2
    return 0
  fi
  if [[ "$status" == declined ]]; then
    subagent_prompt pr/pr-size-declined "$tooling" \
      "request_id=$request_id" "state=$state" "tooling=$tooling" || return 2
    return 1
  fi
  if [[ "$status" == expired ]]; then
    subagent_prompt pr/pr-size-expired "$tooling" "lines=$lines" \
      "base=$(jq -r .base <<<"$snapshot")" "head=$(jq -r .head <<<"$snapshot")" \
      "request_id=$request_id" "state=$state" "tooling=$tooling" || return 2
    return 1
  fi
  message="$(subagent_prompt pr/pr-size-exception "$tooling" "lines=$lines" \
    "base=$(jq -r .base <<<"$snapshot")" "head=$(jq -r .head <<<"$snapshot")" \
    "request_id=$request_id" "state=$state" "tooling=$tooling")" || return 2
  [[ "$message" == *[![:space:]]* ]] || return 2
  printf '%s\n' "$message"
  timed_user_prompt_instruction "$tooling" "$record" || return 2
  return 1
}
