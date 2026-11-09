#!/usr/bin/env bash
# Claim and multiplex one bounded pre-push attachment manifest. Each child uses
# the producer-assigned generation id, so history from an older watch cannot end
# a newly armed stream.
set -uo pipefail

readonly MAX_REFS=4
readonly CHILD_MAX_EVENTS=16
readonly CHILD_MAX_BYTES=8192
readonly DEFAULT_ATTACH_MAX_EVENTS=16
readonly DEFAULT_ATTACH_MAX_BYTES=8192
readonly HARD_ATTACH_MAX_EVENTS=64
readonly HARD_ATTACH_MAX_BYTES=32768
readonly ATTACH_SUMMARY_RESERVE_BYTES=512

manifest="${1:-}"
expected_manifest_identity=""
expected_manifest_hash=""
if [[ -n "$manifest" && $# -eq 3 ]]; then
  expected_manifest_identity="$2"
  expected_manifest_hash="$3"
  [[ "$expected_manifest_identity" =~ ^[0-9]+:[0-9]+$ \
     && "$expected_manifest_hash" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'pr-watch-attach: invalid claim binding\n' >&2
    exit 2
  }
elif [[ -z "$manifest" || $# -ne 1 ]]; then
  printf 'usage: pr-watch-attach.sh <claimed-manifest> [device:inode sha256]\n' >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="$script_dir/../lib"
# shellcheck source=../lib/verdict-audit-state.sh
source "$lib_dir/verdict-audit-state.sh" || {
  printf 'pr-watch-attach: cannot load %s\n' "$lib_dir/verdict-audit-state.sh" >&2
  exit 127
}
# shellcheck source=../lib/pr-watch-state.sh
source "$lib_dir/pr-watch-state.sh" || {
  printf 'pr-watch-attach: cannot load %s\n' "$lib_dir/pr-watch-state.sh" >&2
  exit 127
}

attach_max_events="${PR_WATCH_ATTACH_MAX_EVENTS:-$DEFAULT_ATTACH_MAX_EVENTS}"
attach_max_bytes="${PR_WATCH_ATTACH_MAX_BYTES:-$DEFAULT_ATTACH_MAX_BYTES}"
pr_watch_positive_decimal_is_bounded "$attach_max_events" \
  && pr_watch_positive_decimal_is_bounded "$attach_max_bytes" || {
  printf 'pr-watch-attach: aggregate limits must be positive integers\n' >&2
  exit 2
}
(( attach_max_events >= 2 && attach_max_events <= HARD_ATTACH_MAX_EVENTS )) || {
  printf 'pr-watch-attach: aggregate event limit must be 2..%d\n' \
    "$HARD_ATTACH_MAX_EVENTS" >&2
  exit 2
}
(( attach_max_bytes > ATTACH_SUMMARY_RESERVE_BYTES \
   && attach_max_bytes <= HARD_ATTACH_MAX_BYTES )) || {
  printf 'pr-watch-attach: aggregate byte limit must be %d..%d\n' \
    "$((ATTACH_SUMMARY_RESERVE_BYTES + 1))" "$HARD_ATTACH_MAX_BYTES" >&2
  exit 2
}

manifest_name="${manifest##*/}"
[[ "$manifest_name" =~ ^attach-[0-9a-f]{64}\.json\.claim\.[0-3]$ ]] || {
  printf 'pr-watch-attach: invalid claimed-manifest name\n' >&2
  exit 1
}
manifest_parent_input="${manifest%/*}"
[[ "$manifest_parent_input" != "$manifest" ]] || manifest_parent_input="."
manifest_parent="$(cd "$manifest_parent_input" 2>/dev/null && pwd -P)" || {
  printf 'pr-watch-attach: attachment state directory is unavailable\n' >&2
  exit 1
}
manifest_parent_identity="$(pr_watch_state_directory_identity \
  "$manifest_parent" 2>/dev/null)" || {
  printf 'pr-watch-attach: attachment state directory is unsafe\n' >&2
  exit 1
}
manifest="$manifest_parent/$manifest_name"
manifest_identity="$(verdict_audit_path_identity "$manifest" 2>/dev/null)" || {
  printf 'pr-watch-attach: attachment is unavailable\n' >&2
  exit 1
}
if [[ -n "$expected_manifest_identity" \
   && "$manifest_identity" != "$expected_manifest_identity" ]]; then
  printf 'pr-watch-attach: attachment claim binding mismatch\n' >&2
  exit 1
fi
snapshot="$(verdict_audit_read_json_snapshot "$manifest" 2>/dev/null)" || {
  printf 'pr-watch-attach: invalid attachment manifest\n' >&2
  exit 1
}
verdict_audit_selected_identity_matches "$manifest" "$manifest_identity" \
  2>/dev/null \
  && verdict_audit_selected_identity_matches \
    "$manifest_parent" "$manifest_parent_identity" 2>/dev/null || {
    printf 'pr-watch-attach: attachment manifest changed while claimed\n' >&2
    exit 1
  }
[[ "$snapshot" == *$'\n'* ]] || {
  printf 'pr-watch-attach: invalid attachment snapshot\n' >&2
  exit 1
}
manifest_mtime="${snapshot%%$'\n'*}"
body="${snapshot#*$'\n'}"
manifest_hash="$(LC_ALL=C printf '%s' "$body" | verdict_audit_sha256)"
if [[ -n "$expected_manifest_hash" \
   && "$manifest_hash" != "$expected_manifest_hash" ]]; then
  printf 'pr-watch-attach: attachment claim binding mismatch\n' >&2
  exit 1
fi

# The three-argument form is a delayed capability rendered into an agent turn.
# Its inode/hash binding prevents replacement, but that binding alone must not
# outlive the prompt that authorized it. Recheck every lifecycle input before
# the one-shot consume; rejection deliberately leaves the claim unconsumed.
if [[ -n "$expected_manifest_identity" ]]; then
  now="$(date +%s)"
  if [[ ! "$manifest_mtime" =~ ^[1-9][0-9]*$ \
     || ${#manifest_mtime} -gt 18 \
     || "$manifest_mtime" -gt "$now" \
     || $((now - manifest_mtime)) -gt 600 ]]; then
    printf 'pr-watch-attach: attachment claim lease expired\n' >&2
    exit 1
  fi

  printf '%s' "$body" | jq -e -L "$lib_dir" --argjson now "$now" '
    include "pr-watch-attachment"; pr_watch_attachment_lifecycle($now; 600)' \
    >/dev/null 2>&1 || {
    printf 'pr-watch-attach: attachment lifecycle schema rejected\n' >&2
    exit 1
  }

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'pr-watch-attach: attachment repository is unavailable\n' >&2
    exit 1
  }
  repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || {
    printf 'pr-watch-attach: attachment repository is unavailable\n' >&2
    exit 1
  }
  expected_state_dir="$(git -C "$repo_root" rev-parse --git-path pr-watch \
    2>/dev/null)" || {
    printf 'pr-watch-attach: attachment repository state is unavailable\n' >&2
    exit 1
  }
  [[ "$expected_state_dir" == /* ]] \
    || expected_state_dir="$repo_root/$expected_state_dir"
  expected_state_dir="$(cd "$expected_state_dir" 2>/dev/null && pwd -P)" || {
    printf 'pr-watch-attach: attachment repository state is unavailable\n' >&2
    exit 1
  }
  [[ "$expected_state_dir" == "$manifest_parent" ]] || {
    printf 'pr-watch-attach: attachment repository binding mismatch\n' >&2
    exit 1
  }

  session_scope="$(printf '%s' "$body" | jq -r '.session_scope')"
  prompt_epoch="$(printf '%s' "$body" | jq -r '.prompt_epoch')"
  prompt_epoch_path="$(verdict_audit_state_path \
    "$repo_root/.agents/state/verdict-prompt-epoch" "$session_scope")"
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$prompt_epoch_path" 2>/dev/null)" || {
    printf 'pr-watch-attach: attachment prompt epoch is unavailable\n' >&2
    exit 1
  }
  [[ "$current_prompt_epoch" == "$prompt_epoch" ]] || {
    printf 'pr-watch-attach: attachment prompt epoch was revoked\n' >&2
    exit 1
  }
  owner_pid="$(printf '%s' "$body" | jq -r '.owner.pid')"
  owner_token="$(printf '%s' "$body" | jq -r '.owner.start_token')"
  verdict_audit_process_has_ancestor "$owner_pid" "$owner_token" || {
    printf 'pr-watch-attach: attachment session owner is no longer current\n' >&2
    exit 1
  }
fi

# Branch validation below invokes external helpers. Repeat the mutable lifecycle
# observations after that work, adjacent to the claim's consume point. The
# claim inode/body and repository directory are immutable bindings; owner,
# lease, and prompt epoch are intentionally sampled again in that order so the
# prompt epoch is the final authorization observation.
attachment_lifecycle_is_current() {
  local current_snapshot current_mtime current_body current_hash created_at
  local current_prompt_epoch now
  [[ -n "$expected_manifest_identity" ]] || return 0
  current_snapshot="$(verdict_audit_read_json_snapshot "$manifest" 2>/dev/null)" \
    || {
      printf 'pr-watch-attach: attachment lifecycle snapshot is unavailable\n' >&2
      return 1
    }
  [[ "$current_snapshot" == *$'\n'* ]] || {
    printf 'pr-watch-attach: attachment lifecycle snapshot is invalid\n' >&2
    return 1
  }
  verdict_audit_selected_identity_matches "$manifest" "$manifest_identity" \
    2>/dev/null \
    && verdict_audit_selected_identity_matches \
      "$manifest_parent" "$manifest_parent_identity" 2>/dev/null || {
    printf 'pr-watch-attach: attachment changed before consumption\n' >&2
    return 1
  }
  current_mtime="${current_snapshot%%$'\n'*}"
  current_body="${current_snapshot#*$'\n'}"
  current_hash="$(LC_ALL=C printf '%s' "$current_body" | verdict_audit_sha256)" \
    || return 1
  [[ "$current_hash" == "$manifest_hash" ]] || {
    printf 'pr-watch-attach: attachment changed before consumption\n' >&2
    return 1
  }
  created_at="$(printf '%s' "$current_body" | jq -r '.created_at')" || return 1
  [[ "$created_at" =~ ^[1-9][0-9]*$ && ${#created_at} -le 18 ]] || {
    printf 'pr-watch-attach: attachment creation time is invalid\n' >&2
    return 1
  }
  verdict_audit_process_has_ancestor "$owner_pid" "$owner_token" || {
    printf 'pr-watch-attach: attachment session owner is no longer current\n' >&2
    return 1
  }
  now="$(date +%s)"
  if [[ ! "$current_mtime" =~ ^[1-9][0-9]*$ \
     || ${#current_mtime} -gt 18 \
     || "$current_mtime" -gt "$now" \
     || $((now - current_mtime)) -gt 600 \
     || "$created_at" -gt "$now" \
     || $((now - created_at)) -gt 600 ]]; then
    printf 'pr-watch-attach: attachment claim lease expired\n' >&2
    return 1
  fi
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$prompt_epoch_path" 2>/dev/null)" || {
    printf 'pr-watch-attach: attachment prompt epoch is unavailable\n' >&2
    return 1
  }
  [[ "$current_prompt_epoch" == "$prompt_epoch" ]] || {
    printf 'pr-watch-attach: attachment prompt epoch was revoked\n' >&2
    return 1
  }
}

printf '%s' "$body" | jq -e -L "$lib_dir" \
  'include "pr-watch-attachment"; pr_watch_attachment_entries' >/dev/null 2>&1 || {
    printf 'pr-watch-attach: attachment schema rejected\n' >&2
    exit 1
  }

runtime_dir="$(mktemp -d)" || {
  printf 'pr-watch-attach: cannot allocate aggregate stream state\n' >&2
  exit 1
}
event_fifo="$runtime_dir/events"
delivery_fifo="$runtime_dir/delivery-ack"
if ! mkfifo "$event_fifo" "$delivery_fifo"; then
  rm -f "$event_fifo" "$delivery_fifo" 2>/dev/null || true
  rmdir "$runtime_dir" 2>/dev/null || true
  printf 'pr-watch-attach: cannot create aggregate stream\n' >&2
  exit 1
fi
delivery_nonce="$(LC_ALL=C printf '%s' \
  "$runtime_dir:$$:${RANDOM:-0}" | verdict_audit_sha256)"
[[ "$delivery_nonce" =~ ^[0-9a-f]{64}$ ]] || {
  rm -f "$event_fifo" "$delivery_fifo" 2>/dev/null || true
  rmdir "$runtime_dir" 2>/dev/null || true
  printf 'pr-watch-attach: cannot bind aggregate delivery\n' >&2
  exit 1
}

children=()
attach_child_launch_in_progress=0
pending_attach_signal_status=0
event_reader_open=0
event_fifo_guard_open=0
delivery_fifo_guard_open=0
cleanup_children() {
  local pid
  local -a active_children=()
  [[ -n "${children[*]-}" ]] && active_children=("${children[@]}")
  children=()
  if [[ -n "${active_children[*]-}" ]]; then
    for pid in "${active_children[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${active_children[@]}"; do wait "$pid" 2>/dev/null || true; done
  fi
}
# shellcheck disable=SC2329 # Invoked by the EXIT/TERM/INT traps below.
cleanup_runtime() {
  if (( event_reader_open )); then
    exec 3<&-
    event_reader_open=0
  fi
  if (( event_fifo_guard_open )); then
    exec 9>&-
    event_fifo_guard_open=0
  fi
  if (( delivery_fifo_guard_open )); then
    exec 7>&-
    delivery_fifo_guard_open=0
  fi
  rm -f "$event_fifo" "$delivery_fifo" 2>/dev/null || true
  rmdir "$runtime_dir" 2>/dev/null || true
}
cleanup_all() {
  cleanup_children
  cleanup_runtime
}
attach_signal_shutdown() {  # signal-style exit status
  local status="$1"
  if (( attach_child_launch_in_progress )); then
    (( pending_attach_signal_status != 0 )) \
      || pending_attach_signal_status="$status"
    return 0
  fi
  trap '' TERM INT
  cleanup_all
  exit "$status"
}
finish_attach_child_launch() {
  local status
  attach_child_launch_in_progress=0
  (( pending_attach_signal_status != 0 )) || return 0
  status="$pending_attach_signal_status"
  pending_attach_signal_status=0
  attach_signal_shutdown "$status"
}
trap 'attach_signal_shutdown 143' TERM
trap 'attach_signal_shutdown 130' INT
trap 'cleanup_all' EXIT

stream_args=()
while IFS=$'\t' read -r branch watch_id event_log; do
  event_log_parent="$(cd "${event_log%/*}" 2>/dev/null && pwd -P)" || {
    printf 'pr-watch-attach: event-log identity mismatch\n' >&2
    cleanup_children
    exit 1
  }
  branch_key="$(pr_watch_branch_key "$branch" 2>/dev/null)" || {
    printf 'pr-watch-attach: invalid branch identity\n' >&2
    cleanup_children
    exit 1
  }
  if [[ "$event_log_parent" != "$manifest_parent" \
       || "${event_log##*/}" != "${branch_key}.jsonl" ]] \
     || ! verdict_audit_selected_identity_matches \
       "$manifest_parent" "$manifest_parent_identity" 2>/dev/null; then
    printf 'pr-watch-attach: event-log identity mismatch\n' >&2
    cleanup_children
    exit 1
  fi
  stream_args+=("$event_log" "$watch_id")
done < <(printf '%s' "$body" | jq -r '.entries[] | [.branch,.watch_id,.event_log] | @tsv')

attachment_lifecycle_is_current || exit 1

# Keep one reader/writer open while the background command installs its stdout
# redirection. If this shell is killed in that fork-to-reader interval, the
# serializer has already opened the FIFO and can finish launch ownership instead
# of remaining orphaned in a blocking open(2).
if ! exec 9<> "$event_fifo"; then
  printf 'pr-watch-attach: cannot guard aggregate stream\n' >&2
  exit 1
fi
event_fifo_guard_open=1
if ! exec 7<> "$delivery_fifo"; then
  printf 'pr-watch-attach: cannot guard aggregate delivery\n' >&2
  exit 1
fi
delivery_fifo_guard_open=1

# One process owns the aggregate FIFO. Child stdout travels over private pipes;
# the serializer buffers complete LF-terminated records through the end of every
# stream before it delivers any record. This preserves JSONL framing and makes
# the serializer the one generation-bound finalizer: its exclusive claim lease
# remains recoverable through fork, readiness, and drain. Only a successful
# bounded drain is delivered and consumed; an interrupted drain leaves the exact
# JSON claim retryable.
attach_child_launch_in_progress=1
PR_WATCH_STREAM_MAX_EVENTS="$CHILD_MAX_EVENTS" \
PR_WATCH_STREAM_MAX_BYTES="$CHILD_MAX_BYTES" \
  perl -MIO::Select \
    -MPOSIX=SIG_BLOCK,SIG_SETMASK,SIGTERM,SIGINT,dup2,sigprocmask -e '
    use strict;
    use warnings;
    use Config;
    use Digest::SHA qw(sha256_hex);
    use Fcntl qw(:DEFAULT :flock);
    use IO::Handle;

    my ($claim_path, $expected_identity, $expected_hash,
        $stream_script, $max_drained_bytes, $delivery_nonce, @stream_args) = @ARGV;
    exit 2 unless defined($claim_path) && defined($stream_script)
      && $expected_identity =~ /\A[0-9]+:[0-9]+\z/
      && $expected_hash =~ /\A[0-9a-f]{64}\z/
      && defined($max_drained_bytes)
      && $max_drained_bytes =~ /\A[1-9][0-9]*\z/
      && length($max_drained_bytes) <= 6
      && $max_drained_bytes <= 32768
      && defined($delivery_nonce) && $delivery_nonce =~ /\A[0-9a-f]{64}\z/
      && @stream_args > 0
      && @stream_args % 2 == 0;

    exit 1 if lstat($claim_path) && -l _;
    my $claim_flags = O_RDWR | O_NONBLOCK;
    $claim_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $claim, $claim_path, $claim_flags) or exit 1;
    flock($claim, LOCK_EX | LOCK_NB) or exit 1;
    my @claim_opened = stat($claim);
    my @claim_named = lstat($claim_path);
    exit 1 unless @claim_opened && @claim_named && -f $claim
      && ($claim_opened[3] == 1 || $claim_opened[3] == 2)
      && ($claim_opened[0] . q{:} . $claim_opened[1]) eq $expected_identity
      && $claim_opened[0] == $claim_named[0]
      && $claim_opened[1] == $claim_named[1]
      && $claim_opened[7] > 0 && $claim_opened[7] <= 65536;
    my $claim_body = q{};
    while (length($claim_body) <= 65536) {
      my $chunk = q{};
      my $count = sysread(
        $claim, $chunk, 65537 - length($claim_body));
      next if !defined($count) && $!{EINTR};
      exit 1 unless defined($count);
      last if $count == 0;
      $claim_body .= $chunk;
    }
    exit 1 if length($claim_body) > 65536 || $claim_body =~ /[\0\r]/;
    $claim_body =~ s/\n\z//;
    exit 1 if $claim_body eq q{} || index($claim_body, qq{\n}) >= 0
      || sha256_hex($claim_body) ne $expected_hash;
    # Each stream duplicates this open description to descriptor 8 before exec.
    # pr-watch-stream reserves descriptor 3 for its stable journal and descriptor
    # 4 for readiness, so descriptor 8 remains the inherited generation lease.
    fcntl($claim, F_SETFD, 0) or exit 1;
    open(my $delivery_ack, q{<&=7}) or exit 1;

    my $selector = IO::Select->new();
    my (%buffer_for, %pid_for);
    my $drained_output = q{};
    my $status = 0;
    my $stopping = 0;
    my $is_parent = 1;
    my $signals_are_blocked = 0;
    my $launch_signals = POSIX::SigSet->new(SIGTERM, SIGINT);
    my $previous_signals = POSIX::SigSet->new();

    # A signal may arrive after fork returns but before the PID enters
    # %pid_for. Block both shutdown signals across each fork-to-publication
    # interval; children restore defaults, and the parent unblocks only after it
    # owns the PID needed to reap that launch.
    sigprocmask(SIG_BLOCK, $launch_signals, $previous_signals) or exit 1;
    $signals_are_blocked = 1;

    $SIG{TERM} = sub {
      $stopping = 143;
      kill(q{TERM}, values(%pid_for)) if %pid_for;
    };
    $SIG{INT} = sub {
      $stopping = 130;
      kill(q{TERM}, values(%pid_for)) if %pid_for;
    };

    END {
      if ($is_parent && %pid_for) {
        my $exit_status = $?;
        my @remaining = values(%pid_for);
        kill(q{TERM}, @remaining);
        waitpid($_, 0) for @remaining;
        $? = $exit_status;
      }
    }

    sub remember_status {
      my ($raw) = @_;
      my $value = ($raw & 127) ? 128 + ($raw & 127) : $raw >> 8;
      $status = $value if $value != 0 && $status == 0;
    }

    sub write_all {
      my ($record) = @_;
      my $offset = 0;
      while ($offset < length($record)) {
        exit($stopping) if $stopping;
        my $written = syswrite(STDOUT, $record, length($record) - $offset, $offset);
        next if !defined($written) && $!{EINTR} && !$stopping;
        exit($stopping || 1) unless defined($written) && $written > 0;
        $offset += $written;
      }
    }

    sub retain_record {
      my ($record) = @_;
      exit 1 if length($drained_output) + length($record) > $max_drained_bytes;
      $drained_output .= $record;
    }

    sub await_delivery_ack {
      my $expected = q{delivered:} . $delivery_nonce . qq{\n};
      my $record = q{};
      while (length($record) < length($expected)) {
        my $chunk = q{};
        my $count = sysread(
          $delivery_ack, $chunk, length($expected) - length($record));
        next if !defined($count) && $!{EINTR} && !$stopping;
        exit($stopping || 1) unless defined($count) && $count > 0;
        $record .= $chunk;
      }
      close($delivery_ack) or exit 1;
      exit 1 unless $record eq $expected;
    }

    sub await_ready {
      my ($reader) = @_;
      my $ready_selector = IO::Select->new($reader);
      my $record = q{};
      while (length($record) < 6) {
        my @readable = $ready_selector->can_read(5);
        return 0 unless @readable;
        my $chunk = q{};
        my $count = sysread($reader, $chunk, 6 - length($record));
        next if !defined($count) && $!{EINTR} && !$stopping;
        return 0 unless defined($count) && $count > 0;
        $record .= $chunk;
      }
      return $record eq qq{ready\n};
    }

    sub exchange_paths {
      my ($first, $second) = @_;
      my $os = $Config{osname} // q{};
      my $arch = $Config{archname} // q{};
      my ($call, $cwd, $flag);
      if ($os eq q{darwin}) {
        ($call, $cwd, $flag) = (488, -2, 2);
      } elsif ($os eq q{linux}) {
        ($cwd, $flag) = (-100, 2);
        if ($arch =~ /\A(?:x86_64|amd64)/) { $call = 316 }
        elsif ($arch =~ /\A(?:aarch64|arm64|riscv64|loongarch64)/) { $call = 276 }
        elsif ($arch =~ /\Ai[3-6]86/) { $call = 353 }
        elsif ($arch =~ /\Aarm/) { $call = 382 }
        elsif ($arch =~ /\Appc64/) { $call = 357 }
        elsif ($arch =~ /\As390x/) { $call = 347 }
        else { return 0 }
      } else {
        return 0;
      }
      return syscall($call, $cwd, $first, $cwd, $second, $flag) == 0;
    }

    sub publish_tombstone {
      my $tombstone_path = $claim_path . q{.launch-tombstone};
      exit 1 if lstat($tombstone_path) && -l _;
      my $flags = O_RDWR | O_CREAT | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $tombstone_file, $tombstone_path, $flags, 0600) or exit 1;
      flock($tombstone_file, LOCK_EX | LOCK_NB) or exit 1;
      my @tombstone_opened = stat($tombstone_file);
      my @tombstone_named = lstat($tombstone_path);
      exit 1 unless @tombstone_opened && @tombstone_named
        && -f $tombstone_file && $tombstone_opened[3] == 1
        && $tombstone_opened[0] == $tombstone_named[0]
        && $tombstone_opened[1] == $tombstone_named[1];
      my $record = q{consumed:} . $expected_identity . q{:}
        . $expected_hash . qq{\n};
      truncate($tombstone_file, 0) or exit 1;
      sysseek($tombstone_file, 0, 0) or exit 1;
      my $offset = 0;
      while ($offset < length($record)) {
        my $written = syswrite(
          $tombstone_file, $record, length($record) - $offset, $offset);
        next if !defined($written) && $!{EINTR};
        exit 1 unless defined($written) && $written > 0;
        $offset += $written;
      }
      $tombstone_file->sync or exit 1;
      @claim_opened = stat($claim);
      @claim_named = lstat($claim_path);
      @tombstone_opened = stat($tombstone_file);
      @tombstone_named = lstat($tombstone_path);
      exit 1 unless @claim_opened && @claim_named
        && ($claim_opened[0] . q{:} . $claim_opened[1]) eq $expected_identity
        && $claim_opened[0] == $claim_named[0]
        && $claim_opened[1] == $claim_named[1]
        && @tombstone_opened && @tombstone_named
        && $tombstone_opened[0] == $tombstone_named[0]
        && $tombstone_opened[1] == $tombstone_named[1]
        && $tombstone_opened[7] == length($record);
      exchange_paths($tombstone_path, $claim_path) or exit 1;
      my @published = lstat($claim_path);
      my @displaced = lstat($tombstone_path);
      unless (@published && @displaced
          && $published[0] == $tombstone_opened[0]
          && $published[1] == $tombstone_opened[1]
          && $displaced[0] == $claim_opened[0]
          && $displaced[1] == $claim_opened[1]) {
        exchange_paths($tombstone_path, $claim_path);
        exit 1;
      }
      # Keep the displaced claim at the one bounded sidecar name. Stream
      # children retain its flock as their generation lease, and a later slot
      # generation safely rewrites this same regular inode after that lease is
      # released. Avoiding unlink also removes a pathname race after exchange.
      close($tombstone_file) or exit 1;
    }

    while (@stream_args) {
      exit($stopping) if $stopping;
      my ($event_log, $watch_id) = splice(@stream_args, 0, 2);
      pipe(my $reader, my $writer) or exit 1;
      pipe(my $ready_reader, my $ready_writer) or exit 1;
      my $pid = fork();
      exit 1 unless defined($pid);
      if ($pid == 0) {
        $is_parent = 0;
        $SIG{TERM} = q{DEFAULT};
        $SIG{INT} = q{DEFAULT};
        close($reader);
        close($ready_reader);
        close($delivery_ack);
        open(STDOUT, q{>&}, $writer) or exit 127;
        close($writer);
        POSIX::dup2(fileno($ready_writer), 4) >= 0 or exit 127;
        close($ready_writer);
        POSIX::dup2(fileno($claim), 8) >= 0 or exit 127;
        sigprocmask(SIG_SETMASK, $previous_signals) or exit 127;
        exec(q{bash}, $stream_script, $event_log, q{1}, q{--watch-id},
          $watch_id, q{--ready-fd}, q{4});
        exit 127;
      }
      close($writer);
      close($ready_writer);
      my $fd = fileno($reader);
      $buffer_for{$fd} = q{};
      $pid_for{$fd} = $pid;
      $selector->add($reader);
      sigprocmask(SIG_SETMASK, $previous_signals) or exit 1;
      $signals_are_blocked = 0;
      exit($stopping) if $stopping;
      my $is_ready = await_ready($ready_reader);
      close($ready_reader);
      exit($stopping || 1) unless $is_ready;
      if (@stream_args) {
        sigprocmask(SIG_BLOCK, $launch_signals) or exit 1;
        $signals_are_blocked = 1;
      }
    }

    sigprocmask(SIG_SETMASK, $previous_signals) or exit 1;
    $signals_are_blocked = 0;

    while ($selector->count) {
      for my $reader ($selector->can_read) {
        my $fd = fileno($reader);
        my $chunk = q{};
        my $count = sysread($reader, $chunk, 8192);
        if (!defined($count)) {
          next if $!{EINTR};
          $status = 1 if $status == 0;
          $count = 0;
        }
        if ($count > 0) {
          $buffer_for{$fd} .= $chunk;
          while ((my $newline = index($buffer_for{$fd}, qq{\n})) >= 0) {
            my $record = substr($buffer_for{$fd}, 0, $newline + 1, q{});
            retain_record($record);
          }
          next;
        }

        $status = 1 if length($buffer_for{$fd}) && $status == 0;
        delete($buffer_for{$fd});
        $selector->remove($reader);
        close($reader);
        my $pid = delete($pid_for{$fd});
        waitpid($pid, 0);
        remember_status($?);
      }
    }

    exit($stopping || $status) if $stopping || $status;
    write_all($drained_output);
    write_all(q{delivery-ready:} . $delivery_nonce . qq{\n});
    close(STDOUT) or exit 1;
    exit($stopping) if $stopping;
    # The relay ACK means every bounded record reached the outer shell stdout
    # write. stdout itself has no consumer acknowledgement, so SIGKILL after an
    # actual write and before this ACK remains necessarily at-least-once.
    await_delivery_ack();
    sigprocmask(SIG_BLOCK, $launch_signals) or exit 1;
    $signals_are_blocked = 1;
    exit($stopping) if $stopping;
    publish_tombstone();
    exit 0;
  ' -- "$manifest" "$manifest_identity" "$manifest_hash" \
    "$script_dir/pr-watch-stream.sh" "$((MAX_REFS * CHILD_MAX_BYTES))" \
    "$delivery_nonce" "${stream_args[@]}" \
    7< "$delivery_fifo" 9>&- > "$event_fifo" &
children+=("$!")
finish_attach_child_launch

omitted_refs="$(printf '%s' "$body" | jq -r '.omitted_refs')"
aggregate_body_event_limit=$((attach_max_events - 1))
aggregate_body_byte_limit=$((attach_max_bytes - ATTACH_SUMMARY_RESERVE_BYTES))
aggregate_emitted_events=0
aggregate_emitted_bytes=0
aggregate_omitted_events=0
aggregate_omitted_bytes=0
aggregate_relay_status=0
delivery_ready_seen=0

emit_aggregate_summary() {  # child-status
  local child_status="$1" aggregate_summary aggregate_summary_bytes
  (( aggregate_omitted_events > 0 || omitted_refs > 0 )) || return 0
  aggregate_summary="$(jq -nc \
    --argjson omitted_events "$aggregate_omitted_events" \
    --argjson omitted_bytes "$aggregate_omitted_bytes" \
    --argjson omitted_refs "$omitted_refs" \
    --argjson max_events "$attach_max_events" \
    --argjson max_bytes "$attach_max_bytes" \
    --argjson status "$child_status" '
      {kind:"stream_omitted",scope:"attachment",terminal_output:true,
       omitted_events:$omitted_events,omitted_bytes:$omitted_bytes,
       omitted_refs:$omitted_refs,limits:{events:$max_events,bytes:$max_bytes},
       terminal:{kind:"children_complete",status:$status}}')" || return 1
  aggregate_summary_bytes="$(LC_ALL=C printf '%s\n' \
    "$aggregate_summary" | wc -c | tr -d ' ')"
  if (( aggregate_summary_bytes > ATTACH_SUMMARY_RESERVE_BYTES )); then
    printf 'pr-watch-attach: aggregate summary exceeds reserved bytes\n' >&2
    return 1
  fi
  printf '%s\n' "$aggregate_summary"
}

# Opening the read side after the serializer is launched replaces the temporary
# read/write guard. The parent keeps draining after its output budget closes, so
# children can still observe their exact watch_end and exit without a pipe
# backpressure leak.
exec 3< "$event_fifo"
event_reader_open=1
exec 9>&-
event_fifo_guard_open=0
while IFS= read -r event_line <&3; do
  if [[ "$event_line" == "delivery-ready:$delivery_nonce" ]]; then
    if (( delivery_ready_seen )); then aggregate_relay_status=1; fi
    delivery_ready_seen=1
    continue
  fi
  if (( delivery_ready_seen )); then
    aggregate_relay_status=1
    continue
  fi
  event_bytes="$(LC_ALL=C printf '%s\n' "$event_line" | wc -c | tr -d ' ')"
  if (( aggregate_emitted_events + 1 > aggregate_body_event_limit \
        || aggregate_emitted_bytes + event_bytes > aggregate_body_byte_limit )); then
    aggregate_omitted_events=$((aggregate_omitted_events + 1))
    aggregate_omitted_bytes=$((aggregate_omitted_bytes + event_bytes))
    continue
  fi
  printf '%s\n' "$event_line" || aggregate_relay_status=1
  aggregate_emitted_events=$((aggregate_emitted_events + 1))
  aggregate_emitted_bytes=$((aggregate_emitted_bytes + event_bytes))
done
exec 3<&-
event_reader_open=0

if (( delivery_ready_seen && aggregate_relay_status == 0 )); then
  emit_aggregate_summary 0 || aggregate_relay_status=1
fi
if (( delivery_ready_seen && aggregate_relay_status == 0 )); then
  printf 'delivered:%s\n' "$delivery_nonce" >&7 \
    || aggregate_relay_status=1
fi
exec 7>&-
delivery_fifo_guard_open=0

status=0
for pid in "${children[@]}"; do
  wait "$pid" || child_status=$?
  if [[ "${child_status:-0}" -ne 0 && "$status" -eq 0 ]]; then status="$child_status"; fi
  child_status=0
done
children=()

if (( ! delivery_ready_seen )); then
  emit_aggregate_summary "$status" || status=1
fi
exit "$status"
