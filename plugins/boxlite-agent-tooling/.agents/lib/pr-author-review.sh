#!/usr/bin/env bash
# Author review acknowledgment. Source-only; pr_author_review_run is the facade.
# Requires jq, concise_writing_check_summary, github_writing_check_privacy,
# subagent_prompt and authenticated gh.
# Comments are the record; commit statuses enforce the record on the base repository.

_pr_review_gh() { "${GH_BIN:-gh}" "$@"; }

_pr_review_error() {
  printf 'pr-author-review: %s\n' "$1" >&2
  return 2
}

_pr_review_event() {
  jq -er '
    def positive_integer: type == "number" and . > 0 and floor == .;
    .action as $action |
    if .issue and (.issue.pull_request | not) then "skip"
    elif .issue.pull_request and $action == "created" and .comment.user.type == "Bot"
    then "skip"
    else
      if (.repository.full_name | type != "string") or
         (.repository.full_name | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$") | not) or
         (.repository.full_name | split("/")[1] | . == "." or . == "..")
      then error("invalid repository identity") else . end |
      if .merge_group then
        if $action != "checks_requested" or (.merge_group.head_sha | type != "string") or
           (.merge_group.head_sha | test("^[0-9a-f]{40}$") | not)
        then error("invalid merge group")
        else ["queue", .repository.full_name, .merge_group.head_sha] | @tsv end
      else
        (if .pull_request then
         if (["opened","reopened","synchronize","ready_for_review","closed"] | index($action))
         then .pull_request.number else error("unsupported PR event") end
       elif .issue.pull_request and (["created","edited","deleted"] | index($action))
       then .issue.number
       else error("unsupported PR event") end) as $number |
        if ($number | positive_integer | not) then error("invalid pull request identity")
        else ["pr", .repository.full_name, ($number | tostring)] | @tsv end
      end
    end' "$1"
}

_pr_review_state() { # base repository, PR number -> validated JSON snapshot
  local response
  response="$(_pr_review_gh api "repos/$1/pulls/$2")" || return 2
  jq -ce --arg repo "$1" --argjson number "$2" '
    if .number != $number or .base.repo.full_name != $repo or
       (.node_id | type != "string") or (.node_id | length == 0) or
       (.draft | type != "boolean") or
       (.head.sha | type != "string") or (.head.sha | test("^[0-9a-f]{40}$") | not) or
       (.user.id | type != "number") or .user.id <= 0 or (.user.id | floor != .) or
       (.user.login | type != "string") or
       (.user.login | test("^[A-Za-z0-9][A-Za-z0-9-]*(\\[bot\\])?$") | not) or
       (.user.type != "User" and .user.type != "Bot") or
       (.state != "open" and .state != "closed") then error("invalid PR state")
    else {id:.node_id,draft,sha:.head.sha,author_id:.user.id,author:.user.login,author_type:.user.type,state} end
  ' <<<"$response"
}

_pr_review_status() { # repository, PR number, SHA, state, description, optional target URL
  jq -n --arg state "$4" --arg description "$5" \
    --arg url "${6:-${GITHUB_SERVER_URL:-https://github.com}/$1/pull/$2}" \
    '{state:$state,context:"Author reviewed the PR",description:$description,target_url:$url}' |
    _pr_review_gh api -X POST "repos/$1/statuses/$3" --input - >/dev/null
}

_pr_review_draft() { # validated PR node id -> confirmed draft conversion
  local response
  response="$(jq -n --arg id "$1" '{
    query:"mutation($input: ConvertPullRequestToDraftInput!) { convertPullRequestToDraft(input: $input) { pullRequest { id isDraft } } }",
    variables:{input:{pullRequestId:$id}}
  }' | _pr_review_gh api -X POST graphql --input -)" || return 2
  jq -e --arg id "$1" '
    ((.errors // []) | length == 0) and
    .data.convertPullRequestToDraft.pullRequest.id == $id and
    .data.convertPullRequestToDraft.pullRequest.isDraft == true
  ' <<<"$response" >/dev/null
}

_pr_review_ack() { # author id, SHA; stdin: comment array -> first valid acknowledgment
  # An edited comment may have been rewritten by a maintainer, not its original author.
  # Requiring a fresh comment keeps the acknowledgment attributable to the API's user id.
  jq -c --argjson author "$1" --arg command "/reviewed $2" '
    [.[] | select(.user.id == $author and .user.type == "User" and
      (.body | type == "string") and (.body | gsub("^\\s+|\\s+$"; "")) == $command and
      (.created_at | type == "string") and (.created_at | length > 0) and
      .created_at == .updated_at)] | first // null'
}

_pr_review_comments() { # repository, PR number, author id, SHA -> acknowledgment + prompt
  local page response count candidate prompt ack=null notice=null
  for ((page=1; page<=10; page++)); do
    response="$(_pr_review_gh api "repos/$1/issues/$2/comments?per_page=100&page=$page")" || return 2
    count="$(jq -er '
      if type != "array" then error("expected comment array")
      elif length > 100 or any(.[]; type != "object" or (.id | type != "number") or
        .id <= 0 or (.id | floor != .)) then error("invalid comments")
      else length end' <<<"$response")" || return 2
    candidate="$(_pr_review_ack "$3" "$4" <<<"$response")" || return 2
    [[ "$ack" != null || "$candidate" == null ]] || ack="$candidate"
    prompt="$(jq -c '[.[] | select(.user.login == "github-actions[bot]" and
      .user.type == "Bot" and (.body | type == "string") and
      (.body | startswith("<!-- boxlite-agent-tooling:author-review -->\n")))] | first // null' \
      <<<"$response")" || return 2
    [[ "$notice" != null || "$prompt" == null ]] || notice="$prompt"
    if (( count < 100 )); then
      jq -nc --argjson ack "$ack" --argjson notice "$notice" '{ack:$ack,notice:$notice}'
      return
    fi
  done
  _pr_review_error "$1#$2 has at least 1000 comments; refusing an incomplete acknowledgment scan"
}

_pr_review_exclusive_head() { # repository, PR number, SHA; 0 unique, 1 shared, 2 unknown
  # A required commit status is shared by every PR with that SHA. Refuse ambiguous heads
  # so an acknowledgment on one PR cannot silently satisfy another PR's required check.
  local response count page shared
  for ((page=1; page<=10; page++)); do
    response="$(_pr_review_gh api "repos/$1/commits/$3/pulls?per_page=100&page=$page")" || return 2
    count="$(jq -er 'if type != "array" then error("expected pull request array")
      elif length > 100 or any(.[]; (.number | type != "number") or .number <= 0 or
        (.number | floor != .) or (.head.sha | type != "string") or
        (.head.sha | test("^[0-9a-f]{40}$") | not) or
        (.state != "open" and .state != "closed")) then error("invalid associated PR")
      else length end' <<<"$response")" || return 2
    shared="$(jq -r --arg sha "$3" --argjson number "$2" '
      any(.[]; .state == "open" and .head.sha == $sha and .number != $number)' <<<"$response")" || return 2
    [[ "$shared" == false ]] || return 1
    (( count == 100 )) || return 0
  done
  _pr_review_error "too many pull requests associated with $1@$3"
}

_pr_review_prompt() { # repository, PR number, SHA, author login, existing prompt, result, tooling root
  local body previous id review_question
  review_question="$(subagent_prompt pr-review-question "$7")" || return 2
  [[ "$review_question" == *[![:space:]]* ]] || {
    _pr_review_error "empty prompt: $7/.agents/prompts/pr-review-question.md"; return 2;
  }
  body="$(subagent_prompt pr-author-review "$7" \
    "result=$6" "author=$4" "sha=$3" "review_question=$review_question")" || return 2
  [[ "$body" == *[![:space:]]* ]] || {
    _pr_review_error "empty prompt: $7/.agents/prompts/pr-author-review.md"; return 2;
  }
  github_writing_check_privacy "$body" >&2 || return 2
  concise_writing_check_summary "$body" >&2 || return 2
  # The comment identity is protocol metadata, independent of editable wording.
  body="$(printf '%s\n%s' '<!-- boxlite-agent-tooling:author-review -->' "$body")"
  previous="$(jq -r '.body // ""' <<<"$5")" || return 2
  [[ "$previous" != "$body" ]] || return 0
  id="$(jq -r '.id // ""' <<<"$5")" || return 2
  if [[ -n "$id" ]]; then
    jq -n --arg body "$body" '{body:$body}' |
      _pr_review_gh api -X PATCH "repos/$1/issues/comments/$id" --input - >/dev/null
  else
    jq -n --arg body "$body" '{body:$body}' |
      _pr_review_gh api -X POST "repos/$1/issues/$2/comments" --input - >/dev/null
  fi
}

pr_author_review_run() { # trusted GitHub event file, tooling root
  local identity kind repo number state latest sha author_id author comments ack notice live
  local attempt verdict result unique_rc
  [[ -n "$1" && -f "$1" && -r "$1" ]] || {
    _pr_review_error "cannot read event file ${1:-<none>}"; return 2;
  }
  identity="$(_pr_review_event "$1")" || {
    _pr_review_error "invalid pull request event in $1"; return 2;
  }
  [[ "$identity" != skip ]] || return 0
  IFS=$'\t' read -r kind repo number <<<"$identity"
  if [[ "$kind" == queue ]]; then
    # This is the queue-generated commit, not a new contribution to acknowledge.
    # Requiring our PR status is what prevents unacknowledged PRs entering the queue.
    _pr_review_status "$repo" "" "$number" success "Author review required before entering the merge queue" \
      "${GITHUB_SERVER_URL:-https://github.com}/$repo/actions" || {
      _pr_review_error "could not publish queue status on $repo@$number"; return 2;
    }
    printf 'Author review carried forward from PR admission: %s@%s\n' "$repo" "$number"
    return 0
  fi
  for ((attempt=1; attempt<=3; attempt++)); do
    state="$(_pr_review_state "$repo" "$number")" || {
      _pr_review_error "could not read current state of $repo#$number"; return 2;
    }
    [[ "$(jq -r .state <<<"$state")" == open ]] || return 0
    sha="$(jq -r .sha <<<"$state")"
    author_id="$(jq -r .author_id <<<"$state")"
    author="$(jq -r .author <<<"$state")"
    # Revoke any previous success before reads that might fail or reveal a deleted comment.
    _pr_review_status "$repo" "$number" "$sha" pending "Awaiting author acknowledgment for this commit" || {
      _pr_review_error "could not publish pending status on $repo@$sha"; return 2;
    }
    comments="$(_pr_review_comments "$repo" "$number" "$author_id" "$sha")" || {
      _pr_review_error "could not read acknowledgments for $repo#$number"; return 2;
    }
    ack="$(jq -c .ack <<<"$comments")"
    notice="$(jq -c .notice <<<"$comments")"
    verdict=pending
    result="Awaiting the PR author's acknowledgment."
    if [[ "$ack" != null && "$(jq -r .author_type <<<"$state")" == User ]]; then
      live="$(_pr_review_gh api "repos/$repo/issues/comments/$(jq -r .id <<<"$ack")")" || {
        _pr_review_error "could not recheck acknowledgment for $repo#$number"; return 2;
      }
      ack="$(jq -c '[.]' <<<"$live" | _pr_review_ack "$author_id" "$sha")" || {
        _pr_review_error "invalid acknowledgment for $repo#$number"; return 2;
      }
      if [[ "$ack" != null ]]; then
        _pr_review_exclusive_head "$repo" "$number" "$sha"
        unique_rc=$?
        case "$unique_rc" in
          0) verdict=success; result="The PR author acknowledged this commit." ;;
          1) result="Another open PR shares this commit. Push a distinct commit before acknowledging it." ;;
          *) _pr_review_error "could not verify PRs sharing $repo@$sha"; return 2 ;;
        esac
      fi
    fi
    latest="$(_pr_review_state "$repo" "$number")" || {
      _pr_review_error "could not recheck current state of $repo#$number"; return 2;
    }
    [[ "$latest" == "$state" ]] || continue
    if [[ "$verdict" == pending && "$(jq -r .draft <<<"$state")" == false ]]; then
      _pr_review_draft "$(jq -r .id <<<"$state")" || {
        _pr_review_error "could not convert $repo#$number to draft"; return 2;
      }
    fi
    _pr_review_prompt "$repo" "$number" "$sha" "$author" "$notice" "$result" "$2" || {
      _pr_review_error "could not update review instructions for $repo#$number"; return 2;
    }
    if [[ "$verdict" == success ]]; then
      _pr_review_status "$repo" "$number" "$sha" success "PR author acknowledged this commit" || {
        _pr_review_error "could not publish success on $repo@$sha"; return 2;
      }
      printf 'Author review acknowledged: %s#%s at %s\n' "$repo" "$number" "$sha"
      return 0
    fi
    printf 'Author review pending: %s#%s at %s. %s\n' "$repo" "$number" "$sha" "$result" >&2
    return 1
  done
  _pr_review_error "$repo#$number changed during all three attempts; acknowledgment remains pending"
}
