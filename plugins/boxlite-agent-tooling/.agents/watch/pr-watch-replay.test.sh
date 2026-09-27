#!/usr/bin/env bash
set -uo pipefail
watch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR BOXLITE_PR_WATCH
mkdir "$scratch/repo" "$scratch/bin"
git init -q "$scratch/repo"
git -C "$scratch/repo" remote add origin https://github.com/example/fixture.git
cat > "$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') printf '%s\n' '{"state":"OPEN","mergeable":"CONFLICTING","headRefOid":"head-1","baseRefOid":"base-1","comments":[],"reviews":[{"id":"review-1","author":{"login":"reviewer"},"state":"APPROVED"},{"id":"review-2","author":{"login":"reviewer"},"state":"APPROVED"}]}' ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
cd "$scratch/repo" || exit 1
bash "$watch_dir/pr-watch.sh" --pr 42 --once > "$scratch/first.jsonl" || exit 1
jq -e 'select(.kind == "conflict")' "$scratch/first.jsonl" >/dev/null || exit 1
bash "$watch_dir/pr-watch.sh" --pr 42 --once >/dev/null || exit 1
# The adapter reads either generation journals or pending records. On the old
# contract the second generation has erased the only unread conflict.
available="$(find .git/pr-watch -type f \( -name '*.jsonl' -o -name 'event-*.json' \) \
  -exec cat {} + | jq -sc '[.[] | select(.kind == "conflict")] | length')"
[[ "$available" -ge 1 ]] || {
  printf 'FAIL: unread conflict lost during generation replacement\n'; exit 1;
}
printf 'PASS: unread conflict survives generation replacement\n'
[[ "${1:-}" != --retention-only ]] || exit 0
# shellcheck source=../lib/verdict-audit-state.sh
source "$watch_dir/../lib/verdict-audit-state.sh"
# shellcheck source=../lib/pr-watch-state.sh
source "$watch_dir/../lib/pr-watch-state.sh"
# shellcheck source=../lib/pr-watch-pending.sh
source "$watch_dir/../lib/pr-watch-pending.sh"
directory="$PWD/.git/pr-watch/$(pr_watch_branch_key pr-42).pending"
batch="$(pr_watch_pending read "$directory")" || exit 1
[[ "$(jq '[.[] | select(.kind == "review")] | length' <<< "$batch")" == 2 ]] || {
  printf 'FAIL: distinct reviews with identical text lost delivery identity\n'; exit 1;
}
printf 'PASS: distinct GitHub reviews retain separate delivery identities\n'
id="$(jq -r '.[] | select(.kind == "conflict") | .event_id' <<< "$batch")"
[[ "$id" =~ ^[0-9a-f]{64}$ ]] || exit 1
pr_watch_pending ack "$directory" "$id" || exit 1
pr_watch_pending ack "$directory" "$id" || exit 1
batch="$(pr_watch_pending read "$directory")" || exit 1
[[ "$(jq '[.[] | select(.kind == "conflict")] | length' <<< "$batch")" == 0 ]] || exit 1
printf 'PASS: acknowledged conflict is retired idempotently\n'
capacity_directory="$scratch/capacity"
for (( number=0; number<128; number++ )); do
  event="$(jq -nc --argjson number "$number" '{kind:"comment",body:($number|tostring)}')"
  pr_watch_pending publish "$capacity_directory" "$event" >/dev/null || exit 1
done
if pr_watch_pending publish "$capacity_directory" '{"kind":"comment","body":"overflow"}' \
    >/dev/null 2> "$scratch/capacity.error"; then
  printf 'FAIL: pending store exceeded capacity\n'; exit 1
fi
[[ "$(pr_watch_pending read "$capacity_directory" | jq length)" == 128 ]] || exit 1
[[ "$(cat "$scratch/capacity.error")" == *'capacity reached'* ]] || exit 1
printf 'PASS: full pending capacity fails visibly without removing unread events\n'
rm -f "$directory"/event-*.json
ln -s "$scratch/first.jsonl" "$directory/event-$(printf '%064d' 0).json"
if pr_watch_pending read "$directory" >/dev/null 2>&1; then
  printf 'FAIL: pending reader followed a symlink\n'; exit 1
fi
printf 'PASS: pending reader rejects unsafe records\n'
