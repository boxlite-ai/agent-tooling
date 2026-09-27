#!/usr/bin/env bash
set -euo pipefail
watch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
producer_pid=""
cleanup() {
  [[ -z "$producer_pid" ]] || kill -TERM "$producer_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT
while IFS= read -r name; do unset "$name"; done < <(git rev-parse --local-env-vars)
unset BOXLITE_PR_WATCH
mkdir "$scratch/repo" "$scratch/bin"
git init -q "$scratch/repo"
git -C "$scratch/repo" remote add origin https://github.com/example/fixture.git
export PR_WATCH_TEST_FIXTURE="$scratch"
date +%s > "$scratch/clock"
real_date="$(command -v date)"
cat > "$scratch/bin/date" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == +%s ]]; then cat "\$PR_WATCH_TEST_FIXTURE/clock"; else exec '$real_date' "\$@"; fi
EOF
cat > "$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') cat "$PR_WATCH_TEST_FIXTURE/view.json" ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$scratch/bin/gh" "$scratch/bin/date"
printf '%s\n' '{"state":"OPEN","mergeable":"CONFLICTING","headRefOid":"head-1","baseRefOid":"base-1","comments":[],"reviews":[]}' > "$scratch/view.json"
export PATH="$scratch/bin:$PATH"
export PR_WATCH_INTERVAL=1 PR_WATCH_MAX_LIFETIME=1200 PR_WATCH_COMMAND_TIMEOUT=3
cd "$scratch/repo"
run() { bash "$watch_dir/pr-watch-session.sh" --branch fixture --pr 42 "$@"; }
tick() { bash "$watch_dir/pr-watch-keepalive.sh" "$targets"; }
expect_tick() {
  local actual
  actual="$(tick)" || { printf 'FAIL: scheduled reconciliation failed\n' >&2; exit 1; }
  [[ "$actual" == "$1" ]] || { printf 'FAIL: expected liveness counts, got %s\n' "$actual" >&2; exit 1; }
}
targets="$(jq -nc --arg worktree "$PWD" '[{worktree:$worktree,branch:"fixture",pr:"42"}]')"
advance() { printf '%s\n' "$(( $(cat "$scratch/clock") + $1 ))" > "$scratch/clock.next"; mv "$scratch/clock.next" "$scratch/clock"; }
first="$(run --start)"
[[ "$(jq -r .status <<< "$first")" == starting ]]
first_id="$(jq -r .watch_id <<< "$first")"
owner="$(find .git/pr-watch -path '*.lock/owner.json')"
producer_pid="$(jq -r .pid "$owner")"
deadline=$((SECONDS + 10))
while :; do
  batch="$(run)"
  jq -e 'any(.events[]; .kind == "conflict")' <<< "$batch" >/dev/null && break
  (( SECONDS < deadline )) || { printf 'FAIL: no conflict in durable batch\n'; exit 1; }
  sleep 0.1
done
[[ "$(jq -r .watch_id <<< "$batch")" == "$first_id" ]]
printf 'PASS: stateless consumer reconnects to the same producer and unread conflict\n'
# Schedule output carries liveness only; delivery stays pending for foreground turns.
expect_tick '{"active":1,"stopped":0}'
[[ "$(jq -r .pid "$owner")" == "$producer_pid" ]] || exit 1
[[ "$(run --keepalive | jq 'has("events")')" == false ]] || { printf 'FAIL: keepalive exposed events\n'; exit 1; }
[[ "$(run | jq -r '.events[] | select(.kind == "conflict") | .event_id')" == \
  "$(jq -r '.events[] | select(.kind == "conflict") | .event_id' <<< "$batch")" ]] || exit 1
for forbidden in --start --cancel '--ack event-unknown'; do
  # shellcheck disable=SC2086 # Exercise each CLI flag, including --ack's argument.
  if run --keepalive $forbidden > "$scratch/rejected" 2>&1; then exit 1; fi
done
for invalid in '[]' '[{}]' '[{"worktree":"relative","branch":"fixture"}]' \
  "$(jq '. + [{worktree:"/missing",branch:42}]' <<< "$targets")"; do
  if bash "$watch_dir/pr-watch-keepalive.sh" "$invalid" > "$scratch/out" 2> "$scratch/err"; then exit 1; else result=$?; fi
  [[ "$result" == 2 && ! -s "$scratch/out" && -s "$scratch/err" ]] || exit 1
done
printf 'PASS: schedule reuses producers, retains events, and rejects invalid inputs\n'

event_id="$(jq -r '.events[] | select(.kind == "conflict") | .event_id' <<< "$batch")"
batch="$(run --ack "$event_id")"
[[ "$(jq '[.events[] | select(.kind == "conflict")] | length' <<< "$batch")" == 0 ]]
printf 'PASS: batch acknowledgment survives a new consumer invocation\n'
for contender in 1 2; do
  (
    if run > "$scratch/contender-$contender.json"; then result=0; else result=$?; fi
    printf '%s\n' "$result" > "$scratch/contender-$contender.status"
  ) &
done
wait
for contender in 1 2; do
  result="$(cat "$scratch/contender-$contender.status")"
  [[ "$result" == 0 || "$result" == 75 ]]
  if [[ "$result" == 0 ]]; then
    [[ "$(jq -r .watch_id "$scratch/contender-$contender.json")" == "$first_id" ]]
  fi
done
printf 'PASS: concurrent reconciliation preserves the active generation\n'
kill -TERM "$producer_pid"
deadline=$((SECONDS + 5))
while kill -0 "$producer_pid" 2>/dev/null; do
  (( SECONDS < deadline )) || exit 1
  sleep 0.1
done
producer_pid=""
batch="$(run)"
[[ "$(jq -r .status <<< "$batch")" == degraded ]]
advance 61
expect_tick '{"active":1,"stopped":0}'
batch="$(run)"
second_id="$(jq -r .watch_id <<< "$batch")"
[[ "$second_id" != "$first_id" ]] || exit 1
case "$(jq -r .status <<< "$batch")" in healthy|waiting) ;; *) exit 1 ;; esac
producer_pid="$(jq -r .pid "$owner")"
printf 'PASS: failed coverage waits for backoff and starts a new generation\n'
kill -TERM "$producer_pid"
deadline=$((SECONDS + 5))
while kill -0 "$producer_pid" 2>/dev/null; do
  (( SECONDS < deadline )) || exit 1
  sleep 0.1
done
producer_pid=""
advance 121
batch="$(run)"
[[ "$(jq -r .status <<< "$batch")" == starting ]]
[[ "$(jq -r .retry_at <<< "$batch")" == "$(( $(cat "$scratch/clock") + 900 ))" ]]
producer_pid="$(jq -r .pid "$owner")"
printf 'PASS: repeated failures enter a bounded 15-minute cooldown\n'
advance 61
deadline=$((SECONDS + 10))
while :; do
  batch="$(run)"
  monitor="$(find .git/pr-watch -name '*.monitor.json')"
  [[ "$(jq -r .attempts "$monitor")" == 0 ]] && break
  (( SECONDS < deadline )) || { printf 'FAIL: health did not reset consecutive failures\n'; exit 1; }
  sleep 0.1
done
printf 'PASS: demonstrated healthy polling resets consecutive recovery failures\n'
jq '.state="MERGED"' "$scratch/view.json" > "$scratch/view.next"
mv "$scratch/view.next" "$scratch/view.json"
deadline=$((SECONDS + 10))
terminal_id=""
while [[ -z "$terminal_id" ]]; do
  terminal_id="$(find .git/pr-watch -name 'event-*.json' -exec cat {} + \
    | jq -r 'select(.kind == "watch_end" and .reason == "PR MERGED") | .event_id')"
  (( SECONDS < deadline )) || { printf 'FAIL: producer did not report closure\n'; exit 1; }
  [[ -n "$terminal_id" ]] || sleep 0.1
done
expect_tick '{"active":0,"stopped":1}'
[[ "$(run --ack "$terminal_id" | jq -r .status)" == stopped ]]
[[ "$(run | jq -r .status)" == stopped ]]
printf 'PASS: acknowledging closure cannot resurrect monitoring\n'
producer_pid=""
jq '.state="OPEN"' "$scratch/view.json" > "$scratch/view.next"
mv "$scratch/view.next" "$scratch/view.json"
run --start >/dev/null
producer_pid="$(jq -r .pid "$owner")"
run --cancel >/dev/null
expect_tick '{"active":0,"stopped":1}'
batch="$(run)"
[[ "$(jq -r .status <<< "$batch")" == stopped ]]
printf 'PASS: cancellation survives a new consumer invocation\n'
deadline=$((SECONDS + 5))
while kill -0 "$producer_pid" 2>/dev/null; do
  (( SECONDS < deadline )) || exit 1
  sleep 0.1
done
producer_pid=""
run --start > "$scratch/restarted.json"
producer_pid="$(jq -r .pid "$owner")"
advance 1201
expect_tick '{"active":0,"stopped":1}'
[[ "$(run | jq -r .status)" == stopped ]]
printf 'PASS: recovery cannot extend the monitoring deadline\n'
producer_pid=""
run --start >/dev/null
producer_pid="$(jq -r .pid "$owner")"
BOXLITE_PR_WATCH=0 expect_tick '{"active":0,"stopped":1}'
expect_tick '{"active":0,"stopped":1}'
printf 'PASS: scheduled opt-out persists without renewing intent\n'
# Keep a foreign inode intact instead of following a forged persisted state.
mv "$monitor" "$scratch/monitor.backup"
ln -s "$scratch/monitor.backup" "$monitor"
if run >/dev/null 2>&1; then printf 'FAIL: accepted unsafe watch state\n'; exit 1; fi
printf 'PASS: unsafe persisted intent fails closed\n'
