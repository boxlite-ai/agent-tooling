#!/usr/bin/env bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
usage='Use gh-write.sh GROUP OPERATION --body-file PATH [gh arguments] or --notes-file PATH for releases.'
group="${1:-}"
operation="${2:-}"
case "$group:$operation" in
  issue:create|issue:edit|issue:comment|pr:comment|pr:review) text_option=body ;;
  release:create|release:edit) text_option=notes ;;
  *) fail "$usage" ;;
esac
shift 2
file_option="$text_option-file"
case "${1:-}" in
  "--$file_option"|-F) (( $# >= 2 )) || fail "$usage"; path="$2"; shift 2 ;;
  "--$file_option="*|-F=*) path="${1#*=}"; shift ;;
  -F?*) path="${1#-F}"; shift ;;
  *) fail "$usage" ;;
esac

for dependency in gh jq perl; do
  command -v "$dependency" >/dev/null 2>&1 || fail "gh-write: $dependency is required."
done
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.agents/lib" && pwd -P)"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/github-body-file.sh
source "$lib/github-body-file.sh"
# shellcheck source=../.agents/lib/reply-summary.sh
source "$lib/reply-summary.sh"
# shellcheck source=../.agents/lib/concise-writing.sh
source "$lib/concise-writing.sh"
# shellcheck source=../.agents/lib/github-writing.sh
source "$lib/github-writing.sh"

# The writing policy checks the text. The launcher also limits other sources
# and release assets before any command can use the original argv.
status=0
_github_writing_parse "gh $group $operation" "$(_github_writing_spec "$group:$operation")" "$@" >&2 || status=$?
case "$status" in
  0) ;;
  2) fail 'Help is unavailable in a guarded write.' ;;
  *) printf '\n' >&2; exit 2 ;;
esac
for option in ${_github_writing_options[@]+"${_github_writing_options[@]}"}; do
  case "$option" in
    "$text_option="*|"$file_option="*) fail 'Use one checked text source.' ;;
    delete-last=true) fail 'A guarded comment cannot delete the last comment.' ;;
  esac
done
if [[ "$group" == release ]]; then
  (( ${#_github_writing_operands[@]} == 1 )) && [[ -n "${_github_writing_operands[0]}" ]] \
    || fail 'Supply exactly one tag. A guarded release write does not upload assets.'
fi

github_body_file_read "$path" 'GitHub text file' || fail "$github_body_file_error"
reason="$(github_writing_check 1 "$group" "$operation" "--$text_option=$github_body_file_text" "$@")" || {
  status=$?
  (( status == 1 )) || { printf '%s\n' "$reason" >&2; exit "$status"; }
  guidance="$(concise_writing_reminder)" || exit 2
  fail "$reason"$'\n\n'"$guidance"
}
printf '%s' "$github_body_file_text" | exec gh "$group" "$operation" "--$file_option=-" "$@"
