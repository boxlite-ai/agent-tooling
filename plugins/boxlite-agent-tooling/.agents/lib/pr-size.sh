#!/usr/bin/env bash
# Source-only PR size facade. Requires git, gh, jq, perl, subagent, and timed-user-prompt.
# Check the published branch before creation; gh must not implicitly push a new head.

_pr_size_gh() {
  perl -e '$SIG{ALRM}=sub{exit 124}; alarm 20; exec @ARGV; exit 2' gh "$@"
}

_pr_size_snapshot() { # subcommand argv... -> {repo,branch,head,base,lines}
  local operation="$1" branch head repository base="" selector="" head_option="" token value metadata response
  shift
  branch="$(git branch --show-current)" && [[ -n "$branch" ]] || return 2
  head="$(git rev-parse HEAD)" || return 2
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --undo) [[ "$operation" == ready ]] && return 3; return 2 ;;
      --draft|-d|--draft=true|-d=true|--fill|--fill-first|--fill-verbose|--dry-run|--no-maintainer-edit|--remove-milestone) ;;
      --base|-B|--head|-H|--title|-t|--body|-b|--body-file|-F|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer)
        (( $# )) || return 2
        value="$1"; shift
        case "$token" in --base|-B) base="$value" ;; --head|-H) head_option="$value" ;; esac ;;
      --base=*) base="${token#*=}" ;;
      --head=*) head_option="${token#*=}" ;;
      --title=*|--body=*|--body-file=*|--assignee=*|--label=*|--milestone=*|--project=*|--reviewer=*|--add-*=*|--remove-*=*|-t?*|-b?*|-F?*|-a?*|-l?*|-m?*|-p?*|-r?*) ;;
      -*) return 2 ;;
      *) [[ "$operation" != create && -z "$selector" ]] || return 2; selector="$token" ;;
    esac
  done
  [[ -z "$head_option" || "$head_option" == "$branch" ]] || return 2
  metadata="$(_pr_size_gh repo view --json nameWithOwner,defaultBranchRef)" || return 2
  repository="$(jq -er '.nameWithOwner | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))' <<<"$metadata")" || return 2
  if [[ "$operation" == create ]]; then
    [[ -n "$base" ]] || base="$(git config --get "branch.$branch.gh-merge-base" || true)"
    [[ -n "$base" ]] || base="$(jq -er '.defaultBranchRef.name | select(type == "string" and length > 0)' <<<"$metadata")" || return 2
    response="$(_pr_size_gh api "repos/$repository/commits/$(jq -rn --arg ref "$branch" '$ref|@uri')")" || return 2
    [[ "$(jq -er .sha <<<"$response")" == "$head" ]] || return 2
    response="$(_pr_size_gh api "repos/$repository/compare/$(jq -rn --arg ref "$base" '$ref|@uri')...$head")" || return 2
    # GitHub only returns the first 300 files. Refuse a possibly truncated total.
    response="$(jq -ce --arg head "$head" '
      def count: type == "number" and . >= 0 and . <= 1000000000 and floor == .;
      if (.files | type) != "array" or (.files|length) >= 300
        or any(.files[]; (.additions|count|not) or (.deletions|count|not))
      then error("incomplete comparison")
      else {base:.base_commit.sha,head:$head,lines:([.files[]|.additions+.deletions]|add//0)} end
    ' <<<"$response")" || return 2
  else
    response="$(_pr_size_gh pr view "${selector:-$branch}" --json baseRefOid,headRefOid,headRefName,additions,deletions)" || return 2
    response="$(jq -ce --arg head "$head" --arg branch "$branch" '
      def count: type == "number" and . >= 0 and . <= 1000000000 and floor == .;
      if .headRefOid != $head or .headRefName != $branch
        or (.additions|count|not) or (.deletions|count|not)
      then error("PR does not match the checkout")
      else {base:.baseRefOid,head:.headRefOid,lines:(.additions+.deletions)} end
    ' <<<"$response")" || return 2
  fi
  jq -ce --arg repo "$repository" --arg branch "$branch" '
    select(.base|type=="string" and test("^[0-9a-f]{40}$"))
    | select(.head|type=="string" and test("^[0-9a-f]{40}$"))
    | . + {repo:$repo,branch:$branch}' <<<"$response"
}

pr_size_check() { # context JSON {root,project,session,tooling}, subcommand argv...
  local context="$1" snapshot status=0 spec record request_id state lines message project tooling
  shift
  project="$(jq -er .project <<<"$context")" || return 2
  tooling="$(jq -er .tooling <<<"$context")" || return 2
  snapshot="$(_pr_size_snapshot "$@")" || status=$?
  (( status != 3 )) || return 0
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
    [[ "$(_pr_size_snapshot "$@")" == "$snapshot" ]] || return 2
    return 0
  fi
  if [[ "$status" == expired ]]; then
    subagent_prompt pr-size-expired "$tooling" "lines=$lines" \
      "base=$(jq -r .base <<<"$snapshot")" "head=$(jq -r .head <<<"$snapshot")" \
      "request_id=$request_id" "state=$state" "tooling=$tooling" || return 2
    return 1
  fi
  message="$(subagent_prompt pr-size-exception "$tooling" "lines=$lines" \
    "base=$(jq -r .base <<<"$snapshot")" "head=$(jq -r .head <<<"$snapshot")" \
    "request_id=$request_id" "state=$state" "tooling=$tooling")" || return 2
  [[ "$message" == *[![:space:]]* ]] || return 2
  printf '%s\n' "$message"
  timed_user_prompt_instruction "$tooling" "$record" || return 2
  return 1
}
