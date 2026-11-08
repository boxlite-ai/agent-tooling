#!/usr/bin/env bash
# Print one JSON object for the live PR diff. On uncertainty, emit no paths.
set -uo pipefail

die() { printf 'pr-watch-scope: %s\n' "$*" >&2; exit 1; }
sha='^[0-9a-f]{40}$'
url_pattern='^https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*$'
[[ $# == 2 && "$1" =~ $url_pattern && "$2" =~ $sha ]] ||
  die 'usage: pr-watch-scope.sh PR_URL EXPECTED_HEAD'
url="$1"
head="$2"
export GIT_NO_REPLACE_OBJECTS=1
grafts="$(git rev-parse --git-path info/grafts)" || die 'cannot inspect Git grafts'
[[ -n "$grafts" && ! -e "$grafts" && ! -L "$grafts" ]] || die 'local Git grafts prevent checking PR scope'
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || die 'complete Git history is required'
[[ "$(git rev-parse HEAD)" == "$head" ]] || die 'local head does not match the watched PR'

watch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || die 'cannot locate the command runner'
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/tooling-command.sh
source "$watch_dir/../lib/tooling-command.sh" || die 'cannot load the command runner'
now="$(date +%s)" || die 'cannot establish a lookup deadline'
deadline=$((now + 20))

live_refs() {
  tooling_command "$deadline" gh pr view "$url" --json url,state,baseRefOid,headRefOid |
    jq -rse --arg url "$url" --arg head "$head" '
      select(length == 1) | .[0]
      | select(.url == $url and .state == "OPEN" and .headRefOid == $head)
      | .baseRefOid | strings | select(test("\\A[0-9a-f]{40}\\z"))
    '
}

base="$(live_refs)" || die 'cannot bind the live PR base and head'
merge_base="$(tooling_command "$deadline" git merge-base --all "$base" "$head")" ||
  die 'fetch the live PR base and retry'
[[ "$merge_base" =~ $sha ]] || die 'PR merge base is ambiguous'
result="$(tooling_command "$deadline" git diff --name-only --no-relative --find-renames --no-ext-diff \
  --no-textconv --ignore-submodules=none -z "$merge_base" "$head" -- |
  perl -MEncode=decode,FB_CROAK,LEAVE_SRC -0777 -ne 'decode("UTF-8", $_, FB_CROAK | LEAVE_SRC); print' |
  jq -cRs --arg base "$base" --arg head "$head" \
    '{base:$base,head:$head,paths:(split("\u0000") | map(select(length>0)))}')" ||
  die 'cannot read the complete PR diff'
[[ "$(live_refs)" == "$base" && "$(git rev-parse HEAD)" == "$head" ]] ||
  die 'PR or local refs changed while reading the diff'
printf '%s\n' "$result"
