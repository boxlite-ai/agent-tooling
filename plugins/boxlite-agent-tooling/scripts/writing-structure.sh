#!/usr/bin/env bash
# Structure violations (the boxlite-writing limits) that a commit adds to staged Markdown.
#
#   writing-structure.sh commit [repository]
#
# Each staged *.md file the commit adds, modifies or renames is measured before and
# after; only violations absent from its HEAD version are reported, so existing text
# never blocks. A renamed file is compared with the path it was renamed from.
#
# Exit 0: nothing added, not a commit, COMMIT_WRITING_CHECK=0, or a merge, cherry-pick
#         or revert in progress.
# Exit 1: stdout lists `path: rule count (limit N): excerpt`, one line per added violation.
# Exit 2: a staged file could not be measured; stderr names it.
set -uo pipefail

[[ "${1:-commit}" == commit ]] || exit 0
[[ "${COMMIT_WRITING_CHECK:-1}" != 0 ]] || exit 0
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in git perl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'writing-structure: required command missing: %s\n' "$dependency" >&2; exit 2;
  }
done
# shellcheck source=../.agents/lib/reply-summary.sh
source "$plugin_root/.agents/lib/reply-summary.sh" || exit 2

root="$(git -C "${2:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
# These operations stage other commits' text; those commits own their violations.
for replayed in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if git -C "$root" rev-parse -q --verify "$replayed" >/dev/null 2>&1; then exit 0; fi
done

max_bytes=1048576
status=0
unmeasured() {  # path
  printf 'writing-structure: cannot measure %s\n' "$1" >&2
  status=2
}

# Reports what the staged $1 adds over HEAD's $2 (the same path unless renamed).
report_added() {  # staged path, previous path
  local path="$1" size staged previous staged_report previous_report violation rule count limit excerpt
  size="$(git -C "$root" cat-file -s ":$path" 2>/dev/null)" || size=''
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size > max_bytes )); then unmeasured "$path"; return; fi
  staged="$(git -C "$root" show ":$path" 2>/dev/null)" || { unmeasured "$path"; return; }
  previous="$(git -C "$root" show "HEAD:$2" 2>/dev/null)" || previous=''
  staged_report="$(reply_summary_structure "$staged")" || { unmeasured "$path"; return; }
  previous_report="$(reply_summary_structure "$previous")" || { unmeasured "$path"; return; }
  while IFS= read -r violation; do
    [[ -n "$violation" ]] || continue
    if grep -Fxq -- "$violation" <<<"$previous_report"; then continue; fi
    IFS=$'\t' read -r rule count limit excerpt <<<"$violation"
    printf '%s: %s %s (limit %s): %s\n' "$path" "$rule" "$count" "$limit" "$excerpt"
    (( status == 2 )) || status=1
  done <<<"$staged_report"
}

# NUL-separated name-status: `A` or `M`, then one path; `R<score>`, then old and new paths.
while IFS= read -r -d '' change; do
  IFS= read -r -d '' first || break
  case "$change" in
    R*) IFS= read -r -d '' renamed || break
        [[ "$renamed" == *.md ]] && report_added "$renamed" "$first" ;;
    *)  [[ "$first" == *.md ]] && report_added "$first" "$first" ;;
  esac
done < <(git -C "$root" diff --cached --name-status -z -M --diff-filter=AMR)

exit "$status"
