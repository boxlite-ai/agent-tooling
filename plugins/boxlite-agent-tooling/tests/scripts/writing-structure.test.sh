#!/usr/bin/env bash
# Tests for scripts/writing-structure.sh: a commit is refused only for structure
# violations it adds to staged Markdown (design #575).
#
# Run with:  bash tests/scripts/writing-structure.test.sh
# Exits non-zero on any failure.
set -uo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin/tests/lib/assert.sh"
check="$plugin/scripts/writing-structure.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
git init -q -b main "$repo"
commit() { git -C "$repo" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.test commit -qm "$1"; }

two='First sentence here. Second sentence here.'
four="$two Third sentence here. Fourth sentence here."
five="$four Fifth sentence here."
doc() {  # file, body: a heading plus one prose block
  printf '# Title\n\n%s\n' "$2" > "$repo/$1"
}
run() {  # -> sets out, err, rc
  out="$(bash "$check" commit "$repo" 2>"$scratch/err")"; rc=$?
  err="$(cat "$scratch/err")"
}

doc guide.md "$two"
doc legacy.md "$four"
printf 'echo ok\n' > "$repo/tool.sh"
{ printf '# Long\n'; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf '\nShort paragraph %s.\n' "$n"; done; printf '\n%s\n' "$four"; } > "$repo/long.md"
git -C "$repo" add . && commit base

echo "## Nothing staged, or nothing added"
run; check_eq "a clean index passes" "$rc" 0
doc legacy.md "$four"
printf '\nA new short line.\n' >> "$repo/legacy.md"
git -C "$repo" add legacy.md
run; check_eq "an old violation beside an unrelated edit passes" "$rc:$out" "0:"

echo "## Added violations are refused"
doc guide.md "$four"
git -C "$repo" add guide.md
run
check_eq "a new four-sentence block is refused" "$rc" 1
check_eq "the report names file, rule, count and limit" \
  "$(grep -c '^guide.md: prose 4 (limit 3): First sentence here' <<<"$out")" 1
check_eq "the old violation in the other staged file stays unreported" "$(grep -c '^legacy.md' <<<"$out")" 0
doc legacy.md "$five"
git -C "$repo" add legacy.md
run
check_eq "an extended old violation is reported" "$(grep -c '^legacy.md: prose 5 (limit 3)' <<<"$out")" 1
git -C "$repo" reset -q --hard

echo "## A new file is measured against nothing"
doc fresh.md "$four"
git -C "$repo" add fresh.md
run; check_eq "a new violating file is refused" "$rc:$(grep -c '^fresh.md: prose 4' <<<"$out")" "1:1"
git -C "$repo" reset -q --hard

echo "## A renamed file is compared with its old path"
git -C "$repo" mv long.md moved.md
printf '\nAnother short paragraph.\n' >> "$repo/moved.md"
git -C "$repo" add moved.md
run; check_eq "an old violation that follows a rename is not reported" "$rc:$out" "0:"
printf '\nAlpha one here. Alpha two here. Alpha three here. Alpha four here.\n' >> "$repo/moved.md"
git -C "$repo" add moved.md
run
check_eq "a block added to a renamed file is reported under the new path" \
  "$rc:$(grep -c '^moved.md: prose 4 (limit 3): Alpha one here' <<<"$out"):$(grep -c '' <<<"$out")" "1:1:1"
git -C "$repo" reset -q --hard

echo "## Skips"
doc guide.md "$four"
git -C "$repo" add guide.md
out="$(COMMIT_WRITING_CHECK=0 bash "$check" commit "$repo" 2>/dev/null)"; rc=$?
check_eq "the rollback switch skips the check" "$rc:$out" "0:"
out="$(bash "$check" push "$repo" 2>/dev/null)"; rc=$?
check_eq "a push is not checked" "$rc:$out" "0:"
git -C "$repo" rev-parse HEAD > "$repo/.git/MERGE_HEAD"
run; check_eq "a merge in progress is skipped" "$rc:$out" "0:"
rm -f "$repo/.git/MERGE_HEAD"
git -C "$repo" rev-parse HEAD > "$repo/.git/CHERRY_PICK_HEAD"
run; check_eq "a cherry-pick in progress is skipped" "$rc:$out" "0:"
rm -f "$repo/.git/CHERRY_PICK_HEAD"
git -C "$repo" reset -q --hard
printf 'echo changed\n' > "$repo/tool.sh"
git -C "$repo" add tool.sh
run; check_eq "a commit without Markdown passes" "$rc:$out" "0:"
git -C "$repo" reset -q --hard
out="$(bash "$check" commit "$scratch" 2>/dev/null)"; rc=$?
check_eq "a directory outside any repository passes" "$rc" 0

echo "## Unmeasurable input fails closed"
head -c 1048577 /dev/zero | tr '\0' 'a' > "$repo/huge.md"
git -C "$repo" add huge.md
run
check_eq "an oversized staged file is an error" "$rc" 2
check_eq "the error names the file" "$(grep -c 'cannot measure huge.md' <<<"$err")" 1

assert_result
