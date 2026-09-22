#!/usr/bin/env bash
# GitHub text policy over literal argv supplied by the hook's shell scanner.
# Requires reply-summary.sh, perl and jq. No execution, file reads or writes.
# Public checks print a bounded diagnostic on rejection and return 1; success is
# silent. The caller renders the shared reply-summary prompt and host response.
# CLI flag reference: cli/cli pkg/cmd/pr/comment/comment.go:107-114.
# https://github.com/cli/cli/blob/trunk/pkg/cmd/pr/comment/comment.go#L107-L114
# shellcheck disable=SC2154 # Policy constants are owned by sourced reply-summary.sh.

github_writing_check_body() { # body
  local body="$1" density=0
  if [[ "$body" != *[![:space:]]* ]]; then
    printf 'GitHub text is empty.'
    return 1
  fi
  # Bound work before invoking the Markdown counter, including unbroken tokens.
  if (( ${#body} > 8000 )); then
    printf 'GitHub text is too long.'
    return 1
  fi
  if ! reply_summary_fits_restatement "$body"; then
    printf 'GitHub text exceeds the reply-summary limit of %s words or could not be counted.' \
      "$reply_summary_restatement_max_words"
    return 1
  fi
  reply_summary_is_dense "$body" || density=$?
  case "$density" in
    1) return 0 ;;
    0) printf 'GitHub text has a paragraph over %s words or a list item over %s words.' \
         "$reply_summary_paragraph_max_words" "$reply_summary_item_max_words" ;;
    *) printf 'GitHub text could not be counted.' ;;
  esac
  return 1
}

_github_writing_opaque() {
  printf 'GitHub text must be inspectable before posting. Use literal --body/--notes or API body= text; prepare generated text first.'
  return 1
}

_github_writing_api() { # literal-argv(0|1), api argv
  local literal="$1" token value key method="" endpoint="" query="" input=0 has_fields=0
  local bodies=() body_count=0
  shift
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --method|-X|--input|--field|-F|--raw-field|-f|--hostname|--header|-H|--jq|-q|--template|-t|--cache)
        (( $# )) || { _github_writing_opaque; return 1; }
        value="$1"; shift ;;
      --*=*) value="${token#*=}"; token="${token%%=*}" ;;
      -[XfF]?*) value="${token:2}"; value="${value#=}"; token="${token:0:2}" ;;
      --paginate|--slurp|--silent|--include|-i|--verbose) continue ;;
      -*) _github_writing_opaque; return 1 ;;
      *) endpoint="$token"; continue ;;
    esac
    case "$token" in
      --method|-X) method="$value" ;;
      --input) input=1 ;;
      --field|-F|--raw-field|-f)
        has_fields=1
        key="${value%%=*}"; value="${value#*=}"
        case "$key" in
          query) query="$value" ;;
          body|bodyText|description|notes|*'[body]'|*'[bodyText]'|*'[description]')
            if [[ ( "$token" == --field || "$token" == -F ) && "$value" == @* ]]; then
              input=1
            else
              bodies[body_count]="$value"; body_count=$((body_count + 1))
            fi ;;
        esac ;;
    esac
  done
  case "$method" in GET|HEAD|OPTIONS|DELETE) return 0 ;; esac
  # Without fields/input gh defaults to GET, even with a dynamic endpoint.
  if [[ -z "$method" ]] && (( !has_fields && !input )); then return 0; fi
  (( literal )) || { _github_writing_opaque; return 1; }
  if [[ "$endpoint" == graphql ]]; then
    # GraphQL can bury published text in a query or arbitrary variable names.
    # Only text-publishing mutations need the REST/CLI form; resolving a review
    # thread, for example, does not publish prose and stays outside this policy.
    local text_mutation='(addComment|updateIssueComment|createIssue|updateIssue|updatePullRequest|addPullRequestReview|addPullRequestReviewComment|addPullRequestReviewThread|updatePullRequestReview|updatePullRequestReviewComment|submitPullRequestReview|createDiscussion|updateDiscussion|addDiscussionComment|updateDiscussionComment)[[:space:]]*\('
    if (( input )) || [[ "$query" =~ $text_mutation ]]; then
      _github_writing_opaque; return 1
    fi
    return 0
  fi
  # API fields imply POST unless --method says otherwise. Restrict opaque-input
  # rejection to endpoints which can publish writing, not arbitrary API work.
  if (( input )) && [[ "$endpoint" =~ (^|/)(issues|pulls|comments|releases|discussions)(/|$|\?) ]]; then
    _github_writing_opaque; return 1
  fi
  (( has_fields )) || return 0
  for value in ${bodies[@]+"${bodies[@]}"}; do
    github_writing_check_body "$value" || return 1
  done
}

github_writing_check() { # literal-argv(0|1), gh arguments after global options
  local literal="$1" group="${2-}" operation="${3-}" token value
  local required=0 has_body=0 has_option=0 deleting=0
  shift
  # gh persistent flags can occur between its noun and verb as well as before it.
  if [[ "$group" != api ]]; then
    shift
    while (( $# )); do
      case "$1" in
        --repo|-R|--hostname) (( $# >= 2 )) || return 0; shift 2 ;;
        --repo=*|-R?*|--hostname=*) shift ;;
        *) break ;;
      esac
    done
    operation="${1-}"
    set -- "$group" "$@"
  fi
  case "$group:$operation" in
    pr:create)
      # Non-draft create/edit already have a stricter parser in the review gate;
      # that path calls check_body too. Drafts need writing checks without an ack.
      case "${3-}" in --draft|-d|--draft=true|-d=true) ;; *) return 0 ;; esac
      required=1 ;;
    pr:edit|pr:ready) return 0 ;;
    issue:create|discussion:create|release:create|pr:comment|issue:comment|discussion:comment) required=1 ;;
    issue:edit|discussion:edit|release:edit|pr:review|pr:close|issue:close|pr:reopen|issue:reopen) ;;
    api:*)
      shift
      _github_writing_api "$literal" "$@"
      return $? ;;
    *) return 0 ;;
  esac
  (( literal )) || { _github_writing_opaque; return 1; }
  shift 2
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --body|-b|--notes|-n|--comment|-c)
        # --comment/-c on pr review is a boolean, on close/reopen it is text.
        if [[ "$group:$operation" == pr:review && ( "$token" == --comment || "$token" == -c ) ]]; then
          required=1; has_option=1; continue
        fi
        (( $# )) || { _github_writing_opaque; return 1; }
        value="$1"; shift ;;
      --body=*|--notes=*|--comment=*) value="${token#*=}" ;;
      -[bnc]?*) value="${token:2}"; value="${value#=}" ;;
      --body-file|--body-file=*|-F*|--notes-file|--notes-file=*|--editor|-e|--web|-w|--fill*|-f|--template|--template=*|-T*|--recover*|--generate-notes|--notes-from-tag)
        _github_writing_opaque; return 1 ;;
      --delete-last) deleting=1; has_option=1; continue ;;
      --help|-h) return 0 ;;
      --draft|--draft=*|-d|-d=*|--prerelease|-p|--latest|--latest=*|--verify-tag|--fail-on-no-commits|--edit-last|--create-if-none|--yes|--approve|--request-changes|--delete-branch|--dry-run|--no-maintainer-edit|--remove-milestone|--discussion-id=*)
        has_option=1; continue ;;
      -a|-r)
        if [[ "$group:$operation" != pr:review ]]; then
          (( $# )) || { _github_writing_opaque; return 1; }
          shift
        fi
        has_option=1; continue ;;
      --title|-t|--repo|-R|--hostname|--label|-l|--assignee|--milestone|-m|--project|--reviewer|--base|-B|--head|-H|--target|--notes-start-tag|--discussion-category|--category|--reason|--add-label|--remove-label|--add-assignee|--remove-assignee|--add-project|--remove-project)
        (( $# )) || { _github_writing_opaque; return 1; }
        shift; has_option=1; continue ;;
      --title=*|--repo=*|--hostname=*|--label=*|--assignee=*|--milestone=*|--project=*|--reviewer=*|--base=*|--head=*|--target=*|--notes-start-tag=*|--discussion-category=*|--category=*|--reason=*|--add-*=*|--remove-*=*|-t?*|-R?*|-l?*|-m?*|-B?*|-H?*)
        has_option=1; continue ;;
      -*) _github_writing_opaque; return 1 ;;
      *) continue ;;
    esac
    github_writing_check_body "$value" || return 1
    has_body=1; has_option=1
  done
  if (( (required && !has_body && !deleting) || !has_option )); then
    _github_writing_opaque; return 1
  fi
  return 0
}
