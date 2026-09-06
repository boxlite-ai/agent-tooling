#!/usr/bin/env bash
# PostToolUse hook: after a successful remote write, tell the agent that is running
# to attach a consumer to the pr-watch event stream.
#
# This is the in-session *consumer* of the watch. The producer is universal —
# .githooks/pre-push starts .agents/watch/pr-watch.sh for every agent and every
# human. This hook bridges that stream into whichever session ran the remote
# write. Humans keep reading the log directly.
#
# Registered from hooks/hooks.json (PostToolUse, matcher "Bash") — Claude Code
# resolves it through the generic plugin.json, Codex through
# .codex-plugin/plugin.json: the vendor manifests register, .agents/ implements.
#
# The context names the attach route this host has — Monitor for Claude Code, a
# background shell for Codex — and names all of them when hook_host_kind answers
# `unknown`. That accessor is the only sanctioned way to ask; .agents/lib/hook-host.sh
# carries which signals are trustworthy and which look right but are not.
#
# Design notes
# ------------
# * Advisory, not `decision: "block"`. The push has already happened, so a block
#   cannot undo it — it can only nag. Worse, the auto-fix loop this arms itself
#   ends in a push, so a hard block here would deadlock that loop.
#
# * Matcher scope: PreToolUse/PostToolUse matchers are tool-name-only, so this
#   registers on the broad `Bash` matcher and does its own filtering, exiting 0
#   immediately on unrelated commands. Same shape as
#   .agents/hooks/preflight-commit-push.sh:55 and preflight-pr-review.sh:52 —
#   segment-anchored so `echo "git push"` does not match, newline-normalized so
#   a verb on line 2 does.
#
# * `git push` is matched, but so are the `gh pr` writes. The pre-push arm
#   already covers PR creation transitively (a push always precedes it), so the
#   gh cases exist to re-attach a Monitor in a session that pushed earlier, or
#   where the push happened outside this session.
#
# Tests: bash .agents/hooks/post-remote-write-watch.test.sh
set -euo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

normalized="${command//$'\n'/;}"
work="${normalized#"${normalized%%[![:space:]]*}"}"
remote_write_kind=""
if [[ "$work" =~ (^|[[:space:]]*(\&\&|\|\||\;|\||\&|\$\(|\(|\`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*git[[:space:]]+push([[:space:]]|$) ]]; then
  remote_write_kind="git_push"
elif [[ "$work" =~ (^|[[:space:]]*(\&\&|\|\||\;|\||\&|\$\(|\(|\`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+(create|edit|ready|comment|review)([[:space:]]|$) ]]; then
  remote_write_kind="gh_pr"
else
  exit 0
fi

[[ "${BOXLITE_PR_WATCH:-1}" == "0" ]] && exit 0

# tool_response is a string for some tools and an object for Bash; accept both
# rather than assuming a shape.
response="$(printf '%s' "$payload" \
  | jq -r 'if (.tool_response | type) == "string"
           then .tool_response
           else ((.tool_response.stdout // "") + "\n" + (.tool_response.stderr // ""))
           end' 2>/dev/null || echo '')"

# A failed push leaves nothing new to watch. PostToolUse never sees the exit
# code, so the decision has to come from git's own output.
#
# Match the whole `error:`/`fatal:` class, not a list of specific messages. A
# local pre-push hook that exits non-zero — this repo's own audit gate — prints
# ONLY `error: failed to push some refs`: no `fatal:`, no `[rejected]`. An
# earlier version enumerated messages, missed that one, and announced a blocked
# push as a successful remote write.
#
# Fails closed: over-matching costs an un-armed watch, under-matching reports a
# push that never happened.
failure_re='(^|[[:space:]])(fatal|error):|\[(remote )?rejected\]|Everything up-to-date|Permission denied'
if [[ "$response" =~ $failure_re ]]; then
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# The stream script and the escalation policy live in the TOOLING tree (this
# script's own plugin), never at the consumer's repo root — an installed
# consumer carries only .agent-tooling/ and the pinned cache under .git/. An
# earlier version addressed both as ${repo_root}/.agents/… , which exists in
# neither layout; the tests missed it by asserting bare filenames.
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_helpers="$tooling_root/.agents/lib/pr-watch-state.sh"
if [[ ! -r "$state_helpers" ]]; then
  printf 'post-remote-write-watch: state helper not found: %s\n' "$state_helpers" >&2
  exit 1
fi
# shellcheck source=../lib/pr-watch-state.sh
source "$state_helpers"
safe_state_helpers="$tooling_root/.agents/lib/verdict-audit-state.sh"
if [[ ! -r "$safe_state_helpers" ]]; then
  printf 'post-remote-write-watch: safe state helper not found: %s\n' "$safe_state_helpers" >&2
  exit 1
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$safe_state_helpers"
host_helpers="$tooling_root/.agents/lib/hook-host.sh"
if [[ ! -r "$host_helpers" ]]; then
  printf 'post-remote-write-watch: host helper not found: %s\n' "$host_helpers" >&2
  exit 1
fi
# shellcheck source=../lib/hook-host.sh
source "$host_helpers"
command -v shasum >/dev/null 2>&1 || {
  printf 'post-remote-write-watch: shasum not found\n' >&2
  exit 127
}
state_dir="$(git -C "$repo_root" rev-parse --git-path pr-watch 2>/dev/null || echo '')"
[[ -z "$state_dir" ]] && exit 0
[[ "$state_dir" != /* ]] && state_dir="$repo_root/$state_dir"

attachment_body=""
attachment_claim=""
attachment_claim_identity=""
attachment_claim_hash=""
attachment_prompt_epoch=""
attachment_prompt_epoch_path=""
attachment_manifest=""
attachment_manifest_identity=""
attachment_marker_identity=""
attachment_owner_pid=""
attachment_owner_token=""
attachment_recovery_marker=""
attachment_recovery_source_marker=""
attachment_lease_pid=""
attachment_lease_nonce=""
attachment_lease_identity=""
attachment_lease_fd_open=false
attachment_published=false
active_lookup_pid=""
active_lookup_fd_open=false

# The claim JSON is the only consumable capability after selection. The stable
# manifest becomes a small non-authoritative recovery record via atomic replace;
# it is never truncated in place. A separate kernel flock is the live lease, so
# recovery never trusts a recycled PID or a wall-clock-resolution start token.
transition_attachment_claim_state() {  # check|acquire|retry|published|discard
  local target="$1" target_record new_identity
  [[ -n "$attachment_manifest" && -n "$attachment_manifest_identity" \
     && -n "$attachment_marker_identity" \
     && -n "$attachment_claim" && -n "$attachment_claim_identity" \
     && "$attachment_claim_hash" =~ ^[0-9a-f]{64}$ \
     && "$attachment_lease_pid" =~ ^[1-9][0-9]*$ \
     && "$attachment_lease_nonce" =~ ^[0-9a-f]{32}$ \
     && "$attachment_lease_identity" =~ ^[0-9]+:[0-9]+$ \
     && -n "$attachment_prompt_epoch" \
     && -n "$attachment_prompt_epoch_path" \
     && "$target" =~ ^(check|acquire|retry|published|discard)$ ]] || return 1
  if [[ "$target" == acquire ]]; then
    [[ -n "$attachment_recovery_marker" \
       && -n "$attachment_recovery_source_marker" ]] || return 1
    target_record="$attachment_recovery_marker"
  elif [[ "$target" == check ]]; then
    [[ -n "$attachment_recovery_source_marker" ]] || return 1
    target_record="$attachment_recovery_source_marker"
  elif [[ "$target" == retry || "$target" == published ]]; then
    target_record="retry:${attachment_manifest_identity}:${attachment_claim_hash}"
  else
    target_record="published:${attachment_manifest_identity}:${attachment_claim_hash}"
  fi
  new_identity="$(perl -MFcntl=:DEFAULT,:flock -MDigest::SHA -MIO::Handle -e '
    my ($manifest, $generation_identity, $marker_identity, $claim,
      $claim_identity, $hash, $target, $expected, $replacement,
      $lease_path, $lease_identity, $lease_nonce, $epoch_path,
      $epoch_record) = @ARGV;
    my $max = 65536;
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless $generation_identity =~ /\A[0-9]+:[0-9]+\z/
      && $marker_identity =~ /\A[0-9]+:[0-9]+\z/
      && $claim_identity =~ /\A[0-9]+:[0-9]+\z/
      && $hash =~ /\A[0-9a-f]{64}\z/
      && $target =~ /\A(?:check|acquire|retry|published|discard)\z/
      && $lease_identity =~ /\A[0-9]+:[0-9]+\z/
      && $lease_nonce =~ /\A[0-9a-f]{32}\z/
      && length($epoch_record) > 0 && length($epoch_record) <= 256
      && length($expected) <= $max && length($replacement) <= 512
      && $epoch_record !~ /[\0\r\n]/
      && $expected !~ /[\0\r\n]/ && $replacement !~ /[\0\r\n]/;
    my $open_exact = sub {
      my ($path, $identity, $exclusive) = @_;
      exit 1 if lstat($path) && -l _;
      my $flags = ($exclusive ? O_RDWR : O_RDONLY) | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $fh, $path, $flags) or exit 1;
      flock($fh, ($exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) or exit 1;
      my @opened = stat($fh);
      my @named = lstat($path);
      exit 1 unless @opened && @named && -f $fh && $opened[3] >= 1
        && ($opened[0] . ":" . $opened[1]) eq $identity
        && $opened[0] == $named[0] && $opened[1] == $named[1]
        && $opened[7] <= $max;
      return $fh;
    };
    my $read_exact = sub {
      my ($fh) = @_;
      my $body = "";
      sysseek($fh, 0, 0) or exit 1;
      while (length($body) <= $max) {
        my $chunk = "";
        my $count = sysread($fh, $chunk, $max + 1 - length($body));
        next if !defined($count) && $!{EINTR};
        exit 1 unless defined($count);
        last if $count == 0;
        $body .= $chunk;
      }
      exit 1 if length($body) > $max || $body =~ /[\0\r]/;
      return $body;
    };
    exit 1 if lstat($lease_path) && -l _;
    my $lease_flags = O_RDWR | O_NONBLOCK;
    $lease_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $lease_fh, $lease_path, $lease_flags) or exit 1;
    my @lease_opened = stat($lease_fh);
    my @lease_named = lstat($lease_path);
    exit 1 unless @lease_opened && @lease_named && -f $lease_fh
      && $lease_opened[3] == 1 && $lease_opened[7] <= 128
      && ($lease_opened[0] . ":" . $lease_opened[1]) eq $lease_identity
      && $lease_opened[0] == $lease_named[0]
      && $lease_opened[1] == $lease_named[1];
    my $lease_is_current = sub {
      @lease_named = lstat($lease_path);
      return 0 unless @lease_named
        && $lease_opened[0] == $lease_named[0]
        && $lease_opened[1] == $lease_named[1];
      my $lease_body = $read_exact->($lease_fh);
      return 0 unless $lease_body eq "lease:" . $lease_nonce . "\n";
      if (flock($lease_fh, LOCK_EX | LOCK_NB)) {
        flock($lease_fh, LOCK_UN);
        return 0;
      }
      return $!{EWOULDBLOCK} || $!{EAGAIN};
    };
    my $epoch_is_current = sub {
      return 0 if lstat($epoch_path) && -l _;
      my $flags = O_RDONLY | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $fh, $epoch_path, $flags) or return 0;
      flock($fh, LOCK_SH | LOCK_NB) or return 0;
      my @opened = stat($fh);
      my @named = lstat($epoch_path);
      return 0 unless @opened && @named && -f $fh
        && $opened[3] == 1 && $opened[7] <= 256
        && $opened[0] == $named[0] && $opened[1] == $named[1];
      my $record = $read_exact->($fh);
      @named = lstat($epoch_path);
      return 0 unless @named && $opened[0] == $named[0]
        && $opened[1] == $named[1]
        && $record eq $epoch_record . "\n";
      close($fh) or return 0;
      return 1;
    };
    my $manifest_fh = $open_exact->($manifest, $marker_identity, 1);
    my $manifest_body = $read_exact->($manifest_fh);
    $manifest_body =~ s/\n\z// or exit 1;
    exit 1 unless $manifest_body eq $expected;

    my ($claim_fh, $claim_record);
    if ($marker_identity eq $claim_identity) {
      $claim_record = $manifest_body;
    } else {
      $claim_fh = $open_exact->($claim, $claim_identity, 1);
      $claim_record = $read_exact->($claim_fh);
      $claim_record =~ s/\n\z// or exit 1;
    }
    exit 1 unless $claim_record ne ""
      && index($claim_record, "\n") < 0
      && Digest::SHA::sha256_hex($claim_record) eq $hash;
    my @manifest_named = lstat($manifest);
    my @claim_named = lstat($claim);
    exit 1 unless @manifest_named && @claim_named
      && ($manifest_named[0] . ":" . $manifest_named[1]) eq $marker_identity
      && ($claim_named[0] . ":" . $claim_named[1]) eq $claim_identity;
    exit 1 unless $lease_is_current->() && $epoch_is_current->();

    if ($target eq "check") {
      close($lease_fh) or exit 1;
      close($claim_fh) or exit 1 if defined($claim_fh);
      close($manifest_fh) or exit 1;
      alarm 0;
      print $manifest_named[0], ":", $manifest_named[1];
      exit 0;
    }

    if ($target eq "discard") {
      exit 1 unless defined($claim_fh);
      truncate($claim_fh, 0) or exit 1;
      sysseek($claim_fh, 0, 0) or exit 1;
      syswrite($claim_fh, "retired\n") == 8 or exit 1;
      $claim_fh->sync or exit 1;
    }

    my $temporary = $manifest . ".state.tmp";
    exit 1 if lstat($temporary) && -l _;
    my $temporary_flags = O_RDWR | O_CREAT | O_NONBLOCK;
    $temporary_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $temporary_fh, $temporary, $temporary_flags, 0600) or exit 1;
    flock($temporary_fh, LOCK_EX | LOCK_NB) or exit 1;
    my @temporary_opened = stat($temporary_fh);
    my @temporary_named = lstat($temporary);
    exit 1 unless @temporary_opened && @temporary_named && -f $temporary_fh
      && $temporary_opened[3] == 1
      && $temporary_opened[0] == $temporary_named[0]
      && $temporary_opened[1] == $temporary_named[1];
    truncate($temporary_fh, 0) or exit 1;
    sysseek($temporary_fh, 0, 0) or exit 1;
    my $record = $replacement . "\n";
    my $offset = 0;
    while ($offset < length($record)) {
      my $written = syswrite(
        $temporary_fh, $record, length($record) - $offset, $offset);
      next if !defined($written) && $!{EINTR};
      exit 1 unless defined($written) && $written > 0;
      $offset += $written;
    }
    $temporary_fh->sync or exit 1;

    @manifest_named = lstat($manifest);
    @claim_named = lstat($claim);
    @temporary_named = lstat($temporary);
    exit 1 unless @manifest_named && @claim_named && @temporary_named
      && ($manifest_named[0] . ":" . $manifest_named[1]) eq $marker_identity
      && ($claim_named[0] . ":" . $claim_named[1]) eq $claim_identity
      && $lease_is_current->() && $epoch_is_current->();
    rename($temporary, $manifest) or exit 1;
    my @published = lstat($manifest);
    exit 1 unless @published
      && $published[0] == $temporary_opened[0]
      && $published[1] == $temporary_opened[1];
    close($temporary_fh) or exit 1;
    close($lease_fh) or exit 1;
    close($claim_fh) or exit 1 if defined($claim_fh);
    close($manifest_fh) or exit 1;
    alarm 0;
    print $published[0], ":", $published[1];
  ' "$attachment_manifest" "$attachment_manifest_identity" \
    "$attachment_marker_identity" "$attachment_claim" \
    "$attachment_claim_identity" "$attachment_claim_hash" "$target" \
    "$attachment_recovery_source_marker" "$target_record" \
    "${attachment_manifest}.lease" "$attachment_lease_identity" \
    "$attachment_lease_nonce" "$attachment_prompt_epoch_path" \
    "$attachment_prompt_epoch")" || return 1
  [[ "$new_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  attachment_marker_identity="$new_identity"
  attachment_recovery_source_marker="$target_record"
}

stop_attachment_recovery_lease() {
  if [[ "$attachment_lease_fd_open" == true ]]; then
    exec 6<&-
    attachment_lease_fd_open=false
  fi
  if [[ "$attachment_lease_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$attachment_lease_pid" 2>/dev/null || true
    wait "$attachment_lease_pid" 2>/dev/null || true
  fi
  attachment_lease_pid=""
  attachment_lease_nonce=""
  attachment_lease_identity=""
}

start_attachment_recovery_lease() {
  local lease_path="${attachment_manifest}.lease" lease_signal=""
  local ready_record ready_pid ready_nonce ready_device ready_inode
  [[ -n "$attachment_manifest" && -n "$attachment_marker_identity" ]] || return 1
  trap 'lease_signal=TERM' TERM
  trap 'lease_signal=INT' INT
  exec 6< <(exec perl -MFcntl=:DEFAULT,:flock -MIO::Handle -e '
    use strict;
    use warnings;
    my ($path, $parent_pid) = @ARGV;
    exit 1 unless $parent_pid =~ /\A[1-9][0-9]*\z/;
    $SIG{TERM} = sub { exit 143 };
    $SIG{INT} = sub { exit 130 };
    $SIG{PIPE} = sub { exit 0 };
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    sysopen(my $random, "/dev/urandom", O_RDONLY) or exit 1;
    my $bytes = "";
    while (length($bytes) < 16) {
      my $count = sysread($random, $bytes, 16 - length($bytes), length($bytes));
      next if !defined($count) && $!{EINTR};
      exit 1 unless defined($count) && $count > 0;
    }
    close($random) or exit 1;
    my $nonce = unpack("H*", $bytes);
    truncate($fh, 0) or exit 1;
    sysseek($fh, 0, 0) or exit 1;
    my $record = "lease:" . $nonce . "\n";
    my $offset = 0;
    while ($offset < length($record)) {
      my $written = syswrite($fh, $record, length($record) - $offset, $offset);
      next if !defined($written) && $!{EINTR};
      exit 1 unless defined($written) && $written > 0;
      $offset += $written;
    }
    $fh->sync or exit 1;
    @named = lstat($path);
    exit 1 unless @named && $opened[0] == $named[0]
      && $opened[1] == $named[1];
    STDOUT->autoflush(1);
    print "lease:", $$, ":", $nonce, ":", $opened[0], ":", $opened[1],
      "\n" or exit 1;
    # The report pipe is the non-recyclable owner identity: SIGKILL of the hook
    # closes its only reader, so the next heartbeat gets EPIPE and drops flock.
    while (kill(0, $parent_pid)) {
      select(undef, undef, undef, 0.05);
      syswrite(STDOUT, ".", 1) or exit 0;
    }
    close($fh) or exit 1;
  ' "$lease_path" "$$")
  attachment_lease_pid=$!
  attachment_lease_fd_open=true
  trap 'exit 143' TERM
  trap 'exit 130' INT
  case "$lease_signal" in
    TERM) exit 143 ;;
    INT) exit 130 ;;
  esac
  if ! IFS= read -r -t 2 ready_record <&6; then
    stop_attachment_recovery_lease
    return 1
  fi
  if [[ "$ready_record" =~ ^lease:([1-9][0-9]*):([0-9a-f]{32}):([0-9]+):([0-9]+)$ ]]; then
    ready_pid="${BASH_REMATCH[1]}"
    ready_nonce="${BASH_REMATCH[2]}"
    ready_device="${BASH_REMATCH[3]}"
    ready_inode="${BASH_REMATCH[4]}"
  else
    stop_attachment_recovery_lease
    return 1
  fi
  [[ "$ready_pid" == "$attachment_lease_pid" ]] || {
    stop_attachment_recovery_lease
    return 1
  }
  attachment_lease_pid="$ready_pid"
  attachment_lease_nonce="$ready_nonce"
  attachment_lease_identity="${ready_device}:${ready_inode}"
}

clear_attachment_claim_state() {
  attachment_body=""
  attachment_claim=""
  attachment_claim_identity=""
  attachment_claim_hash=""
  attachment_prompt_epoch=""
  attachment_prompt_epoch_path=""
  attachment_manifest=""
  attachment_manifest_identity=""
  attachment_marker_identity=""
  attachment_owner_pid=""
  attachment_owner_token=""
  attachment_recovery_marker=""
  attachment_recovery_source_marker=""
  attachment_lease_identity=""
}

discard_attachment_claim() {
  if [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]]; then
    transition_attachment_claim_state discard 2>/dev/null || true
  fi
  stop_attachment_recovery_lease
  clear_attachment_claim_state
}

terminate_active_lookup() {
  local deadline
  if [[ "$active_lookup_fd_open" == true ]]; then
    exec 7<&-
    active_lookup_fd_open=false
  fi
  if [[ "$active_lookup_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM -- "-$active_lookup_pid" 2>/dev/null || true
    deadline=$(( SECONDS + 1 ))
    while (( SECONDS < deadline )) \
       && kill -0 -- "-$active_lookup_pid" 2>/dev/null; do
      sleep 0.05
    done
    kill -KILL -- "-$active_lookup_pid" 2>/dev/null || true
    wait "$active_lookup_pid" 2>/dev/null || true
  fi
  active_lookup_pid=""
}

post_write_cleanup() {
  local status=$?
  set +e
  trap - EXIT TERM INT
  trap '' TERM INT
  terminate_active_lookup
  if [[ -n "$attachment_claim" ]]; then
    # Hook stdout has no durable host acknowledgement. Keep retry authority
    # until the rendered consumer consumes the exact claim capability.
    if ! transition_attachment_claim_state retry 2>/dev/null \
       && (( status == 0 )); then
      status=1
    fi
    stop_attachment_recovery_lease
    clear_attachment_claim_state
  fi
  exit "$status"
}

trap post_write_cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

bounded_pr_number=""
lookup_pr_number_bounded() {  # repository-slug branch
  local slug="$1" branch="$2" lookup_signal="" lookup_record=""
  bounded_pr_number=""
  trap 'lookup_signal=TERM' TERM
  trap 'lookup_signal=INT' INT
  # The process-substitution pipe is the only parent-facing descriptor. The
  # supervisor replaces stdout and closes every internal descriptor before gh,
  # so the child cannot forge completion. No filesystem temp path exists.
  exec 7< <(exec perl -MFcntl=:DEFAULT -MIO::Select -MPOSIX=:sys_wait_h \
      -MTime::HiRes=time -e '
    use strict;
    use warnings;
    my ($slug, $branch) = @ARGV;
    my $max = 128;
    my $deadline = time() + 5;
    my $cancel = 0;
    $SIG{TERM} = sub { $cancel = 1 };
    $SIG{INT} = sub { $cancel = 1 };
    POSIX::setpgid(0, 0);
    pipe(my $reader, my $writer) or exit 1;
    my $child = fork();
    exit 1 unless defined($child);
    if ($child == 0) {
      POSIX::setpgid(0, 0);
      close($reader);
      POSIX::dup2(fileno($writer), 1) >= 0 or exit 125;
      sysopen(my $null, "/dev/null", O_WRONLY) or exit 125;
      POSIX::dup2(fileno($null), 2) >= 0 or exit 125;
      for my $fd (3 .. 255) { POSIX::close($fd) }
      exec {"/bin/bash"} "bash", "-c", q{gh "$@"}, "gh",
        "pr", "list", "--repo", $slug, "--head", $branch,
        "--state", "open", "--json", "number", "--jq",
        ".[0].number // empty";
      exit 127;
    }
    POSIX::setpgid($child, $child);
    close($writer);
    my $flags = fcntl($reader, F_GETFL, 0);
    exit 1 unless defined($flags) && fcntl($reader, F_SETFL, $flags | O_NONBLOCK);
    my $selector = IO::Select->new($reader);
    my $output = "";
    my $status;
    my $reaped = 0;
    my $over_limit = 0;
    while (!$cancel && time() < $deadline) {
      my $waited = waitpid($child, WNOHANG);
      if ($waited == $child) {
        $status = $?;
        $reaped = 1;
      }
      my @ready = $selector->can_read(0.02);
      if (@ready) {
        my $chunk = "";
        my $wanted = $max + 1 - length($output);
        $wanted = 1 if $wanted < 1;
        my $count = sysread($reader, $chunk, $wanted);
        if (defined($count)) {
          last if $count == 0 && $reaped;
          $output .= $chunk if $count > 0;
          if (length($output) > $max) {
            $over_limit = 1;
            last;
          }
        } elsif (!$!{EAGAIN} && !$!{EWOULDBLOCK} && !$!{EINTR}) {
          last;
        }
      }
      last if $reaped && !@ready;
    }
    kill "TERM", -$child;
    my $kill_deadline = time() + 0.25;
    while (!$reaped && time() < $kill_deadline) {
      my $waited = waitpid($child, WNOHANG);
      if ($waited == $child) {
        $status = $?;
        $reaped = 1;
        last;
      }
      select(undef, undef, undef, 0.01);
    }
    if (!$reaped) {
      kill "KILL", -$child;
      waitpid($child, 0);
      $status = $?;
      $reaped = 1;
    }
    close($reader);
    my $exit_ok = defined($status) && POSIX::WIFEXITED($status)
      && POSIX::WEXITSTATUS($status) == 0;
    if (!$cancel && !$over_limit && time() <= $deadline && $exit_ok) {
      $output =~ s/\n\z//;
      if ($output eq "") {
        print "none:\n";
        exit 0;
      }
      if ($output =~ /\A[1-9][0-9]*\z/ && length($output) <= $max) {
        print "ok:", $output, "\n";
        exit 0;
      }
    }
    print "error:\n";
    exit 1;
  ' "$slug" "$branch")
  active_lookup_pid=$!
  active_lookup_fd_open=true
  trap 'exit 143' TERM
  trap 'exit 130' INT
  case "$lookup_signal" in
    TERM) exit 143 ;;
    INT) exit 130 ;;
  esac
  if ! IFS= read -r -t 7 lookup_record <&7; then
    terminate_active_lookup
    return 1
  fi
  exec 7<&-
  active_lookup_fd_open=false
  wait "$active_lookup_pid" 2>/dev/null || true
  active_lookup_pid=""
  if [[ "$lookup_record" =~ ^ok:([1-9][0-9]*)$ ]]; then
    bounded_pr_number="${BASH_REMATCH[1]}"
    return 0
  fi
  [[ "$lookup_record" == none: ]]
}

attachment_epoch_is_current() {
  local current_prompt_epoch
  [[ -n "$attachment_body" && -n "$attachment_prompt_epoch" \
     && -n "$attachment_prompt_epoch_path" ]] || return 1
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$attachment_prompt_epoch_path" 2>/dev/null)" || return 1
  [[ "$current_prompt_epoch" == "$attachment_prompt_epoch" ]]
}

inspect_attachment_manifest() {
  local session_scope command_hash attachment_key manifest manifest_identity manifest_hash
  local snapshot mtime body now marker_identity marker_hash
  local slot candidate_claim candidate_identity candidate_snapshot
  local candidate_mtime candidate_body candidate_hash claim_matches=0
  local recovered_claim="" recovered_claim_identity=""
  local recovery_source_marker="" recovery_owner_pid recovery_owner_token
  local manifest_prompt_epoch prompt_epoch_path current_prompt_epoch
  local owner_pid owner_token entry branch_key expected_log branch
  session_scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo_root" 2>/dev/null)" || return 1
  command_hash="$(LC_ALL=C printf '%s' "$command" | shasum -a 256 | awk '{print $1}')" || return 1
  attachment_key="$(pr_watch_attachment_key "$session_scope" "$command_hash" 2>/dev/null)" || return 1
  manifest="$state_dir/${attachment_key}.json"
  manifest_identity="$(verdict_audit_path_identity "$manifest" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$manifest" 2>/dev/null)" || return 1
  verdict_audit_selected_identity_matches \
    "$manifest" "$manifest_identity" 2>/dev/null || return 1
  [[ "$snapshot" == *$'\n'* ]] || return 1
  mtime="${snapshot%%$'\n'*}"
  body="${snapshot#*$'\n'}"
  now="$(date +%s)"
  [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime <= now && now - mtime <= 300 )) || return 1
  if [[ "$body" =~ ^(consumed|retry):([0-9]+):([0-9]+):([0-9a-f]{64})$ ]]; then
    marker_identity="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    marker_hash="${BASH_REMATCH[4]}"
    recovery_source_marker="$body"
  elif [[ "$body" =~ ^recovering:([0-9]+):([0-9]+):([0-9a-f]{64}):([1-9][0-9]*):(lease-[0-9a-f]{32}):([0-9]+):([0-9]+)$ ]]; then
    marker_identity="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    marker_hash="${BASH_REMATCH[3]}"
    recovery_owner_pid="${BASH_REMATCH[4]}"
    recovery_owner_token="${BASH_REMATCH[5]}"
    [[ ${#recovery_owner_pid} -le 18 \
       && -n "$recovery_owner_token" \
       && ${#BASH_REMATCH[6]} -le 20 \
       && ${#BASH_REMATCH[7]} -le 20 ]] || return 1
    recovery_source_marker="$body"
  elif [[ "$body" =~ ^recovering:([0-9]+):([0-9]+):([0-9a-f]{64}):([1-9][0-9]*):((cksum-[0-9]+-[0-9]+)|(lease-[0-9a-f]{32}))$ ]]; then
    # Legacy recovery records did not bind the flock inode. They are only a
    # source generation: a new exact lease must be acquired before any output.
    marker_identity="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    marker_hash="${BASH_REMATCH[3]}"
    recovery_owner_pid="${BASH_REMATCH[4]}"
    recovery_owner_token="${BASH_REMATCH[5]}"
    [[ ${#recovery_owner_pid} -le 18 \
       && -n "$recovery_owner_token" ]] || return 1
    recovery_source_marker="$body"
  fi
  if [[ -n "$recovery_source_marker" ]]; then
    for slot in 0 1 2 3; do
      candidate_claim="${manifest}.claim.${slot}"
      candidate_identity="$(verdict_audit_path_identity \
        "$candidate_claim" 2>/dev/null)" || continue
      candidate_snapshot="$(verdict_audit_read_json_snapshot \
        "$candidate_claim" 2>/dev/null)" || continue
      verdict_audit_selected_identity_matches \
        "$candidate_claim" "$candidate_identity" 2>/dev/null || continue
      [[ "$candidate_snapshot" == *$'\n'* ]] || continue
      candidate_mtime="${candidate_snapshot%%$'\n'*}"
      candidate_body="${candidate_snapshot#*$'\n'}"
      [[ "$candidate_mtime" =~ ^[0-9]+$ \
         && ${#candidate_mtime} -le 18 ]] || continue
      (( candidate_mtime <= now && now - candidate_mtime <= 600 )) || continue
      candidate_hash="$(LC_ALL=C printf '%s' "$candidate_body" \
        | shasum -a 256 | awk '{print $1}')" || continue
      [[ "$candidate_hash" == "$marker_hash" ]] || continue
      claim_matches=$((claim_matches + 1))
      recovered_claim="$candidate_claim"
      recovered_claim_identity="$candidate_identity"
      body="$candidate_body"
    done
    (( claim_matches == 1 )) || return 1
    manifest_hash="$marker_hash"
  else
    manifest_hash="$(LC_ALL=C printf '%s' "$body" \
      | shasum -a 256 | awk '{print $1}')" || return 1
    [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  printf '%s' "$body" | jq -e --arg command_hash "$command_hash" \
    --arg session_scope "$session_scope" --argjson now "$now" '
      type == "object" and .schema == 1
      and (keys | sort) == ["command_hash","created_at","entries","omitted_refs",
                            "owner","prompt_epoch","schema","session_scope"]
      and .command_hash == $command_hash and .session_scope == $session_scope
      and (.prompt_epoch | type == "string"
           and test("^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$"))
      and (.created_at | type == "number" and floor == .
           and . <= $now and . >= ($now - 300))
      and (.owner | type == "object"
           and (keys | sort) == ["pid","start_token"])
      and (.owner.pid | type == "number" and . > 0 and floor == .)
      and (.owner.start_token | type == "string"
           and test("^cksum-[0-9]+-[0-9]+$"))
      and (.entries | type == "array" and length > 0 and length <= 4)
      and (.omitted_refs | type == "number" and . >= 0
           and . <= 1000000 and floor == .)
      and all(.entries[];
        (keys | sort) == ["branch","event_log","remote_ref","watch_id"]
        and (.remote_ref | type == "string" and startswith("refs/heads/"))
        and (.branch | type == "string" and length > 0)
        and .remote_ref == ("refs/heads/" + .branch)
        and (.watch_id | type == "string" and test("^watch-[0-9a-f]{24}$"))
        and (.event_log | type == "string" and startswith("/")))' \
    >/dev/null 2>&1 || return 1
  manifest_prompt_epoch="$(printf '%s' "$body" | jq -r '.prompt_epoch')"
  prompt_epoch_path="$(verdict_audit_state_path \
    "$repo_root/.agents/state/verdict-prompt-epoch" "$session_scope")"
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$prompt_epoch_path" 2>/dev/null)" || return 1
  [[ "$current_prompt_epoch" == "$manifest_prompt_epoch" ]] || return 1
  owner_pid="$(printf '%s' "$body" | jq -r '.owner.pid')"
  owner_token="$(printf '%s' "$body" | jq -r '.owner.start_token')"
  verdict_audit_process_has_ancestor "$owner_pid" "$owner_token" || return 1
  while IFS= read -r entry; do
    branch="$(printf '%s' "$entry" | jq -r '.branch')"
    git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1
    branch_key="$(pr_watch_branch_key "$branch" 2>/dev/null)" || return 1
    expected_log="$state_dir/${branch_key}.jsonl"
    [[ "$(printf '%s' "$entry" | jq -r '.event_log')" == "$expected_log" ]] || return 1
  done < <(printf '%s' "$body" | jq -c '.entries[]')

  attachment_body="$body"
  attachment_claim="$recovered_claim"
  attachment_claim_identity="$recovered_claim_identity"
  attachment_manifest="$manifest"
  attachment_manifest_identity="${marker_identity:-$manifest_identity}"
  attachment_marker_identity="$manifest_identity"
  attachment_claim_hash="$manifest_hash"
  attachment_prompt_epoch="$manifest_prompt_epoch"
  attachment_prompt_epoch_path="$prompt_epoch_path"
  attachment_owner_pid="$owner_pid"
  attachment_owner_token="$owner_token"
  if [[ -n "$recovery_source_marker" ]]; then
    start_attachment_recovery_lease || {
      clear_attachment_claim_state
      return 1
    }
    attachment_recovery_source_marker="$recovery_source_marker"
    attachment_recovery_marker="recovering:${attachment_manifest_identity}:${manifest_hash}:${attachment_lease_pid}:lease-${attachment_lease_nonce}:${attachment_lease_identity}"
    transition_attachment_claim_state acquire 2>/dev/null || {
      stop_attachment_recovery_lease
      clear_attachment_claim_state
      return 1
    }
  fi
}

claim_attachment_manifest() {
  local now slot candidate_claim candidate_identity claimed_snapshot claimed_body
  local claim_signal=""
  [[ -n "$attachment_body" && -n "$attachment_manifest" \
     && -n "$attachment_manifest_identity" \
     && "$attachment_claim_hash" =~ ^[0-9a-f]{64}$ \
     && "$attachment_owner_pid" =~ ^[1-9][0-9]*$ \
     && "$attachment_owner_token" =~ ^cksum-[0-9]+-[0-9]+$ ]] || return 1
  attachment_epoch_is_current || return 1
  verdict_audit_process_has_ancestor \
    "$attachment_owner_pid" "$attachment_owner_token" || return 1
  now="$(date +%s)"
  attachment_claim=""
  attachment_claim_identity=""
  for slot in 0 1 2 3; do
    candidate_claim="${attachment_manifest}.claim.${slot}"
    pr_watch_retire_attachment_claim "$candidate_claim" "$now" 600 \
      2>/dev/null || true
    # A signal is delivered between Bash simple commands. Defer its exit across
    # claim selection so cleanup always learns the exact destination identity.
    trap 'claim_signal=TERM' TERM
    trap 'claim_signal=INT' INT
    candidate_identity=""
    if candidate_identity="$(pr_watch_claim_regular_file \
        "$attachment_manifest" "$candidate_claim" \
        "$attachment_manifest_identity" "$attachment_claim_hash" \
        2>/dev/null)"; then
      attachment_claim="$candidate_claim"
      attachment_claim_identity="$candidate_identity"
    fi
    trap 'exit 143' TERM
    trap 'exit 130' INT
    case "$claim_signal" in
      TERM) exit 143 ;;
      INT) exit 130 ;;
    esac
    [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]] \
      || continue
    break
  done
  [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]] || return 1
  start_attachment_recovery_lease || {
    clear_attachment_claim_state
    return 1
  }
  attachment_recovery_source_marker="$attachment_body"
  attachment_recovery_marker="recovering:${attachment_manifest_identity}:${attachment_claim_hash}:${attachment_lease_pid}:lease-${attachment_lease_nonce}:${attachment_lease_identity}"
  transition_attachment_claim_state acquire 2>/dev/null || {
    # Another exact hook may have won the JSON-to-recovering CAS during the few
    # instructions after same-inode claim publication. It owns the claim.
    stop_attachment_recovery_lease
    clear_attachment_claim_state
    return 1
  }
  claimed_snapshot="$(verdict_audit_read_json_snapshot "$attachment_claim" 2>/dev/null)" || {
    discard_attachment_claim
    return 1
  }
  verdict_audit_selected_identity_matches \
    "$attachment_claim" "$attachment_claim_identity" 2>/dev/null || {
    discard_attachment_claim
    return 1
  }
  claimed_body="${claimed_snapshot#*$'\n'}"
  if [[ "$claimed_body" != "$attachment_body" ]] \
     || ! transition_attachment_claim_state check 2>/dev/null; then
    discard_attachment_claim
    return 1
  fi
}

if [[ "$remote_write_kind" == "git_push" ]] \
   && printf '%s' "$payload" | jq -e '(.session_id | type) == "string" and (.session_id | length) > 0' \
      >/dev/null 2>&1; then
  inspect_attachment_manifest || exit 0
fi

branch_count=1
omitted_ref_count=0
if [[ -n "$attachment_body" ]]; then
  branch="$(printf '%s' "$attachment_body" | jq -r '.entries[0].branch')"
  branch_count="$(printf '%s' "$attachment_body" | jq -r '.entries | length')"
  omitted_ref_count="$(printf '%s' "$attachment_body" | jq -r '.omitted_refs')"
else
  branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '')"
fi
[[ -z "$branch" ]] && exit 0

slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null \
        | sed -e 's#^git@[^:]*:##' -e 's#^[a-z+]*://[^/]*/##' -e 's#\.git$##')"
pr_number="$(printf '%s' "$response" \
  | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -1)"
if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
  lookup_pr_number_bounded "$slug" "$branch" || true
  pr_number="$bounded_pr_number"
fi

# All potentially slow work is complete. Consume the manifest only when this
# invocation can immediately render and publish the exact claim command.
if [[ -n "$attachment_body" && -z "$attachment_claim" ]]; then
  claim_attachment_manifest || exit 0
fi

stream_script="$tooling_root/.agents/watch/pr-watch-stream.sh"
attach_script="$tooling_root/.agents/watch/pr-watch-attach.sh"
policy_path="$tooling_root/.agents/watch/escalation-policy.md"
# Both paths can contain shell metacharacters; the branch-derived event path is
# attacker-controlled within Git's ref grammar. Emit one Bash-copyable command whose
# arguments stay data even for quotes, dollars, semicolons, and substitutions.
if [[ -n "$attachment_body" ]]; then
  printf -v stream_command 'bash %q %q %q %q' \
    "$attach_script" "$attachment_claim" "$attachment_claim_identity" \
    "$attachment_claim_hash"
else
  branch_key="$(pr_watch_branch_key "$branch")" || {
    printf 'post-remote-write-watch: cannot derive branch state identity\n' >&2
    exit 1
  }
  event_log="$state_dir/${branch_key}.jsonl"
  printf -v stream_command 'bash %q %q' "$stream_script" "$event_log"
fi
policy_path_json="$(jq -Rn --arg path "$policy_path" '$path')"

pr_line="No open PR for '${branch}' yet; the watcher polls until one appears."
if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
  pr_line="PR #${pr_number}: https://github.com/${slug}/pull/${pr_number}"
fi

branch_line="Remote write succeeded on '${branch}'."
if (( branch_count > 1 || omitted_ref_count > 0 )); then
  pushed_ref_count=$((branch_count + omitted_ref_count))
  branch_line="Remote write succeeded for ${pushed_ref_count} pushed branches; ${branch_count} exact watcher generations attached, ${omitted_ref_count} omitted."
fi
# Name the attach route this host actually has; fall back to all of them when the
# host is unknown (a runtime this hook has not been taught about). Narrowing also
# buys headroom against the 1400-byte ceiling enforced below.
case "$(hook_host_kind)" in
  claude)
    attach_line="Claude: Monitor({command: <stream command>, persistent: true})."
    compact_attach_line="Claude: use Monitor with this command." ;;
  codex)
    attach_line="Codex: run it in a background shell and read at natural pauses."
    compact_attach_line="Codex: run it in a background shell." ;;
  *)
    attach_line="Claude: Monitor({command: <stream command>, persistent: true}). Codex: run it in a
background shell and read at natural pauses. Without background support, cat its
log before each turn ends."
    compact_attach_line="Claude: use Monitor with this command. Codex: run it in a background shell. Without
background support, drain it before turns end." ;;
esac

context="${branch_line} ${pr_line}
Attach exactly ONE consumer using the route below; do not attach twice or
poll gh pr checks. Stream command:
  ${stream_command}

${attach_line} Replay is bounded and generation-scoped; it exits at watch_end.

fail/cancel: run gh run view <run-id> --log-failed. kind 'conflict': alert the
human to the confirmed conflict (confirmed merge conflict) and inspect both
revisions. comment/review/review_comment: summarize for the human. Before editing
or changing history, read the escalation policy at JSON path ${policy_path_json}.
Notify immediately for a failing required check, confirmed conflict, or every
comment/review/thread including bots; routine passing checks stay silent. If the
user declined this watch, do not attach."

context_max_bytes=1400
context_bytes="$(LC_ALL=C printf '%s' "$context" | wc -c | tr -d ' ')"
if (( context_bytes > context_max_bytes )); then
  # Paths are caller-controlled and can be unusually long. Keep the hook bounded
  # rather than letting repeated path prose turn one advisory event into a large
  # prompt. The one exact command is retained; it is the authoritative locator.
  context="${branch_line} No open PR may exist yet; the watcher polls.
Attach exactly ONE consumer.
Stream command:
  ${stream_command}
${compact_attach_line} Read the escalation policy at JSON path
${policy_path_json} before editing. Notify the human for fail/cancel, confirmed
conflict, and every new comment/review/thread including bots; routine passing checks
stay silent."
fi

# Re-check the rendered fallback: its two %q paths and policy JSON are dynamic too.
# At extreme path lengths, decline attachment. A raw follower cannot bind itself
# to the armed watch_id across journal retirement and producer-start boundaries.
context_bytes="$(LC_ALL=C printf '%s' "$context" | wc -c | tr -d ' ')"
if (( context_bytes > context_max_bytes )); then
  [[ -z "$attachment_claim" ]] || discard_attachment_claim
  context="Remote write succeeded and exact PR watchers were armed, but their safe attachment command exceeded the
1400-byte context limit. No safe fallback was attached: raw branch-log replay can
stop at a stale watch_end and miss the current generation. Inspect the bounded
pr-watch logs locally if this watch is required; ask the human before editing,
resolving conflicts, or changing history."
fi

# A later real prompt or replacement lease revokes this exact publisher. Recheck
# the marker, claim, epoch, nonce, and locked lease inode immediately before output.
if [[ -n "$attachment_body" ]] \
   && ! transition_attachment_claim_state check 2>/dev/null; then
  stop_attachment_recovery_lease
  clear_attachment_claim_state
  exit 0
fi

if jq -nc --arg c "$context" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $c
    }
  }'; then
  # shellcheck disable=SC2034 # Lifecycle fault-injection probes this boundary.
  attachment_published=true
else
  exit 1
fi
exit 0
