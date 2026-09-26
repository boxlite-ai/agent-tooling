#!/usr/bin/env bash
# Start/recover a producer independently of the invoking execution session.
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pr-watch-state.sh
source "$script_dir/../lib/pr-watch-state.sh" || exit 127
branch="" sha="" pr=""
while (( $# )); do
  [[ $# -ge 2 ]] || { printf 'pr-watch-start: missing argument\n' >&2; exit 2; }
  case "$1" in
    --branch) branch="$2" ;;
    --sha) sha="$2" ;;
    --pr) pr="$2" ;;
    *) printf 'pr-watch-start: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift 2
done
[[ "${BOXLITE_PR_WATCH:-1}" != 0 ]] || exit 0
[[ -z "$pr" || "$pr" =~ ^[1-9][0-9]*$ ]] || exit 2
[[ -n "$branch" || -n "$pr" ]] || {
  printf 'usage: pr-watch-start.sh --branch NAME [--sha SHA] [--pr NUMBER]\n' >&2
  exit 2
}
[[ -n "$branch" ]] || branch="pr-$pr"
for dependency in git jq perl shasum gh; do
  command -v "$dependency" >/dev/null || exit 127
done
directory="$(git rev-parse --absolute-git-dir)/pr-watch" || exit 1
mkdir -p "$directory" || exit 1
id="$(pr_watch_start "$script_dir/pr-watch.sh" "$directory" "$branch" "$sha" "$pr")" \
  || exit 1
key="$(pr_watch_branch_key "$branch")" || exit 1
jq -nc --arg watch_id "$id" --arg event_log "$directory/$key.jsonl" \
  '{watch_id:$watch_id,event_log:$event_log}'
