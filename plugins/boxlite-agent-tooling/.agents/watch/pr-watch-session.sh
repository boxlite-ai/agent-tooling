#!/usr/bin/env bash
# Reconcile durable watch intent and return a bounded delivery batch.
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pr-watch-state.sh
source "$script_dir/../lib/pr-watch-state.sh" || exit 127
# shellcheck source=../lib/verdict-audit-state.sh
source "$script_dir/../lib/verdict-audit-state.sh" || exit 127
# shellcheck source=../lib/pr-watch-pending.sh
source "$script_dir/../lib/pr-watch-pending.sh" || exit 127
locked=0 start=0 cancel=0 branch="" pr="" acknowledgments=()
result=0
trap 'result=$?; if (( result != 0 && result != 75 )); then
  printf "pr-watch-session: branch %s reconciliation failed (exit %s)\n" "$branch" "$result" >&2
fi' EXIT
original_arguments=("$@")
while (( $# )); do
  case "$1" in
    --locked) locked=1; shift ;;
    --start) start=1; shift ;;
    --cancel) cancel=1; shift ;;
    --branch|--pr|--ack)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in
        --branch) branch="$2" ;;
        --pr) pr="$2" ;;
        --ack) acknowledgments+=("$2") ;;
      esac
      shift 2 ;;
    *) printf 'pr-watch-session: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -z "$pr" || "$pr" =~ ^[1-9][0-9]*$ ]] || exit 2
[[ -n "$branch" ]] || { printf 'pr-watch-session: --branch is required\n' >&2; exit 2; }
for dependency in git jq perl shasum gh; do
  command -v "$dependency" >/dev/null || exit 127
done
git_directory="$(git rev-parse --absolute-git-dir)" || exit 1
directory="$git_directory/pr-watch"
mkdir -p "$directory" || exit 1
directory_identity="$(pr_watch_state_directory_identity "$directory")" || exit 1
key="$(pr_watch_branch_key "$branch")" || exit 1
record="$directory/$key.monitor.json"
lock="$directory/$key.monitor.lock"
if (( ! locked )); then
  pr_watch_prepare_regular_file "$lock" "$directory_identity" || exit 1
  # The descriptor lease survives this exec and is released by process teardown.
  # Detached producers close it; a dead consumer cannot strand recovery.
  exec perl -MFcntl=:DEFAULT,:flock -MPOSIX -e '
    my ($path, @command) = @ARGV;
    sysopen(my $fh, $path, O_RDWR | O_NONBLOCK | O_NOFOLLOW) or exit 1;
    my @opened = stat($fh); my @named = lstat($path);
    exit 1 unless -f $fh && @named && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX | LOCK_NB) or exit 75;
    POSIX::dup2(fileno($fh), 8) >= 0 or exit 1;
    exec @command or exit 127;
  ' "$lock" bash "$0" --locked "${original_arguments[@]}"
fi
# An internal recursive invocation must carry the exact locked descriptor.
perl -MFcntl=:flock -e '
  open(my $fh, "<&=8") or exit 1;
  my @opened = stat($fh); my @named = lstat($ARGV[0]);
  exit 1 unless @opened && @named && -f $fh && !-l $ARGV[0]
    && $opened[0] == $named[0] && $opened[1] == $named[1];
  flock($fh, LOCK_EX | LOCK_NB) or exit 1;
' "$lock" || exit 1
now="$(date +%s)" || exit 1
remote="$(git remote get-url origin)" || exit 1
lifetime="${PR_WATCH_MAX_LIFETIME:-604800}"
[[ "$lifetime" =~ ^[1-9][0-9]*$ && ${#lifetime} -le 7 && "$lifetime" -le 2678400 ]] || {
  printf 'pr-watch-session: lifetime must be 1..2678400 seconds\n' >&2; exit 2;
}
state=""
if [[ -e "$record" || -L "$record" ]]; then
  snapshot="$(verdict_audit_read_json_snapshot "$record")" || exit 1
  state="${snapshot#*$'\n'}"
  jq -e --arg branch "$branch" --arg remote "$remote" '
    type == "object" and .schema == 1 and .branch == $branch and .remote == $remote
    and (.enabled | type == "boolean") and (.pr | type == "string" and test("^(|[1-9][0-9]*)$"))
    and (.watch_id | type == "string")
    and all(.deadline,.retry_at,.started_at,.last_poll,.attempts;
      type == "number" and floor == . and . >= 0 and . < 100000000000)
    and .attempts <= 3' <<< "$state" >/dev/null || exit 1
  stored_pr="$(jq -r '.pr' <<< "$state")"
  [[ -z "$pr" || -z "$stored_pr" || "$pr" == "$stored_pr" ]] || {
    printf 'pr-watch-session: PR identity changed; use a separate branch binding\n' >&2; exit 1;
  }
  [[ -n "$pr" ]] || pr="$stored_pr"
elif (( ! start )); then
  printf 'pr-watch-session: no watch intent; register with --start first\n' >&2
  exit 1
fi
if (( start )) && { [[ -z "$state" ]] || [[ "$(jq -r '.enabled' <<< "$state")" == false ]]; }; then
  state="$(jq -nc --arg branch "$branch" --arg remote "$remote" --arg pr "$pr" \
    --argjson deadline "$((now + lifetime))" \
    '{schema:1,branch:$branch,remote:$remote,pr:$pr,enabled:true,deadline:$deadline,
      retry_at:0,started_at:0,last_poll:0,attempts:0,watch_id:""}')" || exit 1
fi
state="$(jq -c --arg pr "$pr" '.pr=$pr' <<< "$state")" || exit 1
pending="$directory/$key.pending"
events="$(pr_watch_pending read "$pending")" || exit 1
for event_id in ${acknowledgments[@]+"${acknowledgments[@]}"}; do
  pr_watch_pending ack "$pending" "$event_id" || exit 1
done
owner="" pid="" live=0 health="" status=starting
if snapshot="$(verdict_audit_read_json_snapshot "$directory/$key.lock/owner.json" 2>/dev/null)"; then
  owner="${snapshot#*$'\n'}"
  pid="$(jq -er '.pid | select(type == "number" and floor == . and . > 0)' <<< "$owner" 2>/dev/null)" || pid=""
  token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" || token=""
  if [[ -n "$token" ]] && jq -e --arg token "$token" \
      '.schema == 1 and .ready == true and .start_token == $token
       and (.watch_id | test("^watch-[0-9a-f]{24}$"))' <<< "$owner" >/dev/null; then
    live=1
  fi
fi
if (( cancel )) || [[ "${BOXLITE_PR_WATCH:-1}" == 0 ]] \
    || (( now >= $(jq -r '.deadline' <<< "$state") )); then
  state="$(jq -c '.enabled=false' <<< "$state")" || exit 1
fi
if jq -e --arg pr "$pr" 'any(.[];
    .kind == "watch_end" and ($pr == "" or .pr == $pr)
    and (.reason == "PR MERGED" or .reason == "PR CLOSED"))' <<< "$events" >/dev/null; then
  state="$(jq -c '.enabled=false' <<< "$state")" || exit 1
fi
if [[ "$(jq -r '.enabled' <<< "$state")" == false ]]; then
  # Persist cancellation before signaling; a crash cannot resurrect the intent.
  printf '%s\n' "$state" | verdict_audit_write_atomic "$record" || exit 1
  (( ! live )) || kill -TERM "$pid" 2>/dev/null || true
  status=stopped
elif (( live )); then
  id="$(jq -r '.watch_id' <<< "$owner")"
  state="$(jq -c --arg id "$id" --argjson now "$now" '
    if .watch_id != $id then .watch_id=$id | .started_at=$now else . end' <<< "$state")" || exit 1
  if snapshot="$(verdict_audit_read_json_snapshot "$directory/$key.health.json" 2>/dev/null)"; then
    health="${snapshot#*$'\n'}"
  fi
  status=waiting
  (( now - $(jq -r '.started_at' <<< "$state") < 180 )) || status=degraded
  if jq -e --arg id "$id" --argjson now "$now" \
      '.watch_id == $id and (.last_successful_poll | type == "number")
       and .last_successful_poll <= $now and .last_successful_poll >= ($now - 180)' \
      <<< "$health" >/dev/null 2>&1; then
    status=healthy
    poll="$(jq -r '.last_successful_poll' <<< "$health")"
    state="$(jq -c --argjson poll "$poll" --argjson now "$now" '
      if $poll > .last_poll and $now - .started_at >= 60 then .attempts=0 | .retry_at=0 else . end
      | .last_poll=$poll' <<< "$state")" || exit 1
  fi
else
  retry_at="$(jq -r '.retry_at' <<< "$state")"
  status=degraded
  if (( now >= retry_at )); then
    attempts="$(jq -r '.attempts' <<< "$state")"
    (( attempts >= 3 )) || attempts=$((attempts + 1))
    case "$attempts" in 1) delay=60 ;; 2) delay=120 ;; *) delay=900 ;; esac
    state="$(jq -c --argjson attempts "$attempts" --argjson retry "$((now + delay))" \
      '.attempts=$attempts | .retry_at=$retry' <<< "$state")" || exit 1
    # Reserve the attempt before launching, including a crash during readiness.
    printf '%s\n' "$state" | verdict_audit_write_atomic "$record" || exit 1
    remaining=$(( $(jq -r '.deadline' <<< "$state") - now ))
    if id="$(PR_WATCH_MAX_LIFETIME="$remaining" pr_watch_start \
        "$script_dir/pr-watch.sh" "$directory" "$branch" "" "$pr")"; then
      status=starting
      state="$(jq -c --arg id "$id" --argjson now "$now" \
        '.watch_id=$id | .started_at=$now' <<< "$state")" || exit 1
    fi
  fi
fi
[[ "$(pr_watch_state_directory_identity "$directory")" == "$directory_identity" ]] || exit 1
printf '%s\n' "$state" | verdict_audit_write_atomic "$record" || exit 1
events="$(pr_watch_pending read "$pending")" || exit 1
jq -nc --arg status "$status" --argjson state "$state" --argjson events "$events" \
  '{status:$status,watch_id:$state.watch_id,deadline:$state.deadline,
    retry_at:$state.retry_at,events:($events | sort_by(.ts) | .[0:16])}'
