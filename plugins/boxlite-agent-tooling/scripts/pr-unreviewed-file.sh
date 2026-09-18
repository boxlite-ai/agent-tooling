#!/usr/bin/env bash
# CI step: commit UNREVIEWED.md to a new pull request's branch, and fail while the PR head
# still has it. A person deletes the file in a commit after reading the diff. A PR merged
# without that brings the file onto the default branch, where it says so even if this
# check has since been removed.
#
#   pr-unreviewed-file.sh <github-event.json>
#
# A missing file means "reviewed" only when the pull request carries a marking commit
# GitHub signed for its own bot and whose diff added the file. Every event the workflow
# listens for marks a pull request that has none, so a first run that failed, or a pull
# request older than this workflow, cannot pass unmarked.
#
# Every read is of current state — the pull request's head sha and its commits — because a
# queued run holding an older event sha would otherwise pass a head that still has the file.
# Exit 0 when the file was added and then deleted, 1 otherwise, 2 when the event cannot be
# read or GitHub cannot be queried or updated: CI must not pass an unknown state.
# GH_BIN overrides the gh executable (tests). Needs jq and an authenticated gh.
#
# Four properties of GitHub shape this:
#   - The gate is a commit status on the head, not this job's own check run. The workflow
#     runs from the base branch under pull_request_target, which associates its run with
#     the base sha, so nothing this job reports by itself reaches the commit a merge looks
#     at.
#   - Statuses belong to the base repository even for a fork's head commit, which lives
#     there as refs/pull/<number>/head. The token cannot write the fork's branch, so a fork
#     pull request is reported unreviewed rather than passed unmarked.
#   - A commit made with that token starts no workflow run, so the marking commit would
#     otherwise leave the new head with no result at all.
#   - A pull request lists at most 250 commits. Past that end a marking commit is invisible
#     and its absence proves nothing, so the step says so rather than marking forever.
#
# Tests: bash scripts/pr-unreviewed-file.test.sh
set -uo pipefail

marker_path="UNREVIEWED.md"
marker_commit_subject="chore: mark pull request unreviewed"
# What a pull request author cannot produce: GitHub signs the commits its own token makes,
# for the bot that made them. A subject, a file body and a commit status are all things an
# author can write themselves, so none of the three is proof on its own.
marker_commit_author="github-actions[bot]"
# The most commits GitHub lists for a pull request.
marker_commit_list_limit=250
# The job name in .github/workflows/unreviewed-pr.yml: branch protection matches a status
# to a check run by this one name, so both report under the same gate.
status_context="Author reviewed the PR"
status_present_description="$marker_path is in this pull request"

marker_content() {
  printf '%s\n' \
    '# Unreviewed' \
    '' \
    'Nobody has reviewed this pull request yet. After reading the diff, delete this file in a commit.' \
    '' \
    'If this file is on the default branch, the pull request that added it was merged without review.'
}

gh_cli() { "${GH_BIN:-gh}" "$@"; }

# Print the pull request's current head sha, a fork's own commit when it comes from one.
pr_head_sha() {  # base repo, pull request number
  gh_cli api "repos/$1/pulls/$2" --jq '.head.sha'
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
  local commits sha author verified subject added listed=0
  commits="$(gh_cli api --paginate "repos/$1/pulls/$2/commits?per_page=100" \
    --jq '.[] | [.sha, (.author.login // ""), (.commit.verification.verified | tostring),
                 (.commit.message | split("\n")[0])] | @tsv')" || return 2
  while IFS=$'\t' read -r sha author verified subject; do
    [[ -n "$sha" ]] || continue
    listed=$((listed + 1))
    [[ "$subject" == "$marker_commit_subject" && "$author" == "$marker_commit_author" \
       && "$verified" == true ]] || continue
    commit_added_marker "$1" "$sha"
    added=$?
    (( added == 2 )) && return 2
    (( added == 0 )) && return 0
  done <<<"$commits"
  (( listed >= marker_commit_list_limit )) && return 3
  return 1
}

# Add the file and print the commit it created.
add_marker() {  # repo, branch
  jq -n --arg content "$(marker_content)"$'\n' --arg branch "$2" --arg message "$marker_commit_subject" \
    '{message: $message, content: ($content | @base64), branch: $branch}' \
    | gh_cli api -X PUT "repos/$1/contents/$marker_path" --input - --jq '.commit.sha'
}

# Report the gate on one commit of the base repository, a fork's head sha included.
report_status() {  # base repo, commit sha, state, description
  jq -n --arg context "$status_context" --arg state "$3" --arg description "$4" \
    '{context: $context, state: $state, description: $description}' \
    | gh_cli api -X POST "repos/$1/statuses/$2" --input - >/dev/null
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

report_unreviewed() {  # closing line
  printf 'Unreviewed: %s\n' "$1" >&2
  printf 'Read the diff, then delete %s in a commit.\n' "$marker_path" >&2
  exit 1
}

head_sha="$(pr_head_sha "$base_repo" "$number")" \
  || fail_closed "could not read the head of $base_repo#$number"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || fail_closed "unexpected head sha for $base_repo#$number"

# Nothing to mark on a fork's branch, and a silent gate is worse than a red one.
if [[ "$head_repo" != "$base_repo" ]]; then
  report_status "$base_repo" "$head_sha" failure "a fork's branch cannot be marked from here" \
    || fail_closed "could not report $status_context on $base_repo@$head_sha"
  report_unreviewed "this pull request comes from $head_repo, where this workflow's token cannot commit $marker_path."
fi

state="$(marker_state "$head_repo" "$head_sha")" \
  || fail_closed "could not look up $marker_path at $head_repo@$head_sha"
if [[ "$state" == present ]]; then
  report_status "$base_repo" "$head_sha" failure "$status_present_description" \
    || fail_closed "could not report $status_context on $base_repo@$head_sha"
  report_unreviewed "$marker_path is still in this pull request."
fi

# Absent is only reviewed when this pull request was marked and the mark was deleted.
marker_commit_state "$base_repo" "$number"
case $? in
  0)
    report_status "$base_repo" "$head_sha" success "$marker_path was added and then deleted" \
      || fail_closed "could not report $status_context on $base_repo@$head_sha"
    printf '%s was added and then deleted in this pull request.\n' "$marker_path"
    exit 0
    ;;
  2) fail_closed "could not read the commits of $base_repo#$number" ;;
  3) fail_closed "$base_repo#$number lists $marker_commit_list_limit commits, all GitHub returns for a pull request, and none of them marked it: a marking commit past that end would be invisible here. Squash or split the branch to get under that many." ;;
esac

marked_sha="$(add_marker "$head_repo" "$head_ref")" \
  || fail_closed "could not add $marker_path to $head_repo:$head_ref"
[[ "$marked_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail_closed "adding $marker_path returned no commit for $head_repo:$head_ref"
report_status "$base_repo" "$marked_sha" failure "$status_present_description" \
  || fail_closed "could not report $status_context on $base_repo@$marked_sha"
report_unreviewed "$marker_path was just added to this pull request."
