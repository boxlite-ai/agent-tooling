#!/usr/bin/env bash
# CI step: commit UNREVIEWED.md to a new pull request's branch, and fail while the PR head
# still has it. A person deletes the file in a commit after reading the diff. A PR merged
# without that brings the file onto the default branch, where it says so even if this
# check has since been removed.
#
#   pr-unreviewed-file.sh <github-event.json>
#
# A missing file means "reviewed" only when the pull request carries the commit that added
# it. Every event the workflow listens for marks a pull request that does not, so a first
# run that failed, or a pull request older than this workflow, cannot pass unmarked. The
# marking commit is proof of ceremony, not of reading: it must carry this file's canonical
# content and the gate status posted by this workflow.
#
# Both reads are live — the branch tip and the pull request's current commits — because a
# queued run holding an older event sha would otherwise pass a tip that still has the file.
# Exit 0 when the file was added and then deleted, 1 otherwise, 2 when the event cannot be
# read or GitHub cannot be queried or updated: CI must not pass an unknown state.
# GH_BIN overrides the gh executable (tests). Needs jq and an authenticated gh.
#
# Two properties of GitHub shape this:
#   - The token belongs to the base repository, so a fork's branch cannot be written. A
#     fork pull request is reported unreviewed rather than passed unmarked.
#   - A commit made with that token starts no workflow run, so the marking commit would
#     leave the new head with no result at all. The status is posted on it directly.
#
# Tests: bash scripts/pr-unreviewed-file.test.sh
set -uo pipefail

marker_path="UNREVIEWED.md"
# The subject of the commit that adds the file.
marker_commit_subject="chore: mark pull request unreviewed"
# The job name in .github/workflows/unreviewed-pr.yml: branch protection matches a status
# to a check run by this one name, so the marking commit reports under the same gate.
status_context="Author reviewed the PR"
status_description="$marker_path is in this pull request"

marker_content() {
  printf '%s\n' \
    '# Unreviewed' \
    '' \
    'Nobody has reviewed this pull request yet. After reading the diff, delete this file in a commit.' \
    '' \
    'If this file is on the default branch, the pull request that added it was merged without review.'
}

gh_cli() { "${GH_BIN:-gh}" "$@"; }

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

# Report whether the pull request carries the marking commit: 0 yes, 1 no, 2 cannot tell.
marker_commit_state() {  # repo, pull request number
  local commits sha subject marker
  commits="$(gh_cli api --paginate "repos/$1/pulls/$2/commits" \
    --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv')" || return 2
  while IFS=$'\t' read -r sha subject; do
    [[ "$subject" == "$marker_commit_subject" ]] || continue
    marker="$(marker_state "$1" "$sha")" || return 2
    [[ "$marker" == present ]] || continue
    marker_content_matches "$1" "$sha" || {
      [[ "$?" == 1 ]] && continue
      return 2
    }
    marker_statused_unreviewed "$1" "$sha" || {
      [[ "$?" == 1 ]] && continue
      return 2
    }
    return 0
  done <<<"$commits"
  return 1
}

# Return 0 when the file at ref carries this script's canonical marker body.
marker_content_matches() {  # repo, ref
  local encoded content expected
  encoded="$(gh_cli api -X GET "repos/$1/contents/$marker_path" -f ref="$2" --jq '.content' 2>/dev/null)" \
    || return 2
  content="$(printf '%s' "$encoded" | tr -d '\n' | base64 --decode 2>/dev/null)" || return 2
  expected="$(marker_content)"
  [[ "$content" == "$expected" ]]
}

# Return 0 when commit sha has this workflow's unreviewed status on it.
marker_statused_unreviewed() {  # repo, commit sha
  if gh_cli api -X GET "repos/$1/commits/$2/status" 2>/dev/null \
    | jq -er --arg context "$status_context" --arg description "$status_description" '
        .statuses[]? | select(.context == $context and .state == "failure" and .description == $description)
      ' >/dev/null; then
    return 0
  fi
  [[ "$?" == 1 ]] && return 1
  return 2
}

# Add the file and print the commit it created.
add_marker() {  # repo, branch
  jq -n --arg content "$(marker_content)"$'\n' --arg branch "$2" --arg message "$marker_commit_subject" \
    '{message: $message, content: ($content | @base64), branch: $branch}' \
    | gh_cli api -X PUT "repos/$1/contents/$marker_path" --input - --jq '.commit.sha'
}

# That commit runs no workflow, so report the gate on it here or nothing ever will.
mark_commit_unreviewed() {  # repo, commit sha
  jq -n --arg context "$status_context" --arg description "$status_description" \
    '{state: "failure", context: $context, description: $description}' \
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

if [[ "$head_repo" != "$base_repo" ]]; then
  report_unreviewed "this pull request comes from $head_repo, where this workflow's token cannot commit $marker_path."
fi

# The branch, not the event's sha: a queued run must not pass a tip that has the file.
state="$(marker_state "$head_repo" "$head_ref")" \
  || fail_closed "could not look up $marker_path on $head_repo:$head_ref"
[[ "$state" == present ]] && report_unreviewed "$marker_path is still in this pull request."

# Absent is only reviewed when this pull request was marked and the mark was deleted.
marker_commit_state "$base_repo" "$number"
case $? in
  0) printf '%s was added and then deleted in this pull request.\n' "$marker_path"; exit 0 ;;
  2) fail_closed "could not read the commits of $base_repo#$number" ;;
esac

marked_sha="$(add_marker "$head_repo" "$head_ref")" \
  || fail_closed "could not add $marker_path to $head_repo:$head_ref"
[[ "$marked_sha" =~ ^[0-9a-f]{40}$ ]] \
  || fail_closed "adding $marker_path returned no commit for $head_repo:$head_ref"
mark_commit_unreviewed "$head_repo" "$marked_sha" \
  || fail_closed "could not report $status_context on $head_repo@$marked_sha"
report_unreviewed "$marker_path was just added to this pull request."
