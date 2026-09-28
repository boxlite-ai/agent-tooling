#!/usr/bin/env bash
# Source-only PR size facade. Requires git, gh, jq, perl, subagent, and timed-user-prompt.
# Check the published branch before creation; gh must not implicitly push a new head.

_pr_size_gh() {
  perl -e '$SIG{ALRM}=sub{exit 124}; alarm 20; exec @ARGV; exit 2' gh "$@"
}

_pr_size_snapshot() { # subcommand argv... -> {repo,branch,head,base,lines}
  local operation="$1" branch head repository base="" selector="" head_option="" token value metadata response filter
  local repo_option="" head_owner="" head_repository
  shift
  branch="$(git branch --show-current)" && [[ -n "$branch" ]] || return 2
  head="$(git rev-parse HEAD)" || return 2
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --undo) [[ "$operation" == ready ]] && return 3; return 2 ;;
      --draft|-d|--draft=true|-d=true|--fill|--fill-first|--fill-verbose|--dry-run|--no-maintainer-edit|--remove-milestone) ;;
      --base|-B|--head|-H|--repo|-R|--title|-t|--body|-b|--body-file|-F|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer)
        (( $# )) || return 2
        value="$1"; shift
        case "$token" in
          --base|-B) base="$value" ;; --head|-H) head_option="$value" ;; --repo|-R) repo_option="$value" ;;
        esac ;;
      --base=*) base="${token#*=}" ;;
      --head=*) head_option="${token#*=}" ;;
      --repo=*) repo_option="${token#*=}" ;;
      -R?*) repo_option="${token#-R}" ;;
      --title=*|--body=*|--body-file=*|--assignee=*|--label=*|--milestone=*|--project=*|--reviewer=*|--add-*=*|--remove-*=*|-t?*|-b?*|-F?*|-a?*|-l?*|-m?*|-p?*|-r?*) ;;
      -*) return 2 ;;
      *) [[ "$operation" != create && -z "$selector" ]] || return 2; selector="$token" ;;
    esac
  done
  # A fork head is owner:branch; its branch must still be this checkout's.
  if [[ "$head_option" == *:* ]]; then
    head_owner="${head_option%%:*}"
    head_option="${head_option#*:}"
    [[ "$head_owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 2
  fi
  [[ -z "$head_option" || "$head_option" == "$branch" ]] || return 2
  # The review gate refuses repository overrides on edit and ready, so only create
  # measures one; any other caller would mix repositories.
  [[ -z "$repo_option" || "$operation" == create ]] || return 2
  [[ -z "$repo_option" || "$repo_option" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  metadata="$(_pr_size_gh repo view ${repo_option:+"$repo_option"} --json nameWithOwner,defaultBranchRef)" || return 2
  repository="$(jq -er '.nameWithOwner | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))' <<<"$metadata")" || return 2
  if [[ "$operation" == create ]]; then
    [[ -n "$base" ]] || base="$(git config --get "branch.$branch.gh-merge-base" || true)"
    [[ -n "$base" ]] || base="$(jq -er '.defaultBranchRef.name | select(type == "string" and length > 0)' <<<"$metadata")" || return 2
    # Only the pushed-head check reads the fork: the upstream compare below resolves a
    # fork commit through the shared object network. A renamed fork fails closed here.
    head_repository="${head_owner:+$head_owner/${repository#*/}}"
    response="$(_pr_size_gh api "repos/${head_repository:-$repository}/commits/$(jq -rn --arg ref "$branch" '$ref|@uri')")" || return 2
    [[ "$(jq -er .sha <<<"$response")" == "$head" ]] || return 2
  else
    response="$(_pr_size_gh pr view "${selector:-$branch}" --json baseRefOid,headRefOid,headRefName)" || return 2
    base="$(jq -er --arg head "$head" --arg branch "$branch" '
      select(.headRefOid == $head and .headRefName == $branch)
      | .baseRefOid | select(type == "string" and test("^[0-9a-f]{40}$"))
    ' <<<"$response")" || return 2
  fi
  # All publication paths use one file-level comparison and the same classifier.
  # GitHub returns at most 300 files; the filter rejects possibly truncated input.
  response="$(_pr_size_gh api "repos/$repository/compare/$(jq -rn --arg ref "$base" '$ref|@uri')...$head")" || return 2
  filter="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-size.jq" || return 2
  response="$(jq -ce --arg head "$head" --arg base "$base" -f "$filter" <<<"$response")" || return 2
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
