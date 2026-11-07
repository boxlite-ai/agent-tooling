#!/usr/bin/env bash
# The claim check for commit/push audit text (design #407): the gate's writer names
# files by hash, rewrites them, and prunes old ones; the reader prints a task only when
# its size and hash match a regular, non-symlinked file.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
reader="$plugin/scripts/read-audit-task.sh"
pass=0 fail=0
holds() { # description, command... -> passes when the command succeeds
  local description="$1"
  shift
  if "$@"; then printf 'PASS %s\n' "$description"; pass=$((pass+1))
  else printf 'FAIL %s\n' "$description"; fail=$((fail+1)); fi
}
exits() { # description, wanted status, command...
  local description="$1" wanted="$2" status=0
  shift 2
  "$@" || status=$?
  holds "$description (exit $status)" test "$status" = "$wanted"
}
write() { # state directory, text -> pointer JSON from the production writer
  bash -c 'source "$1/.agents/lib/verdict-audit-state.sh" && source "$1/.agents/lib/audit-task-file.sh" &&
    audit_task_file_write "$2" "$3"' write "$plugin" "$1" "$2"
}
read_task() { # pointer JSON -> reader status; output in $scratch/out
  bash "$reader" "$(jq -r .path <<<"$1")" "$(jq -r .sha256 <<<"$1")" "$(jq -r .bytes <<<"$1")" \
    > "$scratch/out" 2> "$scratch/err"
}
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
recent() { [[ -n "$(find "$1" -mmin -5)" ]]; }
pruned() { [[ ! -e "$1" && -f "$2" ]]; }
silent_reject() { ! read_task "$1" && [[ ! -s "$scratch/out" ]]; }

mkdir -p "$scratch/state"
task=$'Audit one blocked Git operation.\n\nUNTRUSTED_TASK_INPUT_JSON:\n{"operation_kind":"commit"}\n'
pointer="$(write "$scratch/state" "$task")"
holds 'the writer returns a pointer' test -n "$pointer"
path="$(jq -r .path <<<"$pointer")"
holds 'the file is named by its SHA-256' \
  test "$path" = "$scratch/state/audit-tasks/$(jq -r .sha256 <<<"$pointer").md"
holds 'the file is private to its owner' test "$(mode_of "$path")" = 600
exits 'a matching file is read' 0 read_task "$pointer"
holds 'the reader prints the exact task bytes' test "$(cat "$scratch/out"; printf x)" = "${task}x"

# Rewriting refreshes the timestamp, so age-based pruning cannot remove a named file.
touch -t 202001010000 "$path"
write "$scratch/state" "$task" >/dev/null
holds 'an identical task is rewritten, refreshing its age' recent "$path"
old="$(write "$scratch/state" 'an older task')"
touch -t 202001010000 "$(jq -r .path <<<"$old")"
write "$scratch/state" "$task" >/dev/null
holds 'writes prune files older than 5 hours and keep the current one' \
  pruned "$(jq -r .path <<<"$old")" "$path"

printf 'tampered' >> "$path"
holds 'an edited file is rejected with no output' silent_reject "$pointer"
write "$scratch/state" "$task" >/dev/null
rm "$path"
exits 'a missing file is rejected' 1 read_task "$pointer"
printf '%s' "$task" > "$scratch/real"
ln -s "$scratch/real" "$path"
exits 'a symlinked file is rejected' 1 read_task "$pointer"
rm "$path"; mkfifo "$path"
exits 'a FIFO is rejected without waiting' 1 read_task "$pointer"
rm "$path"
write "$scratch/state" "$task" >/dev/null
exits 'a wrong size is rejected' 1 read_task "$(jq -c '.bytes = 5' <<<"$pointer")"
exits 'malformed arguments are refused' 2 bash "$reader" "$path" not-a-hash 10
ln -s "$scratch/state" "$scratch/linked"
exits 'the writer refuses a symlinked state directory' 1 write "$scratch/linked" "$task"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
