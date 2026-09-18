#!/usr/bin/env bash
# CI step: commit UNREVIEWED.md to a new pull request's branch, convert the pull request to
# a draft, and fail while the head still has the file. A person deletes the file in a commit
# after reading the diff, then marks the pull request ready. A PR merged without that brings
# the file onto the default branch, where it says so even if this check has since been
# removed.
#
#   pr-unreviewed-file.sh <github-event.json>
#
# A missing file means "reviewed" only when the pull request carries a marking commit that
# names this pull request in its subject, is authored by the Actions bot, is committed by
# GitHub, verifies, and whose own diff added the file. Every event the workflow listens for
# marks a pull request that has none, so a first run that failed, or a pull request older
# than this workflow, cannot pass unmarked.
#
# Those five are tamper-evidence, not access control. Each rules out one cheap pass: a
# subject anyone can type; a real marker minted for another pull request and merged in on a
# stacked branch; a commit signed on a workstation under the bot's author email, which
# GitHub verifies against the committer, not the author; an unsigned commit; an empty one.
# None of them stops someone with write access who is willing to work at it, because the
# token of any workflow in this repository can make a real marking commit and GitHub signs
# for identities it authenticated, not for the workflow that asked. Draft is the block that
# does not depend on any of this; branch protection and review of .github/workflows are the
# controls.
#
# Every read is of current state — the head sha of the pull request and its commits —
# because a queued run holding an older event sha would otherwise pass a head that still has
# the file. Exit 0 when the file was added and then deleted, 1 otherwise, 2 when the event
# cannot be read or GitHub cannot be queried or updated: CI must not pass an unknown state.
# GH_BIN overrides the gh executable (tests). Needs jq and an authenticated gh.
#
# Three properties of GitHub shape this:
#   - The verdict reaches the pull request as this job's own check run, which GitHub
#     attaches to the head of the pull request under pull_request_target as under
#     pull_request. A commit made with this token starts no run at all, so the marking
#     commit gets an explicit status instead, under the job name so that one required check
#     covers both.
#   - Draft is the only block that needs no branch protection, and it is the only one that
#     reaches a fork, whose branch this token cannot write. The step converts to draft and
#     never back: a person marks the pull request ready themselves.
#   - A pull request lists at most 250 commits. Past that end a marking commit is invisible
#     and its absence proves nothing, so the step says so rather than marking forever.
#
# Tests: bash scripts/pr-unreviewed-file.test.sh
set -uo pipefail

marker_path="UNREVIEWED.md"
# Who GitHub says made the commit. Both logins are resolved from commit email addresses,
# which anyone can set, so neither means anything without the signature: GitHub verifies a
# signature against the committer, and it is GitHub itself that commits everything created
# through its API or web interface.
marker_commit_author="github-actions[bot]"
marker_commit_committer="web-flow"
# The most commits GitHub lists for a pull request.
marker_commit_list_limit=250
# The job name in .github/workflows/unreviewed-pr.yml: branch protection matches a status
# to a check run by this one name, so the marking commit reports under the same gate.
status_context="Author reviewed the PR"
status_description="$marker_path is in this pull request"

# The subject of the commit that adds the file, naming the pull request it marks. Unbound,
# a marking commit would still be one after a branch carrying it is merged into another
# pull request, which would then pass without ever having been marked itself.
marker_commit_subject() {  # pull request number
  printf 'chore: mark pull request #%s unreviewed' "$1"
}

marker_content() {
  printf '%s\n' \
    '# Unreviewed' \
    '' \
    'Nobody has reviewed this pull request yet. After reading the diff, delete this file in a commit and mark the pull request ready for review.' \
    '' \
    'If this file is on the default branch, the pull request that added it was merged without review.'
}

gh_cli() { "${GH_BIN:-gh}" "$@"; }

# Print the current head sha, node id and draft state of the pull request, one per line so
# that a missing value stays an empty field instead of shifting the next one into its place.
# The head sha of a fork pull request is one of the fork's commits.
pr_state() {  # base repo, pull request number
  gh_cli api "repos/$1/pulls/$2" \
    --jq '(.head.sha // ""), (.node_id // ""), (.draft | tostring)'
}

# Print present or absent for the file at a ref; return 1 when GitHub cannot say.
marker_state() {  # repo, ref
  local err
  if err="$(gh_cli api -X GET "repos/$1/contents/$marker_path" -f ref="$2" 2>&1 >/dev/null)"; then
    printf 'present'
  elif [[ "$err" == *"HTTP 404"* ]]; then
    printf 'absent'
  else
    return 1
  fi
}

# Did this commit add the file? 0 yes, 1 no, 2 cannot tell.
commit_added_marker() {  # repo, commit sha
  local changes
  changes="$(gh_cli api "repos/$1/commits/$2" --jq '.files[]? | .status + " " + .filename')" \
    || return 2
  grep -qxF "added $marker_path" <<<"$changes"
}

# Report whether the pull request carries a marking commit: 0 yes, 1 no, 2 cannot tell,
# 3 the list GitHub returned is full, so a no would be unprovable.
marker_commit_state() {  # base repo, pull request number
  local commits sha author committer verified subject wanted added listed=0
  wanted="$(marker_commit_subject "$2")"
  commits="$(gh_cli api --paginate "repos/$1/pulls/$2/commits?per_page=100" \
    --jq '.[] | [.sha, (.author.login // ""), (.committer.login // ""),
                 (.commit.verification.verified | tostring),
                 (.commit.message | split("\n")[0])] | @tsv')" || return 2
  while IFS=$'\t' read -r sha author committer verified subject; do
    [[ -n "$sha" ]] || continue
    listed=$((listed + 1))
    [[ "$subject" == "$wanted" && "$author" == "$marker_commit_author" \
       && "$committer" == "$marker_commit_committer" && "$verified" == true ]] || continue
    commit_added_marker "$1" "$sha"
    added=$?
    (( added == 2 )) && return 2
    (( added == 0 )) && return 0
  done <<<"$commits"
  (( listed >= marker_commit_list_limit )) && return 3
  return 1
}

# Add the file and print the commit it created.
add_marker() {  # repo, branch, pull request number
  jq -n --arg content "$(marker_content)"$'\n' --arg branch "$2" \
    --arg message "$(marker_commit_subject "$3")" \
    '{message: $message, content: ($content | @base64), branch: $branch}' \
    | gh_cli api -X PUT "repos/$1/contents/$marker_path" --input - --jq '.commit.sha'
}

# That commit runs no workflow, so report the gate on it here or nothing ever will. Statuses
# belong to the base repository, which is also the only repository this step ever marks.
mark_commit_unreviewed() {  # base repo, commit sha
  jq -n --arg context "$status_context" --arg description "$status_description" \
    '{state: "failure", context: $context, description: $description}' \
    | gh_cli api -X POST "repos/$1/statuses/$2" --input - >/dev/null
}

# Take the merge button away. Draft is the only block that needs no branch protection and
# the only one that reaches a fork. Never the reverse: a person marks it ready.
draft_pull_request() {  # node id
  # shellcheck disable=SC2016  # $id is a GraphQL variable, bound by -f id below
  gh_cli api graphql -f query='
      mutation($id: ID!) {
        convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } }
      }' -f id="$1" >/dev/null
}

fail_closed() {
  printf 'pr-unreviewed-file: %s\n' "$1" >&2
  exit 2
}

event_file="${1:-}"
command -v jq >/dev/null 2>&1 || fail_closed "jq is required"
command -v "${GH_BIN:-gh}" >/dev/null 2>&1 || fail_closed "${GH_BIN:-gh} is required"
[[ -n "$event_file" && -r "$event_file" ]] || fail_closed "cannot read event file ${event_file:-<none>}"
if ! identity="$(jq -er '
    if (.pull_request | type) != "object" then error("no pull_request object")
    else [(.repository.full_name // ""), ((.pull_request.number // "") | tostring),
          (.pull_request.head.repo.full_name // ""), (.pull_request.head.ref // "")] | @tsv end' \
    "$event_file" 2>/dev/null)"; then
  fail_closed "$event_file is not a readable pull request event"
fi
IFS=$'\t' read -r base_repo number head_repo head_ref <<<"$identity"
# The head repository, not the base: a fork's branch name can match a base branch. The
# event's own sha is deliberately unused; every read below is of the current state.
[[ "$base_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
   && "$head_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
   && "$number" =~ ^[1-9][0-9]*$ && -n "$head_ref" ]] \
  || fail_closed "unexpected repositories, number, or branch in $event_file"

state="$(pr_state "$base_repo" "$number")" \
  || fail_closed "could not read $base_repo#$number"
{ IFS= read -r head_sha; IFS= read -r node_id; IFS= read -r is_draft; } <<<"$state"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ && -n "$node_id" ]] \
  || fail_closed "unexpected head or id for $base_repo#$number"

# Exit 1 after taking the merge button away. The failing verdict itself is this job's own
# check run, which GitHub puts on the head of the pull request.
report_unreviewed() {  # closing line
  if [[ "$is_draft" != true ]] && ! draft_pull_request "$node_id"; then
    printf 'pr-unreviewed-file: could not convert %s#%s to a draft; the failing gate is the only block left\n' \
      "$base_repo" "$number" >&2
  fi
  printf 'Unreviewed: %s\n' "$1" >&2
  printf 'Read the diff, delete %s in a commit, then mark this pull request ready.\n' "$marker_path" >&2
  exit 1
}

# Nothing to mark on a fork's branch, which this token cannot write. Draft still applies.
if [[ "$head_repo" != "$base_repo" ]]; then
  report_unreviewed "this pull request comes from $head_repo, where this workflow's token cannot commit $marker_path."
fi

marker="$(marker_state "$head_repo" "$head_sha")" \
  || fail_closed "could not look up $marker_path at $head_repo@$head_sha"
[[ "$marker" == present ]] && report_unreviewed "$marker_path is still in this pull request."

# Absent is only reviewed when this pull request was marked and the mark was deleted.
marker_commit_state "$base_repo" "$number"
case $? in
  0) printf '%s was added and then deleted in this pull request.\n' "$marker_path"; exit 0 ;;
  2) fail_closed "could not read the commits of $base_repo#$number" ;;
  3) fail_closed "$base_repo#$number lists $marker_commit_list_limit commits, all GitHub returns for a pull request, and none of them marked it: a marking commit past that end would be invisible here. Squash or split the branch to get under that many." ;;
esac

marked_sha="$(add_marker "$head_repo" "$head_ref" "$number")" \
  || fail_closed "could not add $marker_path to $head_repo:$head_ref"
[[ "$marked_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail_closed "adding $marker_path returned no commit for $head_repo:$head_ref"
mark_commit_unreviewed "$base_repo" "$marked_sha" \
  || fail_closed "could not report $status_context on $base_repo@$marked_sha"
report_unreviewed "$marker_path was just added to this pull request."
