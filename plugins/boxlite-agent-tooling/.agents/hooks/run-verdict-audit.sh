#!/usr/bin/env bash
# Harness-neutral verdict-audit runner: any coding agent that can run bash gets an
# INDEPENDENT auditor — the same cold-reader judgment Claude Code gets from its
# verdict-auditor subagent — instead of degrading to self-audit.
#
#   bash .agents/hooks/run-verdict-audit.sh <transcript_path> [session_id] [generation] [session_scope]
#
# Feeds the procedure in .claude/agents/verdict-auditor.md (frontmatter stripped)
# as the system prompt to a model CLI with Read/Bash/Write tools, which audits the
# transcript's final turn (all assistant text since the last real user message,
# mid-turn claims included) against the working tree and writes the
# requested session-scoped dossier under .agents/state/. Succeeds only if it lands.
#
# Model resolution (same seam pattern as the triage classifier):
#   1. VERDICT_AUDITOR_CMD — full override; invoked with the audit prompt on stdin;
#      must leave a dossier behind. Per-harness config, tests stub it.
#   2. claude CLI — headless with the auditor spec as system prompt, tools
#      whitelisted, hooks disabled (no nested gates), 10-minute cap.
#   3. Codex CLI — read-only, hooks disabled, ephemeral, same timeout. Codex writes
#      only its final response through the host-owned --output-last-message channel;
#      the parent runner validates and publishes those bytes.
#   4. Neither → exit 2 with instructions (the caller sees why).
#
# Exit codes: 0 dossier written · 1 audit ran but no dossier · 2 no runner available ·
#             130 canceled by a newer user prompt/INT · 143 canceled by TERM.
set -uo pipefail

transcript_path="${1:-}"
if [[ -z "$transcript_path" ]]; then
  echo "usage: run-verdict-audit.sh <transcript_path> [session_id] [generation]" >&2
  exit 2
fi
session_id="${2:-}"
audit_generation="${3:-}"
provided_session_scope="${4:-}"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null \
  || ( cd "$project_dir" 2>/dev/null && pwd -P ) \
  || pwd -P)"
project_dir="$(cd "$repo_root" && pwd -P)"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
spec_file="$tooling_root/.claude/agents/verdict-auditor.md"
audit_timeout_seconds="${VERDICT_AUDITOR_TIMEOUT:-600}"
auditor_model="${VERDICT_AUDITOR_MODEL:-claude-sonnet-5}"
audit_pgid=0
audit_group_identity_owned=false
audit_group_event_monitor_pid=0
audit_group_event_write_open=false
request_monitor_pid=0
audit_started=false
audit_launching=false
pending_cancel_code=""
pending_cancel_reason=""
pending_cancel_tombstone=false
audit_request_body=""
audit_token="$$-$(date +%s)-${RANDOM:-0}"
owns_audit_lock=false
audit_lease_pid=0
audit_lease_event_monitor_pid=0
audit_lease_control_open=false
quarantine_counter=0
audit_verified_file=""
audit_verified_identity=""
audit_success_pending=false
transcript_snapshot_dir=""
transcript_snapshot_path=""
transcript_source_max_bytes=67108864
transcript_turn_max_bytes=262144
previous_dossier_max_bytes=65536
previous_dossier_input_path=""
previous_dossier_snapshot_path=""
reflection_context=""
reflection_pending=false
history_path=""

audit_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
if [[ ! -r "$audit_state_lib" ]]; then
  printf 'run-verdict-audit.sh: missing %s — cannot scope the audit owner.\n' \
    "$audit_state_lib" >&2
  exit 2
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$audit_state_lib"
# shellcheck source=../lib/audit-reflection.sh
source "$tooling_root/.agents/lib/audit-reflection.sh"
# shellcheck source=../lib/audit-reflection-gate.sh
source "$tooling_root/.agents/lib/audit-reflection-gate.sh"
# shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh above.
max_audit_timeout_seconds="$(( verdict_audit_lock_max_seconds - verdict_audit_deadline_slack_seconds ))"
audit_timeout_is_numeric=true
[[ "$audit_timeout_seconds" =~ ^[1-9][0-9]*$ \
   && ${#audit_timeout_seconds} -le 4 ]] || audit_timeout_is_numeric=false
# Bound the string before arithmetic: macOS Bash 3.2 wraps integers wider than 64 bits,
# which can turn an attacker-controlled huge value into a small accepted timeout.
if [[ "$audit_timeout_is_numeric" != true ]] \
   || (( audit_timeout_seconds > max_audit_timeout_seconds )); then
  printf 'run-verdict-audit.sh: VERDICT_AUDITOR_TIMEOUT must be an integer from 1 to %s seconds.\n' \
    "$max_audit_timeout_seconds" >&2
  exit 2
fi
if [[ -n "$provided_session_scope" ]]; then
  if [[ "$provided_session_scope" != "-" \
     && ! "$provided_session_scope" =~ ^git-[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    printf 'run-verdict-audit.sh: invalid session scope.\n' >&2
    exit 2
  fi
  session_scope="$provided_session_scope"
else
  if ! session_scope="$(verdict_audit_scope_identity "$session_id" "$project_dir")"; then
    printf 'run-verdict-audit.sh: could not derive the session audit scope.\n' >&2
    exit 2
  fi
fi
if [[ "$session_scope" != "-" && ! "$audit_generation" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ ]]; then
  printf 'run-verdict-audit.sh: a session-scoped audit requires a valid generation.\n' >&2
  exit 2
fi
audit_generation="${audit_generation:-legacy}"
state_dir="$project_dir/.agents/state"
verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.json" "$session_scope")"
previous_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.prev.json" "$session_scope")"
audit_lock_file="$(verdict_audit_state_path "$state_dir/verdict-audit.lock" "$session_scope")"
audit_mutex_file="${audit_lock_file}.mutex"
audit_request_file="$(verdict_audit_state_path "$state_dir/verdict-request" "$session_scope")"
audit_publish_mutex_file="${audit_request_file}.publish.mutex"
prompt_epoch_file="$(verdict_audit_state_path "$state_dir/verdict-prompt-epoch" "$session_scope")"
auditor_control="$tooling_root/.agents/hooks/auditor-control.sh"
auditor_control_started=false
audit_cancellation_file="$(verdict_audit_cancellation_path \
  "$state_dir" "$session_scope" "$audit_generation")"
# Session-aware audits write to a runner-owned generation file first. Promotion happens
# only after the entire process group is quiescent; legacy/manual runs keep their stable
# path so older bare-CLI integrations remain compatible.
audit_output_file="$verdict_file"
[[ "$session_scope" == "-" ]] \
  || audit_output_file="${verdict_file}.audit-${audit_token}"
# shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh above.
audit_deadline="$(( $(date +%s) + audit_timeout_seconds + verdict_audit_deadline_slack_seconds ))"
runner_start_token="$(verdict_audit_process_start_token "$$" 2>/dev/null)" || {
  printf 'run-verdict-audit.sh: could not identify the runner process start time.\n' >&2
  exit 2
}

# Announce "an audit is running" to preflight-verdict-check.sh, which otherwise re-blocks
# the agent every few seconds for this script's whole runtime. A direct Perl child safely
# opens and flocks both stable, never-unlinked mutex files for the runner lifetime.
# Parent and holder communicate over two FIFOs created in a private directory and unlinked
# immediately after opening. The resulting descriptors cannot be replaced through the
# workspace: closing the control writer is the only clean-release protocol, and an event
# EOF without `clean` is an unambiguous lost lease. Parent death closes control even on
# SIGKILL. The adjacent metadata is: runner PID, deadline, process-group placeholder (the
# runner owns that detail), session, owner token, audit generation, and process-start token.
# Splitting exclusion from observation removes stale check/delete races and the start token
# distinguishes a crashed runner from PID reuse.
start_audit_lease_holder() {
  local channel_dir control_fifo event_fifo status=""
  channel_dir="$(mktemp -d "${TMPDIR:-/tmp}/boxlite-verdict-lease.XXXXXX" 2>/dev/null)" \
    || return 2
  chmod 700 "$channel_dir" 2>/dev/null || { rmdir "$channel_dir" 2>/dev/null; return 2; }
  control_fifo="$channel_dir/control"
  event_fifo="$channel_dir/event"
  if ! mkfifo "$control_fifo" "$event_fifo" 2>/dev/null; then
    rm -f "$control_fifo" "$event_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 2
  fi
  # Bootstrap both directions O_RDWR so no pathname open can deadlock. Holder and parent
  # then take their one-way endpoints and close the bootstraps before names are unlinked.
  if ! exec 5<>"$control_fifo" || ! exec 6<>"$event_fifo"; then
    exec 5>&- || true
    exec 6>&- || true
    rm -f "$control_fifo" "$event_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 2
  fi
  perl -MFcntl=:DEFAULT,:flock -MErrno=EAGAIN,EWOULDBLOCK,EINTR -e '
    my ($audit_path, $publish_path, $parent) = @ARGV;
    $| = 1;

    sub report {
      my ($value) = @_;
      print STDOUT $value, "\n" or exit 2;
    }

    sub open_mutex {
      my ($path) = @_;
      return if lstat($path) && -l _;
      my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $fh, $path, $flags, 0600) or return;
      my @opened = stat($fh);
      my @named = lstat($path);
      return unless @opened && @named && -f $fh && $opened[3] == 1
        && $opened[0] == $named[0] && $opened[1] == $named[1];
      return $fh;
    }

    $SIG{PIPE} = "IGNORE";
    $SIG{ALRM} = sub { report("error"); exit 2 };
    alarm 3;
    my $audit = open_mutex($audit_path);
    if (!$audit) { report("error"); exit 2 }
    if (!flock($audit, LOCK_EX | LOCK_NB)) {
      report(($!{EAGAIN} || $!{EWOULDBLOCK}) ? "busy" : "error");
      exit 2;
    }
    my @audit_opened = stat($audit);
    my @audit_named = lstat($audit_path);
    if (!@audit_opened || !@audit_named || !-f $audit || $audit_opened[3] != 1
        || $audit_opened[0] != $audit_named[0]
        || $audit_opened[1] != $audit_named[1]) {
      report("error");
      exit 2;
    }
    my $publish = open_mutex($publish_path);
    if (!$publish) { report("error"); exit 2 }
    if (!flock($publish, LOCK_EX | LOCK_NB)) {
      report(($!{EAGAIN} || $!{EWOULDBLOCK}) ? "busy" : "error");
      exit 2;
    }
    my @publish_opened = stat($publish);
    my @publish_named = lstat($publish_path);
    if (!@publish_opened || !@publish_named || !-f $publish
        || $publish_opened[3] != 1
        || $publish_opened[0] != $publish_named[0]
        || $publish_opened[1] != $publish_named[1]) {
      report("error");
      exit 2;
    }
    # Ordinary termination exits without `clean`; the event monitor treats that EOF as
    # lease loss. Only control-channel EOF is a deliberate parent release.
    $SIG{TERM} = sub { exit 143 };
    $SIG{INT} = sub { exit 130 };
    $SIG{HUP} = sub { exit 129 };
    alarm 0;
    report("ok");
    my $byte = "";
    while (1) {
      my $count = sysread(STDIN, $byte, 1);
      next if !defined($count) && $!{EINTR};
      exit 2 unless defined $count;
      last if $count == 0;
    }
    report("clean");
    exit 0;
  ' "$audit_mutex_file" "$audit_publish_mutex_file" "$$" \
    <"$control_fifo" >"$event_fifo" 5>&- 6>&- 7>&- 8>&- 9>&- &
  audit_lease_pid=$!
  if ! exec 7>"$control_fifo" || ! exec 8<"$event_fifo"; then
    exec 5>&- 6>&- 7>&- 8>&- || true
    wait "$audit_lease_pid" 2>/dev/null || true
    rm -f "$control_fifo" "$event_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    audit_lease_pid=0
    return 2
  fi
  audit_lease_control_open=true
  exec 5>&- 6>&-
  rm -f "$control_fifo" "$event_fifo" 2>/dev/null || true
  rmdir "$channel_dir" 2>/dev/null || true
  IFS= read -r -t 3 -u 8 status || status=""
  case "$status" in
    ok)
      # This direct child is the sole event reader after the startup record. A clean
      # release consumes `clean`; malformed input or EOF signals only its actual parent.
      perl -e '
        my $parent = shift;
        while (my $line = <STDIN>) {
          exit 0 if $line eq "clean\n";
          last;
        }
        kill "USR2", $parent if getppid() == $parent;
        exit 1;
      ' "$$" <&8 7>&- 8<&- 9>&- &
      audit_lease_event_monitor_pid=$!
      exec 8<&-
      return 0
      ;;
    busy)
      stop_audit_lease_holder
      return 1
      ;;
    *)
      stop_audit_lease_holder
      return 2
      ;;
  esac
}

stop_audit_lease_holder() {
  local holder_status=0 monitor_status=0
  if [[ "$audit_lease_control_open" == true ]]; then
    exec 7>&-
    audit_lease_control_open=false
  fi
  if [[ "$audit_lease_pid" =~ ^[1-9][0-9]*$ ]]; then
    wait "$audit_lease_pid" 2>/dev/null || holder_status=$?
  fi
  audit_lease_pid=0
  if [[ "$audit_lease_event_monitor_pid" =~ ^[1-9][0-9]*$ ]]; then
    wait "$audit_lease_event_monitor_pid" 2>/dev/null || monitor_status=$?
  fi
  audit_lease_event_monitor_pid=0
  (( holder_status == 0 && monitor_status == 0 ))
}

persisted_runner_is_current() {  # pid start-token generation
  local pid="$1" expected_start="$2" expected_generation="$3"
  local actual_start command_line
  actual_start="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" || return 2
  [[ "$actual_start" == "$expected_start" ]] || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 2
  [[ -n "$command_line" ]] || return 2
  [[ "$command_line" == *run-verdict-audit.sh* \
     && "$command_line" == *"$expected_generation"* ]] || return 1
  return 0
}

acquire_audit_lock() {
  local status existing_body existing_pid existing_start existing_extra identity_status
  command -v perl >/dev/null 2>&1 || {
    printf 'run-verdict-audit.sh: perl is required for exclusive audit ownership.\n' >&2
    return 2
  }
  mkdir -p "$(dirname "$audit_lock_file")" 2>/dev/null || return 2
  start_audit_lease_holder
  status=$?
  if (( status != 0 )); then
    return "$status"
  fi
  if ! kill -0 "$audit_lease_pid" 2>/dev/null; then
    request_cancel 143 "the audit ownership lease was lost" true
  fi
  # If a holder crashes, its immutable metadata remains until that live runner cancels.
  # Refuse a contender during this fail-closed handoff window even though the kernel lease
  # has already released; once cleanup removes metadata, the generation tombstone prevents
  # the same canceled request from restarting.
  existing_body="$(verdict_audit_read_single_record "$audit_lock_file" 2>/dev/null)" \
    || existing_body=""
  read -r existing_pid _ _ _ _ _ existing_start existing_extra <<< "$existing_body"
  if [[ "$existing_pid" =~ ^[1-9][0-9]*$ && "$existing_pid" != "$$" ]] \
    && kill -0 "$existing_pid" 2>/dev/null; then
    if [[ "$existing_start" =~ ^cksum-[0-9]+-[0-9]+$ && -z "$existing_extra" ]]; then
      persisted_runner_is_current \
        "$existing_pid" "$existing_start" "$audit_generation"
      identity_status=$?
      case "$identity_status" in
        0)
          stop_audit_lease_holder
          return 1
          ;;
        1) ;;
        *)
          stop_audit_lease_holder
          return 2
          ;;
      esac
    else
      # Legacy metadata has no reusable-PID discriminator. Keep its conservative
      # handoff behavior until that older live process disappears.
      stop_audit_lease_holder
      return 1
    fi
  fi
  if ! printf '%s %s 0 %s %s %s %s\n' \
      "$$" "$audit_deadline" "$session_scope" "$audit_token" "$audit_generation" \
      "$runner_start_token" \
      | verdict_audit_write_atomic "$audit_lock_file" 2>/dev/null; then
    stop_audit_lease_holder
    return 2
  fi
  owns_audit_lock=true
  return 0
}

stop_request_monitor() {
  if [[ "$request_monitor_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$request_monitor_pid" 2>/dev/null || true
    wait "$request_monitor_pid" 2>/dev/null || true
    request_monitor_pid=0
  fi
}

# Called indirectly by the EXIT trap installed in take_audit_lock().
# shellcheck disable=SC2329
cleanup_audit_lock() {
  local original_status=$? body owner_pid owner_token extra _ lease_status=0
  local control_cleanup_failed=false
  if [[ "$reflection_pending" == true ]]; then
    local reflection_terminal=error
    (( original_status == 130 || original_status == 143 )) && reflection_terminal=cancel
    audit_reflection_gate "$reflection_context" "$reflection_terminal" "$audit_token" \
      "\"verdict runner exited with status $original_status\"" >/dev/null || true
  fi
  if [[ -n "$transcript_snapshot_path" ]]; then
    rm -f "$transcript_snapshot_path" 2>/dev/null || true
    transcript_snapshot_path=""
  fi
  if [[ -n "$transcript_snapshot_dir" ]]; then
    rmdir "$transcript_snapshot_dir" 2>/dev/null || true
    transcript_snapshot_dir=""
  fi
  if [[ -n "$previous_dossier_snapshot_path" ]]; then
    rm -f "$previous_dossier_snapshot_path" 2>/dev/null || true
    previous_dossier_snapshot_path=""
  fi
  if [[ "$auditor_control_started" == true ]]; then
    control_terminal="${audit_verdict:-unavailable}"
    (( original_status == 0 )) || control_terminal=unavailable
    if ! CLAUDE_PROJECT_DIR="$project_dir" bash "$auditor_control" external-stop \
      verdict-auditor "$audit_generation" "$session_scope" "$control_terminal" \
      >/dev/null 2>&1; then
      control_cleanup_failed=true
    fi
    auditor_control_started=false
  fi
  # A successful audit is not committed until the holder's clean-release handshake.
  # Keep request revocation observable through that wait; non-success exits no longer
  # need the monitor and tear it down immediately.
  (( original_status == 0 )) || stop_request_monitor
  if [[ "$owns_audit_lock" == true ]]; then
    :
  else
    if [[ "$control_cleanup_failed" == true ]]; then
      remove_verified_publication
      rm -f "$audit_output_file" 2>/dev/null || true
      remove_owned_verdict
      retire_matching_session_verdict
      printf 'run-verdict-audit.sh: could not close auditor prompt state.\n' >&2
      trap - EXIT
      exit 2
    fi
    return 0
  fi
  if body="$(verdict_audit_read_single_record "$audit_lock_file" 2>/dev/null)"; then
    read -r owner_pid _ _ _ owner_token _ _ extra <<< "$body"
    if [[ "$owner_pid" == "$$" && "$owner_token" == "$audit_token" && -z "$extra" ]]; then
      rm -f "$audit_lock_file"
    fi
  fi
  stop_audit_lease_holder || lease_status=$?
  owns_audit_lock=false
  if (( original_status == 0 && lease_status != 0 )); then
    stop_request_monitor
    if ! revoke_canceled_generation_authority; then
      printf 'run-verdict-audit.sh: could not durably revoke generation %s after lease loss\n' \
        "$audit_generation" >&2
    fi
    remove_verified_publication
    rm -f "$audit_output_file" 2>/dev/null || true
    remove_owned_verdict
    retire_matching_session_verdict
    printf 'run-verdict-audit.sh: cancelled — the audit ownership lease was lost before success\n' \
      >&2
    trap - EXIT
    exit 143
  fi
  if [[ "$control_cleanup_failed" == true ]]; then
    stop_request_monitor
    remove_verified_publication
    rm -f "$audit_output_file" 2>/dev/null || true
    remove_owned_verdict
    retire_matching_session_verdict
    printf 'run-verdict-audit.sh: could not close auditor prompt state.\n' >&2
    trap - EXIT
    exit 2
  fi
  if (( original_status == 0 )); then
    if ! audit_request_is_current; then
      stop_request_monitor
      remove_verified_publication
      rm -f "$audit_output_file" 2>/dev/null || true
      remove_owned_verdict
      retire_matching_session_verdict
      printf 'run-verdict-audit.sh: cancelled — the audit generation was revoked before lease commit\n' \
        >&2
      trap - EXIT
      exit 130
    fi
    # Publication is committed only after the holder returned `clean` and both direct
    # channel children were reaped successfully. The stable hardlink remains; drop only
    # the private ownership name now that no late lease-loss rollback is possible.
    [[ -z "$audit_verified_file" ]] || rm -f "$audit_verified_file" 2>/dev/null || true
    audit_verified_file=""
    audit_verified_identity=""
    if [[ "$audit_success_pending" == true ]]; then
      printf 'audit complete: %s → %s\n' "$audit_verdict" "$verdict_file"
    fi
    stop_request_monitor
  fi
}

# A session-scoped runner is authorized by the request the Stop gate wrote before
# emitting its command. Publishing the lock first closes the startup race: input that
# arrived earlier removes the request and is caught here; input that arrives later is
# observed by the runner's request monitor.
audit_request_is_current() {
  [[ "$session_scope" != "-" ]] || return 0
  local body request_generation request_deadline message_id extra now
  [[ -r "$audit_request_file" ]] || return 1
  verdict_audit_cancellation_exists "$audit_cancellation_file" && return 1
  body="$(verdict_audit_read_single_record "$audit_request_file" 2>/dev/null)" || return 1
  read -r request_generation request_deadline message_id extra <<< "$body"
  now="$(date +%s)"
  verdict_audit_epoch_is_bounded "$request_deadline" || return 1
  [[ "$request_generation" == "$audit_generation" \
     && "$message_id" =~ ^cksum-[0-9]+-[0-9]+$ \
     && -z "$extra" ]] || return 1
  # shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh above.
  if (( now <= request_deadline \
        && request_deadline <= now + verdict_audit_lock_max_seconds )); then
    audit_request_body="$body"
    return 0
  fi
  return 1
}

# Move a shared session dossier to a runner-unique same-directory pathname before reading
# its generation. The rename selects one inode atomically; a newer writer that appears
# afterward stays at the stable path and can never be unlinked by this cleanup. A moved
# non-owned generation is restored with link(2) no-clobber semantics. If another writer
# already occupies the stable path, preserve both files and fail closed rather than guess.
restore_quarantined_state() {  # quarantined-path stable-path
  if verdict_audit_restore_no_clobber "$1" "$2" 2>/dev/null; then
    return 0
  fi
  printf 'run-verdict-audit.sh: could not safely restore non-owned state from %s to %s\n' \
    "$1" "$2" >&2
  return 1
}

# BSD `mv file directory` changes meaning and nests the source under the destination.
# rename(2) always treats both arguments as exact pathnames, so a directory appearing in
# the promotion gap fails without moving the runner-owned stage out of cleanup reach.
rename_exact_path() {  # source destination
  verdict_audit_rename_exact "$1" "$2"
}

retire_matching_session_verdict() {
  [[ "$session_scope" != "-" ]] || return 0
  local quarantined_verdict dossier_generation dossier_snapshot dossier_json
  quarantine_counter=$(( quarantine_counter + 1 ))
  quarantined_verdict="${verdict_file}.cancel-${audit_token}-${quarantine_counter}"
  [[ -f "$verdict_file" || -L "$verdict_file" ]] || return 0
  if ! rename_exact_path "$verdict_file" "$quarantined_verdict" 2>/dev/null; then
    return 0
  fi
  dossier_snapshot="$(verdict_audit_read_json_snapshot \
    "$quarantined_verdict" 2>/dev/null)" || dossier_snapshot=""
  dossier_json=""
  [[ "$dossier_snapshot" == *$'\n'* ]] \
    && dossier_json="${dossier_snapshot#*$'\n'}"
  dossier_generation="$(printf '%s' "$dossier_json" \
    | jq -r '.generation // ""' 2>/dev/null || echo '')"
  if [[ "$dossier_generation" == "$audit_generation" ]]; then
    rm -f "$quarantined_verdict"
    return 0
  fi
  restore_quarantined_state "$quarantined_verdict" "$verdict_file"
}

# Legacy runners own their established shared path. A session runner owns a matching
# generation only on an ordinary rejection while its exact request is still current.
remove_owned_verdict() {  # [while-current]
  if [[ "$session_scope" == "-" ]]; then
    rm -f "$verdict_file"
  elif [[ "${1:-}" == "while-current" ]] \
    && audit_request_is_current; then
    retire_matching_session_verdict
  fi
}

# Once promotion succeeds, the selected stage inode remains the runner's ownership token
# through the final authority and lease checks. Rollback selects the stable pathname first
# and removes it only when it still names that exact inode; a concurrent replacement is
# restored untouched.
remove_verified_publication() {
  if [[ -n "$audit_verified_identity" ]]; then
    verdict_audit_unlink_if_identity \
      "$verdict_file" "$audit_verified_identity" >/dev/null 2>&1 || true
  fi
  [[ -z "$audit_verified_file" ]] || rm -f "$audit_verified_file" 2>/dev/null || true
  audit_verified_file=""
  audit_verified_identity=""
}

publish_cancellation_tombstone() {
  [[ "$session_scope" != "-" ]] || return 0
  local fallback_file="${audit_cancellation_file}.fallback-${audit_token}"
  mkdir -p "$(dirname "$audit_cancellation_file")" 2>/dev/null || return 1
  # Any pre-existing entry at the canonical path is already a visible fail-closed
  # revocation, even when its unsafe type prevents writing a JSON record into it.
  verdict_audit_cancellation_exists "$audit_cancellation_file" && return 0
  if ! printf '%s\n' "$audit_request_body" \
      | verdict_audit_write_atomic "$audit_cancellation_file" 2>/dev/null; then
    printf '%s\n' "$audit_request_body" \
      | verdict_audit_write_exclusive_regular "$fallback_file" 2>/dev/null \
      || return 1
  fi
  return 0
}

revoke_canceled_generation_authority() {
  [[ "$session_scope" != "-" ]] || return 0
  publish_cancellation_tombstone && return 0
  # When a parent directory refuses new names, removing or invalidating the exact
  # authorized request still makes the canceled generation impossible to reload.
  retire_canceled_request_authority >/dev/null 2>&1 && return 0
  if capture_matching_request_authority >/dev/null 2>&1 \
     && verdict_audit_invalidate_record_if_matches \
          "$audit_request_file" "$audit_request_body" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

capture_matching_request_authority() {
  [[ "$session_scope" != "-" ]] || return 0
  if [[ -z "$audit_request_body" ]]; then
    local body request_generation request_deadline message_id extra
    body="$(verdict_audit_read_single_record "$audit_request_file" 2>/dev/null)" \
      || return 1
    read -r request_generation request_deadline message_id extra <<< "$body"
    verdict_audit_epoch_is_bounded "$request_deadline" || return 1
    [[ "$request_generation" == "$audit_generation" \
       && "$message_id" =~ ^cksum-[0-9]+-[0-9]+$ \
       && -z "$extra" ]] || return 1
    audit_request_body="$body"
  fi
  return 0
}

retire_canceled_request_authority() {
  [[ "$session_scope" != "-" ]] || return 0
  capture_matching_request_authority || return 1
  verdict_audit_remove_record_if_matches \
    "$audit_request_file" "$audit_request_body" >/dev/null 2>&1
}

# Report whether the anchored audit group still has any member other than its leader.
# `ps -axo` is available on both BSD/macOS and procps; the sentinel keeps the PGID from
# being reused while this observational poll runs.
audit_group_has_residual_members() {  # leader-pid / pgid
  ps -axo pid=,pgid= 2>/dev/null \
    | awk -v leader="$1" -v group="$1" '
        $1 != leader && $2 == group { found = 1 }
        END { exit(found ? 0 : 1) }
      '
}

# The auditor runs in its own process group. Its leader is a runner-owned sentinel that
# stays alive until teardown, so every negative-PGID signal is backed by a live identity
# the runner still owns. Signal the group, give residual tools two bounded seconds for
# cooperative cleanup, then KILL the still-anchored group. Normal completion usually has
# only the sentinel left and therefore takes the immediate path.
quiesce_audit_group() {
  local i=0 owned_pgid="$audit_pgid"
  if [[ "$owned_pgid" =~ ^[1-9][0-9]*$ \
     && "$audit_group_identity_owned" == true ]] \
     && kill -0 "$owned_pgid" 2>/dev/null; then
    kill -TERM -- "-$owned_pgid" 2>/dev/null || true
    while (( i < 40 )) && audit_group_has_residual_members "$owned_pgid"; do
      sleep 0.05
      (( i += 1 ))
    done
    # The sentinel ignores TERM and remains the group identity through escalation.
    kill -KILL -- "-$owned_pgid" 2>/dev/null || true
  fi
  if [[ "$owned_pgid" =~ ^[1-9][0-9]*$ ]]; then
    wait "$owned_pgid" 2>/dev/null || true
  fi
  stop_audit_group_event_monitor >/dev/null 2>&1 || true
  audit_group_identity_owned=false
  audit_pgid=0
}

# Called indirectly by the signal traps installed in take_audit_lock().
# shellcheck disable=SC2329
cancel_audit() {  # exit-code reason [publish-tombstone]
  local exit_code="$1" reason="$2" publish_tombstone="${3:-false}"
  trap '' INT TERM USR1 USR2
  stop_request_monitor
  if [[ "$publish_tombstone" == true ]] \
     && ! revoke_canceled_generation_authority; then
    printf 'run-verdict-audit.sh: could not durably revoke generation %s\n' \
      "$audit_generation" >&2
  fi
  if [[ "$audit_started" == true ]]; then
    # Revoke authority before process cleanup. Even a native-style late writer cannot
    # authorize a turn once UserPromptSubmit removed its request or INT/TERM published
    # this generation's tombstone. Never remove the shared request here: a newer
    # generation may already have replaced it by the time a delayed signal is handled.
    remove_verified_publication
    rm -f "$audit_output_file"
    remove_owned_verdict
    retire_matching_session_verdict
    quiesce_audit_group
    # The child may write while handling TERM. Removal AFTER quiescence closes that race.
    remove_verified_publication
    rm -f "$audit_output_file"
    remove_owned_verdict
    retire_matching_session_verdict
  fi
  printf 'run-verdict-audit.sh: cancelled — %s\n' "$reason" >&2
  exit "$exit_code"
}

# A signal can land after the background group exists but before `$!` is published.
# Record it during that two-command launch window, then cancel once ownership is known.
# shellcheck disable=SC2329
request_cancel() {  # exit-code reason [publish-tombstone]
  if [[ "$audit_launching" == true ]]; then
    pending_cancel_code="$1"
    pending_cancel_reason="$2"
    pending_cancel_tombstone="${3:-false}"
    return 0
  fi
  cancel_audit "$1" "$2" "${3:-false}"
}

# Select one stable regular transcript inode and give the auditor a private bounded
# snapshot. This keeps a live transcript append, pathname swap, FIFO, or symlink from
# changing what the prompt names after the boundary check.
snapshot_transcript() {
  local created_snapshot_dir selected_snapshot selected_json normalized_snapshot
  local normalized_bytes
  created_snapshot_dir="$(mktemp -d \
    "${TMPDIR:-/tmp}/boxlite-verdict-transcript.XXXXXX" 2>/dev/null)" || return 1
  transcript_snapshot_dir="$created_snapshot_dir"
  chmod 700 "$transcript_snapshot_dir" 2>/dev/null || return 1
  transcript_snapshot_dir="$(cd "$transcript_snapshot_dir" && pwd -P)" || return 1
  transcript_snapshot_path="$transcript_snapshot_dir/transcript.jsonl"
  selected_snapshot="$(verdict_audit_read_regular_state \
    "$transcript_path" "$transcript_turn_max_bytes" json 2>/dev/null)" \
    || selected_snapshot=""
  selected_json=""
  [[ "$selected_snapshot" == *$'\n'* ]] \
    && selected_json="${selected_snapshot#*$'\n'}"
  normalized_snapshot="$(printf '%s' "$selected_json" \
    | verdict_audit_normalize_turn_snapshot \
        "$transcript_turn_max_bytes" 2>/dev/null || true)"
  if [[ -n "$normalized_snapshot" ]]; then
    normalized_bytes="$(LC_ALL=C printf '%s\n' "$normalized_snapshot" \
      | wc -c | tr -d ' ')"
    if [[ ! "$normalized_bytes" =~ ^[0-9]+$ \
       || "$normalized_bytes" -gt "$transcript_turn_max_bytes" ]] \
       || ! printf '%s\n' "$normalized_snapshot" \
            | verdict_audit_write_exclusive_regular \
                "$transcript_snapshot_path" 2>/dev/null; then
      return 1
    fi
  elif ! verdict_audit_snapshot_final_turn \
        "$transcript_path" "$transcript_snapshot_path" \
        "$transcript_source_max_bytes" "$transcript_turn_max_bytes"; then
    printf 'run-verdict-audit.sh: transcript must be stable, regular JSONL no larger than %s bytes; auditor was not started.\n' \
      "$transcript_source_max_bytes" >&2
    return 1
  fi
  transcript_path="$transcript_snapshot_path"
}

snapshot_previous_dossier() {
  local previous_snapshot previous_json previous_input
  previous_dossier_snapshot_path="${previous_verdict_file}.input-${audit_token}"
  if [[ -e "$previous_verdict_file" || -L "$previous_verdict_file" ]]; then
    previous_snapshot="$(verdict_audit_read_regular_state \
      "$previous_verdict_file" "$previous_dossier_max_bytes" json 2>/dev/null)" \
      || previous_snapshot=""
    previous_json=""
    [[ "$previous_snapshot" == *$'\n'* ]] \
      && previous_json="${previous_snapshot#*$'\n'}"
    previous_json="$(printf '%s' "$previous_json" \
      | verdict_audit_normalize_dossier 2>/dev/null || true)"
    if [[ -z "$previous_json" ]]; then
      previous_input="$(verdict_audit_failed_prior_snapshot)" || return 1
    else
      previous_input="$previous_json"
    fi
  else
    previous_input="$(verdict_audit_absent_prior_snapshot)" || return 1
  fi
  if ! printf '%s\n' "$previous_input" \
      | verdict_audit_write_exclusive_regular \
          "$previous_dossier_snapshot_path" 2>/dev/null; then
    previous_dossier_snapshot_path=""
    return 1
  fi
  previous_dossier_input_path="$previous_dossier_snapshot_path"
}

take_audit_lock() {
  local status
  trap cleanup_audit_lock EXIT
  trap 'request_cancel 130 "a new user prompt arrived" false' USR1
  trap 'request_cancel 143 "the audit ownership lease was lost" true' USR2
  trap 'request_cancel 130 "the runner was interrupted" true' INT
  trap 'request_cancel 143 "the runner was terminated" true' TERM
  acquire_audit_lock
  status=$?
  case "$status" in
    0) ;;
    1)
      printf 'run-verdict-audit.sh: another audit already owns %s\n' "$audit_lock_file" >&2
      exit 2
      ;;
    *)
      printf 'run-verdict-audit.sh: could not acquire exclusive ownership of %s\n' \
        "$audit_lock_file" >&2
      exit 2
      ;;
  esac
}
take_audit_lock
if ! audit_request_is_current; then
  cancel_audit 130 "the audit generation was revoked before launch"
fi
if ! snapshot_transcript; then
  exit 2
fi
if ! snapshot_previous_dossier; then
  printf 'run-verdict-audit.sh: could not publish a bounded prior-dossier snapshot.\n' >&2
  exit 2
fi
if [[ "$session_scope" != "-" ]]; then
  audit_prompt_epoch="$(verdict_audit_read_single_record \
    "$prompt_epoch_file" 2>/dev/null)" || audit_prompt_epoch=""
  if [[ -n "$audit_prompt_epoch" ]]; then
    [[ -r "$auditor_control" ]] || {
      printf 'run-verdict-audit.sh: auditor lifecycle control is unavailable.\n' >&2
      exit 2
    }
    if ! CLAUDE_PROJECT_DIR="$project_dir" bash "$auditor_control" external-start \
        verdict-auditor "$audit_generation" "$session_scope" "$audit_prompt_epoch" \
        >/dev/null 2>&1; then
      printf 'run-verdict-audit.sh: could not start auditor prompt state.\n' >&2
      exit 2
    fi
    auditor_control_started=true
  fi
fi

# Frontmatter (--- ... ---) is subagent WIRING — name, tools, and now the model and
# reasoning effort the Task path launches with. None of it is instruction, so none of it
# may reach the model as part of the procedure. Named rather than inlined at the call
# site because that call site sits in the claude-CLI branch, which the suite can only
# enter by faking `claude` on PATH; as an inline awk this parse had zero coverage while
# quietly deciding what the auditor is told.
strip_frontmatter() {  # $1 = spec file
  awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{fm=2; next} fm!=1' "$1"
}

find_codex_bin() {
  if [[ -n "${CODEX_BIN:-}" ]]; then
    [[ -x "$CODEX_BIN" ]] || return 1
    "$CODEX_BIN" --version >/dev/null 2>&1 || return 1
    printf '%s\n' "$CODEX_BIN"
    return 0
  fi

  local candidate from_path=""
  from_path="$(command -v codex 2>/dev/null || true)"
  for candidate in "$from_path" /Applications/Codex.app/Contents/Resources/codex; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Codex's read-only sandbox deliberately cannot create the throwaway Git index used by
# the auditor procedure. Capture that one write-requiring value in the parent, before
# launch, so the auditor can keep the whole workspace read-only without guessing the
# dossier binding.
compute_audit_tree_hash() {
  local index_file tree_hash="" command_status=0
  index_file="$(mktemp)" || return 1
  GIT_INDEX_FILE="$index_file" git -C "$project_dir" read-tree HEAD >/dev/null 2>&1 \
    && GIT_INDEX_FILE="$index_file" git -C "$project_dir" add -A >/dev/null 2>&1 \
    && tree_hash="$(GIT_INDEX_FILE="$index_file" \
         git -C "$project_dir" write-tree 2>/dev/null)" \
    || command_status=$?
  rm -f "$index_file"
  (( command_status == 0 )) && [[ "$tree_hash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
    || return 1
  printf '%s\n' "$tree_hash"
}

# The prompt is a document, not a string literal: .agents/prompts/verdict-runner.md.
# Loaded through the shared library so this runner and the Stop gate that offers the
# in-agent route cannot drift apart on what "proven" means.
#
# The document is the only copy. A second one drifting out of date would not announce
# itself — the audit would run and return a confident verdict against a superseded
# standard of proof. A missing document is therefore exit 2, the code this script
# already uses for "no runner available", rather than something to improvise around.
# The prompts ship in this same pinned tree, so their absence means the gates that
# reach this script are equally broken.
subagent_lib="$tooling_root/.agents/lib/subagent.sh"
if [[ ! -r "$subagent_lib" ]]; then
  printf 'run-verdict-audit.sh: missing %s — cannot build the audit prompt.\n' "$subagent_lib" >&2
  exit 2
fi
# shellcheck source=../lib/subagent.sh
source "$subagent_lib"
expected_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || printf '')"
expected_head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf '')"
if [[ "$session_scope" != "-" ]]; then
  reflection_context="$(jq -nc --arg root "$project_dir" --arg session "$session_scope" \
    --arg epoch "${audit_prompt_epoch:-0}" --arg branch "${expected_branch:-HEAD}" \
    '{repo_root:$root,session:$session,epoch:$epoch,branch:$branch,gate:"verdict"}')" || exit 2
  history_tree="$(compute_audit_tree_hash)" || exit 2
  history_input="$(jq -nc --arg branch "$expected_branch" --arg head "$expected_head" \
    --arg tree "$history_tree" --arg generation "$audit_generation" --slurpfile turn "$transcript_path" \
    '{binding:{branch:$branch,head:$head,tree_hash:$tree,generation:$generation},
      snapshot:{transcript:$turn,tree:$tree}}')" || exit 2
  history_request="$(audit_reflection_gate "$reflection_context" prepare "$audit_token" "$history_input")" || exit 2
  reflection_pending=true
  history_path="$(jq -r .history_path <<<"$history_request")"
fi
task_input_json="$(jq -nc \
  --arg repo_root "$repo_root" \
  --arg transcript_path "$transcript_path" \
  --arg dossier_path "$audit_output_file" \
  --arg previous_dossier_path "$previous_dossier_input_path" \
  --arg audit_generation "$audit_generation" \
  --arg expected_branch "$expected_branch" \
  --arg expected_head "$expected_head" \
  '{repo_root:$repo_root, transcript_path:$transcript_path,
    dossier_path:$dossier_path, previous_dossier_path:$previous_dossier_path,
    audit_generation:$audit_generation, expected_branch:$expected_branch,
    expected_head:$expected_head}')"
if [[ -n "$history_path" ]]; then
  task_input_json="$(jq -c --arg history "$history_path" '. + {history_path:$history}' <<<"$task_input_json")"
fi
if ! audit_prompt="$(subagent_prompt verdict-runner "$tooling_root" \
                      "task_input_json=${task_input_json}")"; then
  printf 'run-verdict-audit.sh: could not load .agents/prompts/verdict-runner.md.\n' >&2
  exit 2
fi
if [[ -n "$history_path" ]]; then
  reflection_prompt="$(subagent_prompt audit-reflection "$tooling_root")" || exit 2
  audit_prompt+=$'\nHistory schema JSON: '"$(jq -nc --arg path "$tooling_root/.agents/hooks/commit-push-audit.schema.json" '{path:$path}')"
  audit_prompt+=$'\n\n'"$reflection_prompt"
fi

# The audit must be attributable to a fresh run, not a leftover dossier, so each
# runner removes any existing one first and EXISTENCE alone then proves freshness.
# Comparing mtimes instead cannot: they are whole seconds, so an auditor that
# rewrites the dossier within the same second looks unchanged and a genuine run is
# rejected. The removal sits inside each branch, not above them: the no-runner path
# below exits 2 without auditing, and must not destroy a dossier on its way out.
start_request_monitor() {
  local runner_pid="$$"
  [[ "$session_scope" != "-" ]] || return 0
  # One process compares the exact authorized request without spawning cat/date/sleep on
  # every poll. getppid() binds the signal to this runner even if it is SIGKILLed and its
  # numeric PID is later reused. Mutex ownership lives in a separate parent-bound holder,
  # so neither this monitor nor the auditor can inherit and strand the lease.
  perl -MFcntl=:DEFAULT -e '
    my ($path, $expected, $parent) = @ARGV;

    sub read_record {
      my ($record_path) = @_;
      return if lstat($record_path) && -l _;
      my $flags = O_RDONLY | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $fh, $record_path, $flags) or return;
      my @opened = stat($fh);
      my @named = lstat($record_path);
      return unless @opened && @named && -f $fh
        && $opened[0] == $named[0] && $opened[1] == $named[1];
      my $body = "";
      while (length($body) <= 4096) {
        my $chunk = "";
        my $count = sysread($fh, $chunk, 4097 - length($body));
        return unless defined $count;
        last if $count == 0;
        $body .= $chunk;
      }
      return if length($body) > 4096;
      my @named_after = lstat($record_path);
      return unless @named_after
        && $opened[0] == $named_after[0] && $opened[1] == $named_after[1];
      return if $body =~ /[\0\r]/;
      $body =~ s/\n\z//;
      return if $body eq "" || index($body, "\n") >= 0;
      return $body;
    }

    while (getppid() == $parent) {
      my $body = read_record($path);
      if (!defined($body) || $body ne $expected) {
        kill "USR1", $parent;
        exit 0;
      }
      select(undef, undef, undef, 0.05);
    }
  ' "$audit_request_file" "$audit_request_body" "$runner_pid" 7>&- 8>&- 9>&- &
  request_monitor_pid=$!
}

start_audit_group_event_channel() {
  local channel_dir event_fifo monitor_timeout
  channel_dir="$(mktemp -d "${TMPDIR:-/tmp}/boxlite-verdict-group.XXXXXX" 2>/dev/null)" \
    || return 1
  chmod 700 "$channel_dir" 2>/dev/null || { rmdir "$channel_dir" 2>/dev/null; return 1; }
  event_fifo="$channel_dir/event"
  if ! mkfifo "$event_fifo" 2>/dev/null || ! exec 5<>"$event_fifo"; then
    exec 5>&- || true
    rm -f "$event_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  fi
  if ! exec 8<"$event_fifo" || ! exec 9>"$event_fifo"; then
    exec 5>&- 8>&- 9>&- || true
    rm -f "$event_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  fi
  exec 5>&-
  rm -f "$event_fifo" 2>/dev/null || true
  rmdir "$channel_dir" 2>/dev/null || true
  monitor_timeout="$(( audit_timeout_seconds + 5 ))"
  # A direct child owns the event read. A valid `done N` record means the model command
  # returned; EOF, malformed bytes, or timeout is a fail-closed completion failure.
  perl -e '
    my $timeout = shift;
    $SIG{ALRM} = sub { exit 2 };
    alarm $timeout;
    my $line = <STDIN>;
    exit 2 unless defined($line) && $line =~ /\Adone [0-9]+\n\z/;
    alarm 0;
    exit 0;
  ' "$monitor_timeout" <&8 7>&- 8<&- 9>&- &
  audit_group_event_monitor_pid=$!
  audit_group_event_write_open=true
  exec 8<&-
  return 0
}

stop_audit_group_event_monitor() {
  local monitor_status=0
  if [[ "$audit_group_event_write_open" == true ]]; then
    exec 9>&-
    audit_group_event_write_open=false
  fi
  if [[ "$audit_group_event_monitor_pid" =~ ^[1-9][0-9]*$ ]]; then
    wait "$audit_group_event_monitor_pid" 2>/dev/null || monitor_status=$?
  fi
  audit_group_event_monitor_pid=0
  return "$monitor_status"
}

publish_audit_group_completion() {  # command-status
  printf 'done %s\n' "$1" >&9
}

run_in_audit_group() {
  local command_prompt="$1" runner_pid="$$" command_status="" monitor_status=0
  shift
  # Job control gives this one background sentinel a fresh process group on Bash 3,
  # available on both macOS and Linux. The sentinel runs and reaps the model pipeline,
  # publishes completion over a parent-owned unlinked FIFO, then remains alive so
  # audit_pgid is still an owned group identity during teardown.
  start_audit_group_event_channel || return 1
  audit_launching=true
  set -m
  if [[ -n "$pending_cancel_code" ]]; then
    set +m
    audit_launching=false
    cancel_audit "$pending_cancel_code" "$pending_cancel_reason" "$pending_cancel_tombstone"
  fi
  # The separate holder owns the kernel lease; model/tool descendants inherit none of it.
  # TERM reaches the work but the sentinel deliberately survives it until KILL, retaining
  # the kernel identity that makes a negative-PGID escalation safe.
  (
    # Only the runner owns the lease-control writer. The audit group cannot keep that
    # channel open after parent cleanup, and model/tool descendants never receive either
    # private protocol descriptor.
    exec 7>&-
    trap - EXIT USR1 USR2
    trap ':' INT TERM
    # A dead event reader must make printf return failure, not terminate this PGID
    # anchor with SIGPIPE before its parent-notification fallback can run.
    trap '' PIPE
    if ! cd "$project_dir"; then
      command_status=125
    else
      printf '%s' "$command_prompt" | "$@" 8>&- 9>&-
      command_status=$?
    fi
    if ! publish_audit_group_completion "$command_status"; then
      # Preserve the anchor. After exec this process is still the runner's direct child,
      # so getppid() makes the exceptional notification immune to PID reuse.
      exec perl -e '
        my $parent = shift;
        kill "USR2", $parent if getppid() == $parent;
        $SIG{TERM} = sub {};
        $SIG{INT} = sub {};
        select(undef, undef, undef, 0.05) while getppid() == $parent;
      ' "$runner_pid" 9>&-
    fi
    # Preserve this PID/PGID but switch to a parent-bound sleeper. Perl getppid() tracks
    # the real parent (unlike Bash 3 subshell $PPID), and no child `sleep` process is
    # manufactured for residual-member detection to chase.
    exec perl -e '
      my $parent = shift;
      $SIG{TERM} = sub {};
      $SIG{INT} = sub {};
      select(undef, undef, undef, 0.05) while getppid() == $parent;
    ' "$runner_pid" 9>&-
  ) &
  audit_pgid=$!
  audit_group_identity_owned=true
  exec 9>&-
  audit_group_event_write_open=false
  set +m
  audit_launching=false
  if [[ -n "$pending_cancel_code" ]]; then
    cancel_audit "$pending_cancel_code" "$pending_cancel_reason" "$pending_cancel_tombstone"
  fi
  start_request_monitor
  wait "$audit_group_event_monitor_pid" 2>/dev/null || monitor_status=$?
  audit_group_event_monitor_pid=0
  if (( monitor_status != 0 )); then
    quiesce_audit_group
    return 1
  fi
  quiesce_audit_group
  return 0
}

fail_audit_publication() {  # diagnostic
  if ! audit_request_is_current; then
    cancel_audit 130 "the audit generation was revoked during publication"
  fi
  printf 'run-verdict-audit.sh: %s\n' "$1" >&2
  exit 1
}

export VERDICT_AUDITOR_OUTPUT_FILE="$audit_output_file"
export VERDICT_AUDITOR_GENERATION="$audit_generation"
if [[ -n "${VERDICT_AUDITOR_CMD:-}" ]]; then
  if [[ ! -r "$spec_file" ]]; then
    printf 'run-verdict-audit.sh: missing %s — cannot load the audit procedure.\n' \
      "$spec_file" >&2
    exit 2
  fi
  spec_body="$(strip_frontmatter "$spec_file")"
  # The stable procedure comes first so repeated headless audits can reuse that prefix;
  # only the bounded runner task and its JSON input vary by generation.
  audit_prompt="${spec_body}"$'\n\n'"${audit_prompt}"
  audit_started=true
  remove_owned_verdict
  rm -f "$audit_output_file"
  if ! run_in_audit_group \
      "$audit_prompt" \
      perl -e 'alarm shift; exec @ARGV' "$audit_timeout_seconds" \
        bash -c "$VERDICT_AUDITOR_CMD"; then
    rm -f "$audit_output_file"
    remove_owned_verdict while-current
    echo "run-verdict-audit.sh: auditor process group ended without a usable completion" >&2
    exit 1
  fi
elif command -v claude >/dev/null 2>&1 && [[ -r "$spec_file" ]]; then
  audit_started=true
  remove_owned_verdict
  rm -f "$audit_output_file"
  spec_body="$(strip_frontmatter "$spec_file")"
  # Safe mode retains OAuth/keychain auth while dropping project/plugin/memory/hook
  # context. Replace the coding-agent prompt with the stripped auditor procedure and
  # expose only its three required tools; --name suppresses a separate title request.
  # perl alarm remains the portable outer timeout for the complete agent/tool loop.
  if ! run_in_audit_group \
      "$audit_prompt" \
      perl -e 'alarm shift; exec @ARGV' "$audit_timeout_seconds" \
        claude -p --safe-mode --system-prompt "$spec_body" \
          --tools Read Bash Write --effort xhigh --name verdict-auditor \
          --no-session-persistence --model "$auditor_model"; then
    rm -f "$audit_output_file"
    remove_owned_verdict while-current
    echo "run-verdict-audit.sh: auditor process group ended without a usable completion" >&2
    exit 1
  fi
elif codex_bin="$(find_codex_bin)" && [[ -r "$spec_file" ]]; then
  audit_started=true
  remove_owned_verdict
  rm -f "$audit_output_file"
  spec_body="$(strip_frontmatter "$spec_file")"
  if ! codex_tree_hash="$(compute_audit_tree_hash)"; then
    remove_owned_verdict while-current
    printf 'run-verdict-audit.sh: could not capture the working-tree hash for the read-only Codex auditor.\n' >&2
    exit 1
  fi
  codex_prompt="${spec_body}

${audit_prompt}

READ-ONLY DELIVERY OVERRIDE FOR THIS CODEX INVOCATION:
- Do not write or modify any file, including verdict_file.
- In procedure step 2, run the two read-only branch and HEAD commands, but do not
  create the temporary Git index. Use this parent-captured tree_hash exactly:
  ${codex_tree_hash}
- For Tier-2, inspect any existing isolated red-to-green evidence in the transcript;
  do not create another worktree. If required evidence is absent, use step 5's
  blocked-proof form and state that residual risk.
- Replace procedure steps 6 and 7 with: return ONLY the dossier JSON object as your
  final response, with no Markdown fence or commentary.
- The Codex host captures that final response into a generation-owned staging file.
  The parent runner alone validates and publishes the authoritative dossier."
  if ! run_in_audit_group \
      "$codex_prompt" \
      perl -e 'alarm shift; exec @ARGV' "$audit_timeout_seconds" \
        "$codex_bin" --ask-for-approval never \
          exec \
          --disable hooks \
          --ignore-user-config \
          --sandbox read-only \
          --cd "$project_dir" \
          --ephemeral \
          --output-last-message "$audit_output_file" \
          - >/dev/null 2>&1; then
    rm -f "$audit_output_file"
    remove_owned_verdict while-current
    echo "run-verdict-audit.sh: auditor process group ended without a usable completion" >&2
    exit 1
  fi
else
  cat >&2 <<'EOF'
run-verdict-audit.sh: no auditor runner available.
Set VERDICT_AUDITOR_CMD (stdin = audit prompt; it must write the requested dossier path)
or install the Claude or Codex CLI. As a last resort, execute the procedure in
.claude/agents/verdict-auditor.md with any capable model and have IT write the dossier.
EOF
  exit 2
fi

if ! audit_request_is_current; then
  cancel_audit 130 "the audit generation was revoked before publication"
fi

audit_output_snapshot=""
audit_json=""
if audit_output_snapshot="$(verdict_audit_read_json_snapshot \
    "$audit_output_file" 2>/dev/null)" \
   && [[ "$audit_output_snapshot" == *$'\n'* ]]; then
  audit_json="${audit_output_snapshot#*$'\n'}"
fi
audit_json="$(printf '%s' "$audit_json" \
  | verdict_audit_normalize_dossier 2>/dev/null || true)"
audit_output_generation="$(printf '%s' "$audit_json" \
  | jq -r '.generation // ""' 2>/dev/null || echo '')"
audit_verdict="$(printf '%s' "$audit_json" \
  | jq -r '.verdict // ""' 2>/dev/null || echo '')"
generation_matches=false
if [[ "$audit_generation" == "legacy" ]]; then
  [[ -z "$audit_output_generation" || "$audit_output_generation" == "legacy" ]] \
    && generation_matches=true
elif [[ "$audit_output_generation" == "$audit_generation" ]]; then
  generation_matches=true
fi

audit_json_is_valid=false
[[ -n "$audit_json" ]] && audit_json_is_valid=true

if [[ "$generation_matches" == true && "$audit_json_is_valid" == true ]]; then
  if [[ "$reflection_pending" == true ]]; then
    audit_reflection_gate "$reflection_context" record "$audit_token" "$audit_json" >/dev/null || exit 1
    reflection_pending=false
  fi
  # Promote bytes already parsed from the selected regular inode, never the auditor's
  # pathname. This closes both FIFO blocking and validate-then-rename replacement races.
  audit_verified_file="${audit_output_file}.verified-${audit_token}"
  if ! printf '%s\n' "$audit_json" \
      | verdict_audit_write_exclusive_regular "$audit_verified_file" 2>/dev/null; then
    rm -f "$audit_output_file" 2>/dev/null || true
    remove_owned_verdict while-current
    fail_audit_publication "could not stage verified output for $verdict_file"
  fi
  audit_verified_identity="$(verdict_audit_path_identity \
    "$audit_verified_file" 2>/dev/null)" || audit_verified_identity=""
  rm -f "$audit_output_file" 2>/dev/null || true
  verified_stage_snapshot="$(verdict_audit_read_json_snapshot \
    "$audit_verified_file" 2>/dev/null)" || verified_stage_snapshot=""
  verified_stage_json=""
  [[ "$verified_stage_snapshot" == *$'\n'* ]] \
    && verified_stage_json="${verified_stage_snapshot#*$'\n'}"
  verified_stage_json="$(printf '%s' "$verified_stage_json" \
    | verdict_audit_normalize_dossier 2>/dev/null || true)"
  if [[ -z "$audit_verified_identity" \
     || "$verified_stage_json" != "$audit_json" ]] \
     || ! verdict_audit_selected_identity_matches \
          "$audit_verified_file" "$audit_verified_identity" 2>/dev/null; then
    rm -f "$audit_verified_file" 2>/dev/null || true
    audit_verified_file=""
    audit_verified_identity=""
    fail_audit_publication "verified stage changed before publication"
  fi
  published_identity=""
  if [[ -d "$verdict_file" ]] \
     || ! published_identity="$(verdict_audit_link_no_clobber_identity \
          "$audit_verified_file" "$verdict_file" 2>/dev/null)"; then
    rm -f "$audit_verified_file" 2>/dev/null || true
    audit_verified_file=""
    audit_verified_identity=""
    fail_audit_publication "could not promote the audit dossier to $verdict_file"
  fi
  published_snapshot="$(verdict_audit_read_json_snapshot \
    "$verdict_file" 2>/dev/null)" || published_snapshot=""
  published_json=""
  [[ "$published_snapshot" == *$'\n'* ]] \
    && published_json="${published_snapshot#*$'\n'}"
  published_json="$(printf '%s' "$published_json" \
    | verdict_audit_normalize_dossier 2>/dev/null || true)"
  if [[ "$published_identity" != "$audit_verified_identity" \
     || "$published_json" != "$audit_json" ]] \
     || ! verdict_audit_selected_identity_matches \
          "$verdict_file" "$published_identity" 2>/dev/null; then
    verdict_audit_unlink_if_identity \
      "$verdict_file" "$published_identity" >/dev/null 2>&1 || true
    rm -f "$audit_verified_file" 2>/dev/null || true
    audit_verified_file=""
    audit_verified_identity=""
    fail_audit_publication "published dossier changed before acceptance"
  fi
  if ! audit_request_is_current; then
    cancel_audit 130 "the audit generation was revoked during publication"
  fi
  # EXIT cleanup performs the final lease handshake. It prints success only after that
  # commit point; a late lease failure must never leave a contradictory success line.
  audit_success_pending=true
  exit 0
fi

rm -f "$audit_output_file"
[[ -z "$audit_verified_file" ]] || rm -f "$audit_verified_file"
audit_verified_file=""
audit_verified_identity=""
remove_owned_verdict while-current
echo "run-verdict-audit.sh: audit ran but no fresh dossier was written to $verdict_file" >&2
exit 1
