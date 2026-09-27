#!/usr/bin/env bash
set -euo pipefail
library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-watch-schedule.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
before="$PWD:$-"
# shellcheck source=pr-watch-schedule.sh
source "$library" > "$scratch/source.out"
[[ "$before" == "$PWD:$-" && ! -s "$scratch/source.out" ]] || exit 1
export SCHEDULE_TEST_LOG="$scratch/calls"
cat > "$scratch/session.sh" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} != --keepalive ]] || shift
[[ $# == 4 && $1 == --branch && $3 == --pr ]] || exit 2
printf '%s\n' "$2" >> "$SCHEDULE_TEST_LOG"
case "$2" in
  busy) exit 75 ;;
  broken) exit 1 ;;
  stopped) printf '{"status":"stopped","events":[]}\n' ;;
  malformed) printf '{"status":"healthy","events":null}\n' ;;
  bad-id) printf '{"status":"healthy","events":[{"kind":"comment","event_id":"invalid"}]}\n' ;;
  oversized) jq -nc '{status:"healthy",events:[range(17) | {kind:"comment",event_id:("a" * 64)}]}' ;;
  degraded) printf '{"status":"degraded","events":[]}\n' ;;
  event) printf '{"status":"stopped","events":[{"kind":"watch_end","event_id":"%064d","reason":"PR MERGED"}]}\n' 0 ;;
  *) printf '{"status":"healthy","events":[]}\n' ;;
esac
EOF
targets="$(jq -nc --arg worktree "$scratch" \
  '["busy","stopped","$(touch should-not-exist)"] | map({worktree:$worktree,branch:.})')"
result="$(pr_watch_schedule_tick "$scratch/session.sh" "$targets")"
[[ "$result" == '{"active":2,"stopped":1}' && ! -e "$scratch/should-not-exist" ]] || exit 1
[[ "$(wc -l < "$scratch/calls" | tr -d ' ')" == 3 ]] || exit 1
printf 'PASS: library is inert; busy leases defer and target strings remain data\n'

for invalid in '[]' '[{}]' "{} $targets" \
  "$(jq '.[1].branch=42' <<< "$targets")" \
  "$(jq '.[1].pr=false' <<< "$targets")" \
  "$(jq '.[1].worktree="relative"' <<< "$targets")" \
  "$(jq '[range(33) as $i | .[0]]' <<< "$targets")"; do
  : > "$scratch/calls"
  if pr_watch_schedule_tick "$scratch/session.sh" "$invalid" > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
  [[ "$rc" == 2 && ! -s "$scratch/out" && ! -s "$scratch/calls" && -s "$scratch/err" ]] || exit 1
done
printf 'PASS: all targets validate before any reconciliation\n'

targets="$(jq '.[0].branch="broken"' <<< "$targets")"
if pr_watch_schedule_tick "$scratch/session.sh" "$targets" > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
[[ "$rc" == 1 && ! -s "$scratch/out" && -s "$scratch/err" ]] || exit 1
[[ "$(wc -l < "$scratch/calls" | tr -d ' ')" == 3 ]] || exit 1
printf 'PASS: failed targets remain errors while independent targets still run\n'

targets="$(jq -nc --arg worktree "$scratch" '[{worktree:$worktree,branch:"event",pr:"42"}]')"
result="$(pr_watch_schedule_tick "$scratch/session.sh" "$targets" events)"
jq -e 'any(.events[]?; .kind == "watch_end") and .target.pr == "42" and .status == "stopped"' <<< "$result" >/dev/null || {
  printf 'FAIL: scheduled delivery omitted the stopped target terminal event\n' >&2; exit 1;
}
for branch in healthy stopped; do
  quiet="$(jq --arg branch "$branch" '.[0].branch=$branch' <<< "$targets")"
  pr_watch_schedule_tick "$scratch/session.sh" "$quiet" events > "$scratch/out" 2> "$scratch/err"
  [[ ! -s "$scratch/out" && ! -s "$scratch/err" ]] || exit 1
done
busy="$(jq '.[0].branch="busy"' <<< "$targets")"
if pr_watch_schedule_tick "$scratch/session.sh" "$busy" events > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
[[ "$rc" == 75 && ! -s "$scratch/out" && ! -s "$scratch/err" ]] || exit 1
printf 'PASS: terminal events carry bindings; empty reads stay silent; busy reads defer retirement\n'
for branch in broken malformed bad-id oversized degraded; do
  mixed="$(jq --arg branch "$branch" '.[0].branch=$branch | . + [.[0] | .branch="event"]' <<< "$targets")"
  if pr_watch_schedule_tick "$scratch/session.sh" "$mixed" events > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
  [[ "$rc" == 1 && -s "$scratch/err" ]] || exit 1
  jq -e '.target.branch == "event"' "$scratch/out" >/dev/null
done
printf 'PASS: delivery errors preserve independent target events and signal lost coverage\n'
