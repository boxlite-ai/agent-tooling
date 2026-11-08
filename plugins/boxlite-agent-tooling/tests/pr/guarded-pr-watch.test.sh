#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
# shellcheck source=../../.agents/lib/pr-watch-state.sh
source "$plugin/.agents/lib/pr-watch-state.sh"
# shellcheck source=../../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
unset BOXLITE_PR_WATCH
repo="$scratch/repo with spaces"
git init -q -b feature "$repo"
git -C "$repo" remote add origin git@github.com:acme/widget.git
cd "$repo"
repo="$(pwd -P)"
id=watch-0123456789abcdef01234567
branch_key="$(pr_watch_branch_key feature)"
state="$repo/.git/pr-watch"
log="$state/$branch_key.jsonl"
lock="$state/$branch_key.lock"
mkdir -p "$lock"
token="$(verdict_audit_process_start_token "$$")"
jq -nc --argjson pid "$$" --arg token "$token" --arg id "$id" \
  '{schema:1,pid:$pid,start_token:$token,watch_id:$id,ready:true}' > "$lock/owner.json"
url=https://github.com/acme/widget/pull/42
other=https://github.com/acme/widget/pull/41
digest="$(printf '%s' "$repo" | shasum -a 256 | awk '{print $1}')"
receipt="boxlite-pr-write $digest $url"
command="bash '$plugin/scripts/gh-pr.sh' create --draft --title 'feat: checked text' --body-file 'body file.md'"
hook="$plugin/.agents/hooks/post-remote-write-watch.sh"
stream="$plugin/.agents/watch/pr-watch-stream.sh"

case_output() {  # host, command, directory, JSON response
  jq -nc --arg command "$2" --arg cwd "$repo" --arg workdir "$3" --argjson response "$4" \
    '{cwd:$cwd,tool_input:{command:$command,workdir:$workdir},tool_response:$response}' \
    | BOXLITE_HOOK_HOST="$1" bash "$hook"
}
fail() { printf 'guarded-pr-watch: %s\n' "$*" >&2; exit 1; }
structured="$(jq -nc --arg out "$url" --arg err "$receipt" '{exit_code:0,stdout:($out+"\n"),stderr:($err+"\n")}')"
merged="$(jq -nc --arg out "$url"$'\n'"$receipt" '$out')"
if [[ "${1:-}" != stream ]]; then
  claude="$(case_output claude "$command" "$repo" "$structured")"
  [[ "$claude" == *'Monitor'* && "$claude" == *"--watch-id $id --expect-pr-url $url"* ]] \
    || fail 'completed launcher write did not attach the existing Claude generation'
  codex="$(case_output codex "$command" "$repo" "$merged")"
  [[ "$codex" == *'shell session'* && "$codex" == *"--watch-id $id --expect-pr-url $url"* ]] \
    || fail 'merged launcher result did not attach the existing Codex generation'
  [[ "$(case_output claude "echo '$plugin/scripts/gh-pr.sh'" "$repo" "$structured")" == '' ]] \
    || fail 'a launcher mention attached'
  mkdir "$scratch/untrusted"
  cp "$plugin/scripts/gh-pr.sh" "$scratch/untrusted/gh-pr.sh"
  [[ "$(case_output claude "bash '$scratch/untrusted/gh-pr.sh' edit 42" "$repo" "$structured")" == '' ]] \
    || fail 'a different launcher file attached'
  [[ "$(case_output claude "$command; echo injected" "$repo" "$structured")" == '' ]] \
    || fail 'a compound invocation attached'
  [[ "$(case_output codex "$command" "$scratch/untrusted" "$merged")" == '' ]] \
    || fail 'a mismatched worktree attached'
  [[ "$(case_output codex "$command" "$repo" "$(jq '.exit_code=17' <<<"$structured")")" == '' ]] \
    || fail 'a failed write attached'
  for extra in 'Would have created a pull request:' 'Warning: output was truncated'; do
    forged="$(jq -nc --arg extra "$extra" --argjson merged "$merged" '$extra+"\n"+$merged')"
    [[ "$(case_output codex "$command" "$repo" "$forged")" == '' ]] \
      || fail 'extra or truncated output attached'
  done
fi

event() {
  jq -nc --arg id "$id" --arg kind "$1" --arg url "${2:-}" \
    '{watch_id:$id,kind:$kind,url:$url}'
}
run_stream() {
  PR_WATCH_STREAM_WAIT=2 bash "$stream" "$log" 1 --watch-id "$id" --expect-pr-url "$url"
}
{ event watch_start; event pr_found "$other"; event watch_end; } > "$log"
if output="$(run_stream)" || [[ "$output" == *"$other"* ]]; then
  fail 'existing stream delivered a different PR on the same branch'
fi
[[ "$output" == *'pr_target_mismatch'* ]] || fail 'wrong PR did not reach the target check'
{ event watch_start; event pr_found "$url"; event watch_end; } > "$log"
output="$(run_stream)" || fail 'matching generation did not replay'
[[ "$output" == *"$url"* && "$output" == *'"kind":"watch_end"'* ]] || fail 'matching events missing'
{ event watch_start; event watch_end; } > "$log"
if output="$(run_stream)"; then fail 'terminal event without a PR attached'; fi
[[ "$output" == *'pr_target_unresolved'* ]] || fail 'terminal discovery did not fail closed'
event watch_start > "$log"
PR_WATCH_STREAM_WAIT=5 bash "$stream" "$log" 1 --watch-id "$id" --expect-pr-url "$url" --ready-fd 4 \
  4>"$scratch/ready" >"$scratch/events" &
reader=$!
sleep 0.2
[[ ! -s "$scratch/ready" && ! -s "$scratch/events" ]] || fail 'stream signaled before PR discovery'
{ event pr_found "$url"; event watch_end; } >> "$log"
wait "$reader" || fail 'stream did not follow delayed discovery'
[[ "$(cat "$scratch/ready")" == ready ]] || fail 'matching stream never signaled readiness'
grep -Fq "$url" "$scratch/events" || fail 'delayed discovery did not replay'
event watch_start > "$log"
PR_WATCH_STREAM_WAIT=5 bash "$stream" "$log" 1 --watch-id "$id" --expect-pr-url "$url" \
  >"$scratch/events" &
reader=$!
sleep 0.2
{ event watch_start; event pr_found "$url"; event watch_end; } > "$log.new"
mv "$log.new" "$log"
if wait "$reader"; then fail 'replacement log attached'; fi
grep -Fq log_replaced "$scratch/events" || fail 'replacement did not reach identity check'
printf 'guarded-pr-watch: exact write, checkout, and generation passed\n'
