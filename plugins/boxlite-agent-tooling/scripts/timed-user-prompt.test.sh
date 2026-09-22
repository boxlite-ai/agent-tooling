#!/usr/bin/env bash
# Test the public CLI with a deterministic clock; no real three-minute sleeps.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$plugin/scripts/timed-user-prompt.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/state with spaces"
export CONFIRMATION_TEST_CLOCK="$scratch/clock"
printf '1000\n' > "$CONFIRMATION_TEST_CLOCK"
cat > "$scratch/bin/date" <<'CLOCK'
#!/usr/bin/env bash
cat "$CONFIRMATION_TEST_CLOCK"
CLOCK
chmod +x "$scratch/bin/date"
export PATH="$scratch/bin:$PATH"
state="$scratch/state with spaces/request.json"
spec='{"binding":{"head":"first"},"prefix":"reviewed:","fallback":"keep-draft","minimum_words":1}'
run() { bash "$cli" "$@"; }
expect() { jq -e "$2" <<<"$1" >/dev/null || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; }
reject() { if run "$@" >"$scratch/out" 2>"$scratch/err"; then printf 'FAIL: accepted %s\n' "$1" >&2; exit 1; fi; }

request="$(run request "$state" "$spec")"
id="$(jq -r .id <<<"$request")"
expect "$request" '.status == "pending" and .deadline == 1180'
printf '1100\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$state" "$spec")" ".id == \"$id\" and .deadline == 1180"
reject respond "$state" "$id" 'yes'
reject respond "$state" "$id" 'reviewed: '
reject respond "$state" "$id" $'reviewed: text\nextra'
expect "$(run status "$state" "$id")" '.status == "pending" and .deadline == 1180'
printf '1179\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run respond "$state" "$id" 'reviewed: verified the size boundary')" '.status == "accepted"'
printf '1181\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "accepted"'
expect "$(run consume "$state" "$id")" '.status == "consumed"'
reject consume "$state" "$id"
request="$(run request "$state" "$spec")"
next_id="$(jq -r .id <<<"$request")"
[[ "$next_id" != "$id" ]]
reject respond "$state" "$id" 'reviewed: stale reply'
printf '1361\n' > "$CONFIRMATION_TEST_CLOCK"
reject respond "$state" "$next_id" 'reviewed: at the deadline'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1361'
expect "$(run fallback "$state" "$next_id")" '.fallback_delivered and .spec.fallback == "keep-draft"'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1361'

size_spec='{"binding":{"head":"second"},"prefix":"pr-size-exception:","fallback":"split","minimum_words":12}'
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
reject respond "$state" "$next_id" 'reviewed: superseded'
reject respond "$state" "$id" 'pr-size-exception: urgent'
reason='pr-size-exception: This dependency update regenerates 612 lockfile lines; splitting it from the manifest leaves the dependency graph inconsistent.'
expect "$(run respond "$state" "$id" "$reason")" '.status == "accepted" and .spec.fallback == "split"'
[[ "$(run status "$state" "$id" | jq -r .response)" == "$reason" ]]
printf '1\n' > "$CONFIRMATION_TEST_CLOCK"
reject status "$state" "$id"
printf '2000\n' > "$CONFIRMATION_TEST_CLOCK"

for type in symlink fifo directory malformed; do
  unsafe="$scratch/state with spaces/$type"
  case "$type" in
    symlink) ln -s "$state" "$unsafe" ;;
    fifo) mkfifo "$unsafe" ;;
    directory) mkdir "$unsafe" ;;
    malformed) printf '{}\n' > "$unsafe" ;;
  esac
  reject request "$unsafe" "$spec"
done
reject request "$scratch/state with spaces/invalid" '{}'
request="$(run request "$scratch/state with spaces/valid-record" "$spec")"
for mutation in '.status="accepted"' '.fallback_delivered=true' '.extra="unexpected"'; do
  jq "$mutation" <<<"$request" > "$scratch/state with spaces/bad-record"
  reject request "$scratch/state with spaces/bad-record" "$spec"
done
for index in 1 2 3 4; do
  run request "$scratch/state with spaces/concurrent" "$spec" >"$scratch/$index.json" &
done
wait
[[ "$(jq -sr '[.[].id] | unique | length' "$scratch/"[1-4].json)" == 1 ]]
expect "$(cat "$scratch/1.json")" '.deadline == 2180'
printf '2200\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$scratch/state with spaces/concurrent" "$spec")" '.status == "expired" and .deadline == 2180'
printf 'timed-user-prompt: all lifecycle, deadline, unsafe-state, and concurrency checks passed\n'
