#!/usr/bin/env bash
# Replay and follow one live pr-watch generation.
#
# A branch log is append-only within one producer generation and retired at the
# next generation boundary. Every producer run marks its events with one
# watch_id; this consumer selects only the latest generation that has started
# but not ended. Use --watch-id to bind replay to one explicit generation. One
# lifetime budget covers replay plus every later poll; once it
# is exhausted the stream suppresses bodies until one final omission/terminal
# summary reports the generation's watch_end.
#
# Usage: pr-watch-stream.sh <event-log> [poll-seconds] [--watch-id <id>]
#        [--expect-pr-url <url>] [--ready-fd 4]
# Env:
#   PR_WATCH_STREAM_WAIT        seconds to wait for the file/live generation (120; hard max 3600)
#   PR_WATCH_STREAM_MAX_EVENTS  total stdout events for this consumer (64; hard max 256)
#   PR_WATCH_STREAM_MAX_BYTES   total stdout bytes for this consumer (32768; hard max 65536)
set -uo pipefail

readonly DEFAULT_POLL=5
readonly DEFAULT_WAIT=120
readonly DEFAULT_MAX_EVENTS=64
readonly DEFAULT_MAX_BYTES=32768
readonly HARD_MAX_POLL=3600
readonly HARD_MAX_WAIT=3600
readonly HARD_MAX_EVENTS=256
readonly HARD_MAX_BYTES=65536
readonly HARD_MAX_INPUT_BYTES=2097152
readonly SUMMARY_RESERVE_BYTES=512

stream_positive_decimal_is_bounded() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 18 ]]
}

log="${1:-}"
[[ -n "$log" ]] && shift
poll="$DEFAULT_POLL"
if (( $# )) && [[ "$1" != --* ]]; then
  poll="$1"
  shift
fi
requested_watch_id=""
expected_pr_url=""
ready_fd=""
while (( $# )); do
  case "$1" in
    --watch-id|--cursor)
      [[ -n "${2+set}" ]] || {
        printf 'pr-watch-stream: %s requires a value\n' "$1" >&2
        exit 2
      }
      requested_watch_id="$2"
      shift 2
      ;;
    --expect-pr-url)
      [[ -n "${2:-}" ]] || { printf 'pr-watch-stream: --expect-pr-url requires a URL\n' >&2; exit 2; }
      expected_pr_url="$2"
      shift 2
      ;;
    --ready-fd)
      [[ "${2:-}" == 4 ]] || {
        printf 'pr-watch-stream: --ready-fd requires descriptor 4\n' >&2
        exit 2
      }
      ready_fd="$2"
      shift 2
      ;;
    *)
      printf 'pr-watch-stream: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$log" ]]; then
  printf 'usage: pr-watch-stream.sh <event-log> [poll-seconds] [--watch-id <id>] [--ready-fd 4]\n' >&2
  exit 2
fi
stream_positive_decimal_is_bounded "$poll" || {
  printf 'pr-watch-stream: poll-seconds must be a positive integer\n' >&2
  exit 2
}
(( poll <= HARD_MAX_POLL )) || {
  printf 'pr-watch-stream: poll-seconds exceeds hard maximum %d\n' \
    "$HARD_MAX_POLL" >&2
  exit 2
}
if [[ -n "$requested_watch_id" \
   && ( ! "$requested_watch_id" =~ ^[A-Za-z0-9._:-]+$ \
        || ${#requested_watch_id} -gt 128 ) ]]; then
  printf 'pr-watch-stream: invalid watch-id\n' >&2
  exit 2
fi

wait_seconds="${PR_WATCH_STREAM_WAIT:-$DEFAULT_WAIT}"
max_events="${PR_WATCH_STREAM_MAX_EVENTS:-$DEFAULT_MAX_EVENTS}"
max_bytes="${PR_WATCH_STREAM_MAX_BYTES:-$DEFAULT_MAX_BYTES}"
for numeric in "$wait_seconds" "$max_events" "$max_bytes"; do
  stream_positive_decimal_is_bounded "$numeric" || {
    printf 'pr-watch-stream: limits must be positive integers\n' >&2
    exit 2
  }
done
(( wait_seconds <= HARD_MAX_WAIT )) || {
  printf 'pr-watch-stream: wait limit exceeds hard maximum %d\n' \
    "$HARD_MAX_WAIT" >&2
  exit 2
}
(( max_events <= HARD_MAX_EVENTS )) || {
  printf 'pr-watch-stream: event limit exceeds hard maximum %d\n' "$HARD_MAX_EVENTS" >&2
  exit 2
}
(( max_bytes <= HARD_MAX_BYTES )) || {
  printf 'pr-watch-stream: byte limit exceeds hard maximum %d\n' "$HARD_MAX_BYTES" >&2
  exit 2
}
(( max_events >= 2 )) || {
  printf 'pr-watch-stream: event limit must reserve one terminal summary event\n' >&2
  exit 2
}
(( max_bytes > SUMMARY_RESERVE_BYTES )) || {
  printf 'pr-watch-stream: byte limit must exceed terminal summary reserve %d\n' \
    "$SUMMARY_RESERVE_BYTES" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || {
  printf 'pr-watch-stream: jq not found\n' >&2
  exit 127
}
command -v shasum >/dev/null 2>&1 || {
  printf 'pr-watch-stream: shasum not found\n' >&2
  exit 127
}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
safe_state_helpers="$script_dir/../lib/verdict-audit-state.sh"
watch_state_helpers="$script_dir/../lib/pr-watch-state.sh"
[[ -r "$safe_state_helpers" && -r "$watch_state_helpers" ]] || {
  printf 'pr-watch-stream: state helper not found\n' >&2
  exit 127
}
# shellcheck source=../lib/verdict-audit-state.sh
source "$safe_state_helpers" || exit 127
# shellcheck source=../lib/pr-watch-state.sh
source "$watch_state_helpers" || exit 127
if [[ -n "$expected_pr_url" ]] \
   && { ! pr_watch_url_is_valid "$expected_pr_url" || ! pr_watch_id_is_valid "$requested_watch_id"; }; then
  printf 'pr-watch-stream: --expect-pr-url requires a canonical PR URL and watch ID\n' >&2
  exit 2
fi

watch_id="$requested_watch_id"
stream_sleep_pid=""
stream_sleep_pgid=""
stream_sleep_is_launching=0
stream_pending_signal=""
stream_pending_exit_code=""

stream_exit_on_signal() {  # TERM|INT exit-code
  local signal="$1" exit_code="$2" pid pgid
  if (( stream_sleep_is_launching )); then
    if [[ -z "$stream_pending_signal" ]]; then
      stream_pending_signal="$signal"
      stream_pending_exit_code="$exit_code"
    fi
    return 0
  fi
  pid="$stream_sleep_pid"
  pgid="$stream_sleep_pgid"
  stream_sleep_pid=""
  stream_sleep_pgid=""
  trap - TERM INT
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    # Job control gives this invocation one owned timer group. Escalate before
    # reaping its leader so the PGID cannot be recycled under a later process.
    kill -"$signal" -- "-$pgid" 2>/dev/null || true
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    # The direct signal also covers a child that has not completed setpgid yet.
    kill -"$signal" "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  exit "$exit_code"
}

trap 'stream_exit_on_signal TERM 143' TERM
trap 'stream_exit_on_signal INT 130' INT

stream_sleep() {  # positive-seconds
  local seconds="$1" status=0
  stream_pending_signal=""
  stream_pending_exit_code=""
  set -m
  stream_sleep_is_launching=1
  sleep "$seconds" &
  stream_sleep_pid=$!
  stream_sleep_pgid="$stream_sleep_pid"
  stream_sleep_is_launching=0
  set +m
  if [[ -n "$stream_pending_signal" ]]; then
    stream_exit_on_signal \
      "$stream_pending_signal" "$stream_pending_exit_code"
  fi
  wait "$stream_sleep_pid" 2>/dev/null || status=$?
  stream_sleep_pid=""
  stream_sleep_pgid=""
  return "$status"
}

stream_error() {
  local reason="$1" message="$2"
  jq -nc --arg reason "$reason" --arg message "$message" \
    --arg watch_id "$watch_id" \
    '{kind:"stream_error", reason:$reason, message:$message}
     + (if $watch_id == "" then {} else {watch_id:$watch_id} end)'
}

rewind_log() { perl -e 'sysseek(STDIN, 0, 0) or exit 1' <&3; }
file_size() {
  perl -e 'my @state = stat(STDIN); exit 1 unless @state && -f STDIN; print $state[7]' \
    <&3 2>/dev/null
}
file_lines() {
  rewind_log || return 1
  perl -e '
    my $max = shift;
    my ($body, $total) = ("", 0);
    while (1) {
      my $chunk = "";
      my $count = sysread(STDIN, $chunk, 65536);
      exit 1 unless defined($count);
      last if $count == 0;
      $total += $count;
      exit 1 if $total > $max;
      $body .= $chunk;
    }
    my $lines = ($body =~ tr/\n/\n/);
    print $lines;
  ' "$HARD_MAX_INPUT_BYTES" <&3 2>/dev/null
}
read_log_range() {  # first-line last-line
  rewind_log || return 1
  perl -e '
    my ($first, $last, $max) = @ARGV;
    exit 1 unless $first =~ /^[1-9][0-9]*$/
      && $last =~ /^[0-9]+$/ && $max =~ /^[1-9][0-9]*$/;
    my ($body, $total) = ("", 0);
    while (1) {
      my $chunk = "";
      my $count = sysread(STDIN, $chunk, 65536);
      exit 1 unless defined($count);
      last if $count == 0;
      $total += $count;
      exit 1 if $total > $max;
      $body .= $chunk;
    }
    my @lines = split(/\n/, $body, -1);
    pop(@lines) if @lines && $lines[-1] eq "";
    $last = scalar(@lines) if $last > scalar(@lines);
    for my $index ($first .. $last) {
      print $lines[$index - 1], "\n" if $index >= 1 && $index <= @lines;
    }
  ' "$1" "$2" "$HARD_MAX_INPUT_BYTES" <&3 2>/dev/null
}

validate_measurement() {  # bytes lines
  if [[ ! "$1" =~ ^[0-9]+$ || ! "$2" =~ ^[0-9]+$ ]]; then
    stream_error "metadata_unavailable" "cannot measure event log"
    return 1
  fi
  if (( "$1" > HARD_MAX_INPUT_BYTES )); then
    stream_error "input_limit" "event log exceeds the hard input limit"
    return 1
  fi
}

latest_live_watch_id() {
  local through_line="$1"
  (( through_line > 0 )) || return 0
  read_log_range 1 "$through_line" | jq -Rnr '
    reduce inputs as $raw ({id:"", live:false};
      (try ($raw | fromjson) catch null) as $event
      | if (($event | type) == "object"
            and ($event.kind == "watch_start")
            and (($event.watch_id // "") | type) == "string"
            and (($event.watch_id // "") != "")) then
          {id:$event.watch_id, live:true}
        elif (($event | type) == "object"
              and ($event.kind == "watch_end")
              and ($event.watch_id == .id)) then
          .live = false
        else . end)
    | if .live then .id else empty end'
}

watch_id_is_present() {
  local candidate="$1" through_line="$2"
  (( through_line > 0 )) || return 1
  read_log_range 1 "$through_line" | jq -Re \
    --arg id "$candidate" \
    'try fromjson catch null
     | select((type == "object") and (.watch_id == $id))' \
    >/dev/null 2>&1
}

# Only producer journals use the hashed branch filename and adjacent lock. Test
# fixtures and manual JSONL files remain replayable without inventing producer
# metadata, while a real generation can never turn a dead producer into silence.
producer_liveness_is_bound=0
producer_lock=""
if [[ "${log##*/}" =~ ^branch-[0-9a-f]{64}\.jsonl$ ]]; then
  producer_liveness_is_bound=1
  producer_lock="${log%.jsonl}.lock"
fi

producer_is_live() {
  local lock_identity snapshot body owner_pid owner_token current_token
  (( producer_liveness_is_bound )) || return 0
  lock_identity="$(pr_watch_state_directory_identity \
    "$producer_lock" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot \
    "$producer_lock/owner.json" 2>/dev/null)" || return 1
  [[ "$(pr_watch_state_directory_identity "$producer_lock" 2>/dev/null)" \
      == "$lock_identity" ]] || return 1
  body="${snapshot#*$'\n'}"
  printf '%s' "$body" | jq -e --arg watch_id "$watch_id" '
    type == "object"
    and (keys | sort) == ["pid","ready","schema","start_token","watch_id"]
    and .schema == 1 and .watch_id == $watch_id
    and (.pid | type == "number" and . > 0 and floor == .)
    and (.start_token | type == "string"
         and test("^cksum-[0-9]+-[0-9]+$"))
    and (.ready | type == "boolean")' >/dev/null 2>&1 || return 1
  owner_pid="$(printf '%s' "$body" | jq -r '.pid')"
  owner_token="$(printf '%s' "$body" | jq -r '.start_token')"
  current_token="$(verdict_audit_process_start_token \
    "$owner_pid" 2>/dev/null)" || return 1
  [[ "$current_token" == "$owner_token" \
     && "$(pr_watch_state_directory_identity "$producer_lock" 2>/dev/null)" \
        == "$lock_identity" ]]
}

pause_until_deadline() {  # absolute-seconds
  local target="$1" remaining pause="$poll"
  remaining=$((target - SECONDS))
  (( remaining > 0 )) || return 1
  (( pause <= remaining )) || pause="$remaining"
  stream_sleep "$pause"
}

line_fingerprint() {
  local line_number="$1"
  (( line_number > 0 )) || { printf ''; return 0; }
  read_log_range "$line_number" "$line_number" \
    | shasum -a 256 | awk '{print $1}'
}

deadline=$(( SECONDS + wait_seconds ))
while [[ ! -f "$log" ]]; do
  if [[ -e "$log" && ! -f "$log" ]]; then
    stream_error "not_regular" "event log is not a regular file"
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    stream_error "no_event_log" "event log did not appear before the wait limit"
    exit 1
  fi
  pause_until_deadline "$deadline" || true
done

# Perl selects one nonblocking, no-follow regular inode and passes it as fd 3.
# Every later read explicitly rewinds that same open description; pathname
# replacement is checked separately with lstat and is never reopened for data.
if [[ "${PR_WATCH_STREAM_OPENED_IDENTITY:-}" == "" ]]; then
  exec perl -MFcntl=:DEFAULT -MJSON::PP -MPOSIX -e '
    my ($script, $path, $poll, $watch_id, $expected_url, $ready_fd) = @ARGV;
    sub fail {
      my ($reason, $message) = @_;
      my %event = (kind => "stream_error", reason => $reason, message => $message);
      $event{watch_id} = $watch_id if defined($watch_id) && $watch_id ne "";
      print JSON::PP->new->canonical->encode(\%event), "\n";
      exit 1;
    }
    fail("not_regular", "event log is not a stable regular file")
      if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags)
      or fail("not_regular", "event log is not a stable regular file");
    my @opened = stat($fh);
    my @named = lstat($path);
    fail("not_regular", "event log is not a stable regular file")
      unless @opened && @named && -f $fh
        && $opened[0] == $named[0] && $opened[1] == $named[1];
    POSIX::dup2(fileno($fh), 3) >= 0
      or fail("metadata_unavailable", "cannot retain event log");
    open(my $stable_fh, "<&=3")
      or fail("metadata_unavailable", "cannot retain event log");
    fcntl($stable_fh, F_SETFD, 0)
      or fail("metadata_unavailable", "cannot retain event log");
    $ENV{PR_WATCH_STREAM_OPENED_IDENTITY} = $opened[0] . ":" . $opened[1];
    my @command = ("bash", $script, $path, $poll);
    push(@command, "--watch-id", $watch_id) if defined($watch_id) && $watch_id ne "";
    push(@command, "--expect-pr-url", $expected_url) if $expected_url ne "";
    push(@command, "--ready-fd", $ready_fd)
      if defined($ready_fd) && $ready_fd ne "";
    exec(@command);
    fail("metadata_unavailable", "cannot enter stable event reader");
  ' "$script_dir/pr-watch-stream.sh" "$log" "$poll" "$requested_watch_id" "$expected_pr_url" "$ready_fd"
fi

expected_identity="$PR_WATCH_STREAM_OPENED_IDENTITY"
[[ "$expected_identity" =~ ^[0-9]+:[0-9]+$ ]] || {
  stream_error "metadata_unavailable" "cannot identify event log"
  exit 1
}
opened_identity="$(perl -e '
  my @opened = stat(STDIN);
  exit 1 unless @opened && -f STDIN;
  print $opened[0], ":", $opened[1];
' <&3 2>/dev/null)" || opened_identity=""
[[ "$opened_identity" == "$expected_identity" \
   && "$(verdict_audit_path_identity "$log" 2>/dev/null)" == "$expected_identity" ]] || {
  stream_error "metadata_unavailable" "cannot identify event log"
  exit 1
}
observed_size="$(file_size)"
if [[ ! "$observed_size" =~ ^[0-9]+$ ]] \
   || (( observed_size > HARD_MAX_INPUT_BYTES )); then
  validate_measurement "$observed_size" 0 || exit 1
fi
observed_lines="$(file_lines)"
validate_measurement "$observed_size" "$observed_lines" || exit 1

refresh_startup_state() {  # timeout reason, message
  local current_identity current_size current_lines
  if (( SECONDS >= deadline )); then
    stream_error "$1" "$2"
    return 1
  fi
  pause_until_deadline "$deadline" || true
  current_identity="$(verdict_audit_path_identity "$log" 2>/dev/null)" || current_identity=""
  current_size="$(file_size)"
  if [[ ! "$current_size" =~ ^[0-9]+$ ]] \
     || (( current_size > HARD_MAX_INPUT_BYTES )); then
    validate_measurement "$current_size" 0 || exit 1
  fi
  current_lines="$(file_lines)"
  validate_measurement "$current_size" "$current_lines" || exit 1
  if [[ "$current_identity" != "$expected_identity" ]]; then
    stream_error "log_replaced" "event log identity changed while waiting"
    exit 1
  fi
  if (( current_size < observed_size )); then
    stream_error "log_truncated" "event log shrank while waiting"
    exit 1
  fi
  if (( current_lines < observed_lines )); then
    stream_error "line_regression" "event log line count regressed while waiting"
    exit 1
  fi
  observed_size="$current_size"
  observed_lines="$current_lines"
}

# A default consumer waits for a live generation. This matters when an old,
# already-ended journal exists before the newly armed producer publishes start.
while [[ -z "$watch_id" ]]; do
  watch_id="$(latest_live_watch_id "$observed_lines")"
  [[ -n "$watch_id" ]] && break
  refresh_startup_state no_live_generation "no live watch generation appeared before the wait limit" || exit 1
done

if [[ -n "$requested_watch_id" ]]; then
  while ! watch_id_is_present "$watch_id" "$observed_lines"; do
    refresh_startup_state watch_id_not_found "requested watch generation did not appear before the wait limit" || exit 1
  done
fi

if [[ -n "$expected_pr_url" ]]; then
  # Check this descriptor and generation before readiness or any replay.
  while :; do
    target="$(read_log_range 1 "$observed_lines" | jq -Rnr --arg id "$watch_id" '
      reduce inputs as $raw ("";
        ($raw | fromjson) as $event
        | if . != "" or $event.watch_id != $id then .
          elif $event.kind == "watch_end" then "ended"
          elif ($event.kind == "watch_start" or $event.kind == "pr_found")
             and ($event.url | type == "string" and length > 0) then $event.url
          else . end)
    ')" || { stream_error malformed_event "cannot identify the watched PR"; exit 1; }
    case "$target" in
      "$expected_pr_url") break ;;
      "" ) ;;
      ended) stream_error pr_target_unresolved "watch ended before identifying the PR"; exit 1 ;;
      *) stream_error pr_target_mismatch "watch generation follows another PR"; exit 1 ;;
    esac
    producer_is_live || { stream_error producer_orphaned "watch generation has no matching live producer"; exit 1; }
    refresh_startup_state pr_target_unresolved "watch did not identify the PR before the wait limit" || exit 1
  done
  if [[ "$(verdict_audit_path_identity "$log" 2>/dev/null)" != "$expected_identity" ]]; then
    stream_error log_replaced "event log identity changed before replay"
    exit 1
  fi
fi

# Attachment readiness means more than a successful Bash exec: this exact
# generation is now present in the descriptor-bound journal and can be replayed.
# Publish only after every stable-open and initial-input validation above.
if [[ -n "$ready_fd" ]]; then
  printf 'ready\n' >&4 || exit 1
  exec 4>&-
  ready_fd=""
fi

body_event_limit=$((max_events - 1))
body_byte_limit=$((max_bytes - SUMMARY_RESERVE_BYTES))
lifetime_emitted_events=0
lifetime_emitted_bytes=0
lifetime_omitted_events=0
lifetime_omitted_bytes=0
lifetime_is_closed=0
range_saw_end=0
range_error=""
terminal_reason=""

parse_event_identity() {  # JSON line
  printf '%s' "$1" | jq -er '
    if (type == "object")
       and (((.watch_id // "") | type) == "string")
       and (((.kind // "") | type) == "string")
    then [(.watch_id // ""), (.kind // "")] | @tsv
    else error("invalid event") end' 2>/dev/null
}

terminal_reason_from_event() {  # JSON line
  printf '%s' "$1" | jq -r '
    (.reason // "watch ended")
    | if type == "string" then .[0:160] else "watch ended" end' 2>/dev/null
}

emit_lifetime_summary() {
  local summary summary_bytes
  summary="$(jq -nc --arg watch_id "$watch_id" --arg reason "$terminal_reason" \
    --argjson omitted_events "$lifetime_omitted_events" \
    --argjson omitted_bytes "$lifetime_omitted_bytes" \
    --argjson max_events "$max_events" --argjson max_bytes "$max_bytes" '
      {kind:"stream_omitted",scope:"lifetime",terminal_output:true,
       watch_id:$watch_id,omitted_events:$omitted_events,omitted_bytes:$omitted_bytes,
       limits:{events:$max_events,bytes:$max_bytes},
       terminal:{kind:"watch_end",reason:$reason}}')" || return 1
  summary_bytes="$(LC_ALL=C printf '%s\n' "$summary" | wc -c | tr -d ' ')"
  [[ "$summary_bytes" =~ ^[0-9]+$ ]] || return 1
  if (( summary_bytes > SUMMARY_RESERVE_BYTES )); then
    range_error="terminal_summary_exceeds_reserve"
    return 1
  fi
  printf '%s\n' "$summary"
}

emit_initial_range() {
  local first_line="$1" last_line="$2" line parsed event_watch_id event_kind
  local line_bytes head=0 tail=0 retained_count=0 retained_bytes=0 index
  local omitted_events=0 omitted_bytes=0 retained_kind
  local -a replay_lines replay_sizes replay_kinds
  range_saw_end=0
  range_error=""
  replay_lines=()
  replay_sizes=()
  replay_kinds=()
  (( last_line >= first_line )) || return 0

  while IFS= read -r line; do
    parsed="$(parse_event_identity "$line")" || {
      range_error="malformed_event"
      return 1
    }
    event_watch_id="${parsed%%$'\t'*}"
    event_kind="${parsed#*$'\t'}"
    [[ "$event_watch_id" == "$watch_id" ]] || continue
    line_bytes="$(LC_ALL=C printf '%s\n' "$line" | wc -c | tr -d ' ')"
    if (( line_bytes > body_byte_limit )); then
      omitted_events=$((omitted_events + 1))
      omitted_bytes=$((omitted_bytes + line_bytes))
      if [[ "$event_kind" == "watch_end" ]]; then
        range_saw_end=1
        terminal_reason="$(terminal_reason_from_event "$line")"
      fi
      continue
    fi
    replay_lines[tail]="$line"
    replay_sizes[tail]="$line_bytes"
    replay_kinds[tail]="$event_kind"
    tail=$((tail + 1))
    retained_count=$((retained_count + 1))
    retained_bytes=$((retained_bytes + line_bytes))
    while (( retained_count > body_event_limit || retained_bytes > body_byte_limit )); do
      omitted_events=$((omitted_events + 1))
      omitted_bytes=$((omitted_bytes + replay_sizes[head]))
      retained_bytes=$((retained_bytes - replay_sizes[head]))
      unset 'replay_lines[head]' 'replay_sizes[head]' 'replay_kinds[head]'
      head=$((head + 1))
      retained_count=$((retained_count - 1))
    done
  done < <(read_log_range "$first_line" "$last_line")

  if (( omitted_events > 0 )); then
    lifetime_is_closed=1
    lifetime_omitted_events=$((lifetime_omitted_events + omitted_events))
    lifetime_omitted_bytes=$((lifetime_omitted_bytes + omitted_bytes))
  fi
  index="$head"
  while (( index < tail )); do
    retained_kind="${replay_kinds[index]}"
    if [[ "$retained_kind" == "watch_end" && "$lifetime_is_closed" == 1 ]]; then
      lifetime_omitted_events=$((lifetime_omitted_events + 1))
      lifetime_omitted_bytes=$((lifetime_omitted_bytes + replay_sizes[index]))
      terminal_reason="$(terminal_reason_from_event "${replay_lines[index]}")"
      range_saw_end=1
    else
      printf '%s\n' "${replay_lines[index]}"
      lifetime_emitted_events=$((lifetime_emitted_events + 1))
      lifetime_emitted_bytes=$((lifetime_emitted_bytes + replay_sizes[index]))
      if [[ "$retained_kind" == "watch_end" ]]; then
        terminal_reason="$(terminal_reason_from_event "${replay_lines[index]}")"
        range_saw_end=1
      fi
    fi
    index=$((index + 1))
  done
  if (( range_saw_end && lifetime_is_closed )); then
    emit_lifetime_summary || return 1
  fi
}

emit_follow_range() {
  local first_line="$1" last_line="$2" line parsed event_watch_id event_kind line_bytes
  range_saw_end=0
  range_error=""
  (( last_line >= first_line )) || return 0
  while IFS= read -r line; do
    parsed="$(parse_event_identity "$line")" || {
      range_error="malformed_event"
      return 1
    }
    event_watch_id="${parsed%%$'\t'*}"
    event_kind="${parsed#*$'\t'}"
    [[ "$event_watch_id" == "$watch_id" ]] || continue
    line_bytes="$(LC_ALL=C printf '%s\n' "$line" | wc -c | tr -d ' ')"
    if (( lifetime_is_closed \
          || lifetime_emitted_events + 1 > body_event_limit \
          || lifetime_emitted_bytes + line_bytes > body_byte_limit )); then
      lifetime_is_closed=1
      lifetime_omitted_events=$((lifetime_omitted_events + 1))
      lifetime_omitted_bytes=$((lifetime_omitted_bytes + line_bytes))
    else
      printf '%s\n' "$line"
      lifetime_emitted_events=$((lifetime_emitted_events + 1))
      lifetime_emitted_bytes=$((lifetime_emitted_bytes + line_bytes))
    fi
    if [[ "$event_kind" == "watch_end" ]]; then
      terminal_reason="$(terminal_reason_from_event "$line")"
      range_saw_end=1
    fi
  done < <(read_log_range "$first_line" "$last_line")
  if (( range_saw_end && lifetime_is_closed )); then
    emit_lifetime_summary || return 1
  fi
}

sent_lines=0
if ! emit_initial_range 1 "$observed_lines"; then
  stream_error "$range_error" "event replay could not be delivered safely"
  exit 1
fi
sent_lines="$observed_lines"
sent_fingerprint="$(line_fingerprint "$sent_lines")"
(( range_saw_end )) && exit 0

refresh_follow_state() {
  follow_saw_end=0
  current_identity="$(verdict_audit_path_identity "$log" 2>/dev/null)" || current_identity=""
  current_size="$(file_size)"
  if [[ ! "$current_size" =~ ^[0-9]+$ ]] \
     || (( current_size > HARD_MAX_INPUT_BYTES )); then
    validate_measurement "$current_size" 0 || exit 1
  fi
  current_lines="$(file_lines)"
  validate_measurement "$current_size" "$current_lines" || exit 1
  if [[ "$current_identity" != "$expected_identity" ]]; then
    stream_error "log_replaced" "event log identity changed"
    exit 1
  fi
  if (( current_size < observed_size )); then
    stream_error "log_truncated" "event log shrank"
    exit 1
  fi
  if (( current_lines < observed_lines || current_lines < sent_lines )); then
    stream_error "line_regression" "event log line count regressed"
    exit 1
  fi
  if (( sent_lines > 0 )) \
     && [[ "$(line_fingerprint "$sent_lines")" != "$sent_fingerprint" ]]; then
    stream_error "line_regression" "previously delivered event changed"
    exit 1
  fi

  if (( current_lines > sent_lines )); then
    if ! emit_follow_range "$((sent_lines + 1))" "$current_lines"; then
      if (( lifetime_is_closed )); then
        printf 'pr-watch-stream: %s after lifetime output closed\n' "$range_error" >&2
      else
        stream_error "$range_error" "new event batch could not be delivered safely"
      fi
      exit 1
    fi
    sent_lines="$current_lines"
    sent_fingerprint="$(line_fingerprint "$sent_lines")"
    (( range_saw_end )) && follow_saw_end=1
  fi
  observed_size="$current_size"
  observed_lines="$current_lines"
}

while :; do
  stream_sleep "$poll"
  refresh_follow_state
  (( follow_saw_end )) && exit 0
  if ! producer_is_live; then
    # Producers append watch_end before retiring their lock. Liveness may turn
    # false after the sample above, so one post-liveness rescan is the ordering
    # barrier that distinguishes a completed generation from a true orphan.
    refresh_follow_state
    (( follow_saw_end )) && exit 0
    stream_error "producer_orphaned" \
      "watch generation has no matching live producer"
    exit 1
  fi
done
