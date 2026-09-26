#!/usr/bin/env bash
# Exercise the production launcher across caller process-group teardown.
set -uo pipefail
watch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
starter="$watch_dir/pr-watch-start.sh"
scratch="$(mktemp -d)"
producer_pid=""
caller_pid=""
cleanup() {
  [[ -z "$caller_pid" ]] || kill -KILL -- "-$caller_pid" 2>/dev/null || true
  [[ -z "$producer_pid" ]] || kill -TERM "$producer_pid" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT
# Do not let a parent worktree's Git environment select the real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
mkdir "$scratch/repo" "$scratch/bin"
git init -q "$scratch/repo"
git -C "$scratch/repo" remote add origin https://github.com/example/fixture.git
export PR_WATCH_TEST_FIXTURE="$scratch"
cat > "$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') cat "$PR_WATCH_TEST_FIXTURE/view.json" ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
export PR_WATCH_INTERVAL=1 PR_WATCH_MAX_LIFETIME=20 PR_WATCH_COMMAND_TIMEOUT=3
unset BOXLITE_PR_WATCH
printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","comments":[],"reviews":[]}' \
  > "$scratch/view.json"
mkfifo "$scratch/ready"
exec 7<> "$scratch/ready"
perl -MPOSIX -e 'POSIX::setsid() >= 0 or die $!; exec @ARGV or die $!;' \
  bash -c '
    cd "$1" || exit 1
    bash "$2" --branch fixture --pr 42 > "$3" || exit 1
    printf "ready\n" >&7
    exec sleep 20
  ' -- "$scratch/repo" "$starter" "$scratch/binding.json" \
  > "$scratch/caller.log" 2>&1 &
caller_pid=$!
if ! IFS= read -r -t 8 -u 7 ready || [[ "$ready" != ready ]]; then
  printf 'FAIL: launcher did not publish readiness\n'
  cat "$scratch/caller.log"
  exit 1
fi
event_log="$(jq -er '.event_log' "$scratch/binding.json")" || exit 1
watch_id="$(jq -er '.watch_id' "$scratch/binding.json")" || exit 1
producer_pid="$(jq -er '.pid' "${event_log%.jsonl}.lock/owner.json")" || exit 1
kill -KILL -- "-$caller_pid"
wait "$caller_pid" 2>/dev/null || true
caller_pid=""
printf '%s\n' '{"state":"OPEN","mergeable":"CONFLICTING","headRefOid":"head-1","baseRefOid":"base-1","comments":[],"reviews":[]}' \
  > "$scratch/view.json"
deadline=$((SECONDS + 6))
while (( SECONDS < deadline )); do
  if jq -e 'select(.kind == "conflict")' "$event_log" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$producer_pid" 2>/dev/null || break
  # Poll the asynchronous journal with a deadline, not a timing assertion.
  sleep 0.1
done
if ! jq -e --arg id "$watch_id" \
  'select(.kind == "conflict" and .watch_id == $id and .head_sha == "head-1")' \
  "$event_log" >/dev/null; then
  printf 'FAIL: conflict was not emitted after caller process-group cleanup\n'
  exit 1
fi
printf 'PASS: conflict survives caller process-group cleanup\n'
cd "$scratch/repo" || exit 1
repeat="$(bash "$starter" --branch fixture --pr 42)" || exit 1
[[ "$(jq -r '.watch_id' <<< "$repeat")" == "$watch_id" ]] || {
  printf 'FAIL: repeat start replaced the live generation\n'; exit 1;
}
printf 'PASS: repeat start reuses the live generation\n'
[[ -z "$(BOXLITE_PR_WATCH=0 bash "$starter" --pr 42)" ]] || exit 1
printf 'PASS: start honors opt-out\n'
