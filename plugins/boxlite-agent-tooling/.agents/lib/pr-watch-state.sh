#!/usr/bin/env bash
# Shared, side-effect-free state helpers for the PR watch producer and its
# post-write consumer. Requires verdict-audit-state.sh, perl, and jq; callers own
# dependency checks and error reporting.

pr_watch_positive_decimal_is_bounded() {  # value
  [[ "${1-}" =~ ^[1-9][0-9]*$ && ${#1} -le 18 ]]
}

# A fixed-size digest avoids both slash/dash aliases and filesystem component
# limits. The branch remains present in every JSON event for human inspection.
pr_watch_branch_key() {
  local branch="${1-}" digest
  [[ -n "$branch" ]] || return 1
  digest="$(LC_ALL=C printf '%s' "$branch" | verdict_audit_sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'branch-%s' "$digest"
}

# mktemp provides an atomic random component; hashing it with branch, time, and
# PID keeps the model-visible identifier short without making uniqueness depend
# on a timestamp or recycled PID alone.
pr_watch_new_id() {
  local state_dir="${1-}" branch_key="${2-}" marker seed digest
  [[ -d "$state_dir" && -n "$branch_key" ]] || return 1
  marker="$(mktemp -d "$state_dir/.watch-id.XXXXXX")" || return 1
  seed="${branch_key}|$$|$(date +%s)|${marker##*/}"
  rmdir "$marker" || return 1
  digest="$(LC_ALL=C printf '%s' "$seed" | verdict_audit_sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'watch-%s' "${digest:0:24}"
}

pr_watch_id_is_valid() {
  [[ "${1-}" =~ ^watch-[0-9a-f]{24}$ ]]
}

pr_watch_checkout_digest() {
  local root
  root="$(cd -- "$1" && pwd -P)" || return 1
  LC_ALL=C printf '%s' "$root" | verdict_audit_sha256
}

pr_watch_url_is_valid() {
  [[ "${1-}" =~ ^https://github[.]com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*$ ]]
}

# Watch state lives below Git's private directory, but a crash or local pathname
# replacement can still leave a symlink, FIFO, or unrelated inode at a leaf.
# Keep the directory identity explicit and make every leaf operation select one
# nonblocking, no-follow regular descriptor before it consumes or publishes data.
pr_watch_state_directory_identity() {  # directory
  perl -e '
    my @state = lstat($ARGV[0]);
    exit 1 unless @state && -d _ && !-l _;
    print $state[0], ":", $state[1];
  ' "$1"
}

pr_watch_prepare_regular_file() {  # path parent-device:inode
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -e '
    my ($path, $parent_identity) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 unless $parent_identity =~ /\A[0-9]+:[0-9]+\z/;
    my $parent = dirname($path);
    my @parent_before = lstat($parent);
    exit 1 unless @parent_before && -d _ && !-l _
      && ($parent_before[0] . ":" . $parent_before[1]) eq $parent_identity;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    my @parent_after = lstat($parent);
    exit 1 unless @opened && @named && @parent_after && -f $fh
      && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2"
}

pr_watch_append_regular_line() {  # path parent-device:inode line [sync]
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -MIO::Handle -e '
    my ($path, $parent_identity, $line, $sync) = @ARGV;
    $sync //= "0";
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless $parent_identity =~ /\A[0-9]+:[0-9]+\z/
      && $sync =~ /\A[01]\z/ && length($line) <= 16384
      && $line !~ /[\0\r\n]/;
    my $parent = dirname($path);
    my @parent_before = lstat($parent);
    exit 1 unless @parent_before && -d _ && !-l _
      && ($parent_before[0] . ":" . $parent_before[1]) eq $parent_identity;
    exit 1 if lstat($path) && -l _;
    my $flags = O_WRONLY | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $record = $line . "\n";
    my $offset = 0;
    while ($offset < length($record)) {
      my $written = syswrite($fh, $record, length($record) - $offset, $offset);
      next if !defined($written) && $!{EINTR};
      exit 1 unless defined($written) && $written > 0;
      $offset += $written;
    }
    $fh->sync or exit 1 if $sync eq "1";
    @opened = stat($fh);
    @named = lstat($path);
    my @parent_after = lstat($parent);
    exit 1 unless @opened && @named && @parent_after && -f $fh
      && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2" "$3" "${4:-0}"
}

# Return 0 when present, 1 when absent, and 2 when the state object is unsafe or
# corrupt. Callers must distinguish absence from a rejected state boundary.
pr_watch_regular_file_has_line() {  # path parent-device:inode line
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -e '
    my ($path, $parent_identity, $needle) = @ARGV;
    $SIG{ALRM} = sub { exit 2 };
    alarm 1;
    exit 2 unless $parent_identity =~ /\A[0-9]+:[0-9]+\z/
      && length($needle) <= 16384 && $needle !~ /[\0\r\n]/;
    my $parent = dirname($path);
    my @parent_before = lstat($parent);
    exit 2 unless @parent_before && -d _ && !-l _
      && ($parent_before[0] . ":" . $parent_before[1]) eq $parent_identity;
    exit 2 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 2;
    flock($fh, LOCK_SH | LOCK_NB) or exit 2;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && $opened[7] <= 8388608;
    my $body = "";
    while (1) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 65536);
      exit 2 unless defined($count);
      last if $count == 0;
      $body .= $chunk;
      exit 2 if length($body) > 8388608;
    }
    @opened = stat($fh);
    @named = lstat($path);
    my @parent_after = lstat($parent);
    exit 2 unless @opened && @named && @parent_after && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity
      && $body !~ /[\0\r]/ && ($body eq "" || $body =~ /\n\z/);
    close($fh) or exit 2;
    alarm 0;
    for my $line (split(/\n/, $body)) {
      exit 0 if $line eq $needle;
    }
    exit 1;
  ' "$1" "$2" "$3"
}

# Publish one exact validated source into a bounded claim slot without ever
# making an independent JSON copy. A fixed pending name is hard-linked first,
# then atomically renamed over an absent or verified-retired slot. The source
# remains the same inode until the caller atomically replaces its name with a
# recovery record.
pr_watch_claim_regular_file() {  # source destination identity sha256 -> identity
  perl -MFcntl=:DEFAULT,:flock -MDigest::SHA -MFile::Basename=dirname \
    -MIO::Handle -e '
    my ($source, $destination, $expected_identity, $expected_hash) = @ARGV;
    my $max = 65536;
    $SIG{ALRM} = sub { exit 1 };
    alarm 3;
    exit 1 unless $expected_identity =~ /\A[0-9]+:[0-9]+\z/
      && $expected_hash =~ /\A[0-9a-f]{64}\z/
      && $destination ne "" && dirname($source) eq dirname($destination);
    exit 1 if lstat($source) && -l _;
    my $read_flags = O_RDWR | O_NONBLOCK;
    $read_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $input, $source, $read_flags) or exit 1;
    flock($input, LOCK_EX | LOCK_NB) or exit 1;
    my @source_opened = stat($input);
    my @source_named = lstat($source);
    exit 1 unless @source_opened && @source_named && -f $input
      && ($source_opened[3] == 1 || $source_opened[3] == 2)
      && ($source_opened[0] . ":" . $source_opened[1]) eq $expected_identity
      && $source_opened[0] == $source_named[0]
      && $source_opened[1] == $source_named[1]
      && $source_opened[7] <= $max;
    my $read_body = sub {
      my $body = "";
      sysseek($input, 0, 0) or exit 1;
      while (length($body) <= $max) {
        my $chunk = "";
        my $count = sysread($input, $chunk, $max + 1 - length($body));
        exit 1 unless defined($count);
        last if $count == 0;
        $body .= $chunk;
      }
      exit 1 if length($body) > $max || $body =~ /[\0\r]/;
      $body =~ s/\n\z//;
      exit 1 if $body eq "" || index($body, "\n") >= 0;
      return $body;
    };
    my $body = $read_body->();
    exit 1 unless Digest::SHA::sha256_hex($body) eq $expected_hash;

    my $retired = "retired\n";
    my ($output, @destination_opened);
    my $destination_exists = 0;
    if (lstat($destination)) {
      exit 1 if -l _;
      my @destination_named = lstat($destination);
      if (@destination_named
          && $destination_named[0] == $source_opened[0]
          && $destination_named[1] == $source_opened[1]) {
        exit 1 unless $source_opened[3] == 2;
        close($input) or exit 1;
        alarm 0;
        print $source_opened[0], ":", $source_opened[1];
        exit 0;
      }
      my $write_flags = O_RDWR | O_NONBLOCK;
      $write_flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen($output, $destination, $write_flags) or exit 1;
      flock($output, LOCK_EX | LOCK_NB) or exit 1;
      @destination_opened = stat($output);
      @destination_named = lstat($destination);
      exit 1 unless @destination_opened && @destination_named && -f $output
        && $destination_opened[3] == 1
        && $destination_opened[0] == $destination_named[0]
        && $destination_opened[1] == $destination_named[1]
        && $destination_opened[7] == length($retired);
      my $existing = "";
      sysseek($output, 0, 0) or exit 1;
      while (length($existing) <= length($retired)) {
        my $chunk = "";
        my $count = sysread(
          $output, $chunk, length($retired) + 1 - length($existing));
        next if !defined($count) && $!{EINTR};
        exit 1 unless defined($count);
        last if $count == 0;
        $existing .= $chunk;
      }
      exit 1 unless $existing eq $retired;
      $destination_exists = 1;
    }

    my $verified_body = $read_body->();
    @source_opened = stat($input);
    @source_named = lstat($source);
    exit 1 unless Digest::SHA::sha256_hex($verified_body) eq $expected_hash
      && @source_opened && @source_named
      && ($source_opened[0] . ":" . $source_opened[1]) eq $expected_identity
      && $source_opened[0] == $source_named[0]
      && $source_opened[1] == $source_named[1];
    # The source bytes are durable before the only namespace handoff. The
    # first sync is intentionally before any second JSON name can exist.
    $input->sync or exit 1;
    @source_named = lstat($source);
    exit 1 unless @source_named
      && $source_opened[0] == $source_named[0]
      && $source_opened[1] == $source_named[1];
    my $pending = $destination . ".pending";
    my @pending_named = lstat($pending);
    if (@pending_named) {
      exit 1 unless -f _ && !-l _
        && $pending_named[0] == $source_opened[0]
        && $pending_named[1] == $source_opened[1];
    } else {
      link($source, $pending) or exit 1;
    }
    @pending_named = lstat($pending);
    exit 1 unless @pending_named
      && $pending_named[0] == $source_opened[0]
      && $pending_named[1] == $source_opened[1];
    if ($destination_exists) {
      my @destination_named = lstat($destination);
      exit 1 unless @destination_named
        && $destination_opened[0] == $destination_named[0]
        && $destination_opened[1] == $destination_named[1];
    }
    rename($pending, $destination) or exit 1;
    my @destination_named = lstat($destination);
    @source_named = lstat($source);
    exit 1 unless @destination_named
      && $destination_named[0] == $source_opened[0]
      && $destination_named[1] == $source_opened[1]
      && @source_named
      && $source_named[0] == $source_opened[0]
      && $source_named[1] == $source_opened[1];
    close($output) or exit 1 if defined($output);
    close($input) or exit 1;
    alarm 0;
    print $source_opened[0], ":", $source_opened[1];
    exit 0;
  ' "$1" "$2" "$3" "$4"
}

# Fixed claim slots bound cardinality per attachment key. A consumed tombstone
# has no authority and is retired immediately; an unrun JSON claim keeps its
# authority only for the bounded lease. Nonregular, locked, malformed, or
# replaced paths are left untouched.
pr_watch_retire_attachment_claim() {  # claim-path now-epoch lease-seconds
  perl -MFcntl=:DEFAULT,:flock -MIO::Handle -MJSON::PP=decode_json -e '
    my ($path, $now, $ttl) = @ARGV;
    my $max = 65536;
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless $now =~ /^[1-9][0-9]*$/ && length($now) <= 18
      && $ttl =~ /^[1-9][0-9]*$/ && length($ttl) <= 18;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && $opened[7] > 0 && $opened[7] <= $max;
    my $body = "";
    while (length($body) <= $max) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, $max + 1 - length($body));
      next if !defined($count) && $!{EINTR};
      exit 1 unless defined($count);
      last if $count == 0;
      $body .= $chunk;
    }
    exit 1 if length($body) > $max || $body =~ /[\0\r]/ || $body !~ /\n\z/;
    my $is_consumed =
      $body =~ /\Aconsumed:[0-9]+:[0-9]+:[0-9a-f]{64}\n\z/;
    my $is_expired_json = 0;
    if (!$is_consumed && $opened[9] <= $now - $ttl) {
      my $decoded = eval { decode_json($body) };
      $is_expired_json = !$@ && ref($decoded) eq "HASH"
        && exists($decoded->{schema}) && $decoded->{schema} == 1;
    }
    exit 1 unless $is_consumed || $is_expired_json;
    my @opened_after = stat($fh);
    @named = lstat($path);
    exit 1 unless @opened_after && @named && -f $fh
      && $opened_after[3] == 1
      && $opened_after[0] == $opened[0] && $opened_after[1] == $opened[1]
      && $opened_after[7] == $opened[7] && $opened_after[9] == $opened[9]
      && $opened_after[0] == $named[0] && $opened_after[1] == $named[1];
    my $retired = "retired\n";
    truncate($fh, 0) or exit 1;
    sysseek($fh, 0, 0) or exit 1;
    syswrite($fh, $retired) == length($retired) or exit 1;
    $fh->sync or exit 1;
    @opened_after = stat($fh);
    @named = lstat($path);
    exit 1 unless @opened_after && @named && -f $fh
      && $opened_after[3] == 1
      && $opened_after[0] == $opened[0] && $opened_after[1] == $opened[1]
      && $opened_after[7] == length($retired)
      && $opened_after[0] == $named[0] && $opened_after[1] == $named[1];
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2" "$3"
}

# Start or reuse one generation; readiness is the only successful return value.
# Caller owns dependency checks and supplies an existing private state directory.
pr_watch_start() {  # watcher state-directory branch sha pr-number
  local watcher="$1" directory="$2" branch="$3" sha="$4" pr="$5"
  local identity key id ready_directory ready_fifo actual
  [[ "${BOXLITE_PR_WATCH:-1}" != 0 ]] || return 0
  identity="$(pr_watch_state_directory_identity "$directory")" || return 1
  key="$(pr_watch_branch_key "$branch")" || return 1
  id="$(pr_watch_new_id "$directory" "$key")" || return 1
  ready_directory="$(mktemp -d "$directory/.watch-ready.XXXXXX")" || return 1
  ready_fifo="$ready_directory/ready"
  if ! mkfifo "$ready_fifo" || ! exec 9<> "$ready_fifo"; then
    rm -f "$ready_fifo"; rmdir "$ready_directory"
    return 1
  fi
  rm -f "$ready_fifo"; rmdir "$ready_directory"
  # Fork guarantees setsid is not called by a process-group leader. Isolate the
  # entire supervisor: its logger must survive the caller's group cleanup too.
  perl -MPOSIX -e '
    my $child = fork();
    exit 125 unless defined $child;
    exit 0 if $child;
    POSIX::setsid() >= 0 or exit 125;
    POSIX::close($_) for grep { $_ != 9 } 3..255;
    exec @ARGV or exit 127;
  ' bash -c '
    source "$1" || exit 127
    shift
    pr_watch_exec_with_regular_log "$@"
  ' -- "${BASH_SOURCE[0]}" "$directory/$key.daemon.log" "$identity" \
    bash "$watcher" --branch "$branch" --sha "$sha" --pr "$pr" \
    --watch-id "$id" --ready-fd 9 </dev/null >/dev/null 2>&1 || {
      exec 9>&-; return 1;
    }
  IFS= read -r -t 3 -u 9 actual || actual=""
  exec 9>&-
  pr_watch_id_is_valid "$actual" || {
    printf 'pr-watch: producer did not become ready for branch %s\n' "$branch" >&2
    return 1
  }
  printf '%s\n' "$actual"
}

# Supervise one command behind a capped output pipe. The supervisor owns the log
# flock; the command and anything it forks never inherit that generation lease.
# A first helper takes the flock, truncates, and writes at most 2 MiB. A repeat
# helper observes the busy flock without waiting, drains its candidate output to
# nowhere, and can still reach the branch-lock readiness handshake. When the
# direct command leader exits, the supervisor retires its logger and releases the
# flock even if a background descendant retained the pipe.
pr_watch_exec_with_regular_log() {  # path parent-device:inode command...
  local log_path="$1" parent_identity="$2"
  shift 2
  (( $# > 0 )) || return 1
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -MIO::Handle \
    -MPOSIX=:sys_wait_h -e '
    use strict;
    use warnings;
    my ($path, $parent_identity, @command) = @ARGV;
    my $max_bytes = 2 * 1024 * 1024;
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless @command && $parent_identity =~ /\A[0-9]+:[0-9]+\z/;
    my $parent = dirname($path);
    my @parent_before = lstat($parent);
    exit 1 unless @parent_before && -d _ && !-l _
      && ($parent_before[0] . ":" . $parent_before[1]) eq $parent_identity;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_APPEND | O_CREAT | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    my @parent_after = lstat($parent);
    exit 1 unless @opened && @named && @parent_after && -f $fh
      && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity;
    my $owns_log = flock($fh, LOCK_EX | LOCK_NB);
    if (!$owns_log) {
      exit 1 unless $!{EWOULDBLOCK} || $!{EAGAIN};
    }
    if ($owns_log) {
      truncate($fh, 0) or exit 1;
      sysseek($fh, 0, 0) or exit 1;
      $fh->sync or exit 1;
    }
    @opened = stat($fh);
    @named = lstat($path);
    @parent_after = lstat($parent);
    exit 1 unless @opened && @named && @parent_after && -f $fh
      && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && (!$owns_log || $opened[7] == 0)
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity;
    alarm 0;

    pipe(my $reader, my $writer) or exit 1;
    my $logger_pid = fork();
    exit 1 unless defined($logger_pid);
    if ($logger_pid == 0) {
      close($writer);
      POSIX::close(9);
      $SIG{TERM} = sub { exit 143 };
      $SIG{INT} = sub { exit 130 };
      my $written = 0;
      my $can_write = $owns_log ? 1 : 0;
      while (1) {
        my $chunk = "";
        my $count = sysread($reader, $chunk, 65536);
        next if !defined($count) && $!{EINTR};
        exit 1 unless defined($count);
        last if $count == 0;
        next unless $can_write && $written < $max_bytes;
        my @current = lstat($path);
        my @current_parent = lstat($parent);
        if (!@current || !@current_parent
            || $opened[0] != $current[0] || $opened[1] != $current[1]
            || ($current_parent[0] . ":" . $current_parent[1]) ne $parent_identity) {
          $can_write = 0;
          next;
        }
        my $wanted = $count;
        my $remaining = $max_bytes - $written;
        $wanted = $remaining if $wanted > $remaining;
        my $offset = 0;
        while ($offset < $wanted) {
          my $count_written = syswrite($fh, $chunk, $wanted - $offset, $offset);
          next if !defined($count_written) && $!{EINTR};
          exit 1 unless defined($count_written) && $count_written > 0;
          $offset += $count_written;
        }
        $written += $wanted;
      }
      if ($owns_log) {
        $fh->sync or exit 1;
      }
      close($reader) or exit 1;
      close($fh) or exit 1;
      exit 0;
    }

    my $command_pid = fork();
    if (!defined($command_pid)) {
      close($reader);
      close($writer);
      kill "TERM", $logger_pid;
      waitpid($logger_pid, 0);
      exit 1;
    }
    if ($command_pid == 0) {
      close($reader);
      close($fh);
      POSIX::dup2(fileno($writer), 1) >= 0 or exit 125;
      POSIX::dup2(fileno($writer), 2) >= 0 or exit 125;
      close($writer);
      exec(@command) or do {
        print STDERR "pr-watch: cannot exec watcher\n";
        exit 127;
      };
    }
    close($reader);
    close($writer);
    POSIX::close(9);

    my $command_waited;
    do {
      $command_waited = waitpid($command_pid, 0);
    } while ($command_waited < 0 && $!{EINTR});
    my $command_status = $?;
    if ($command_waited != $command_pid) {
      kill "TERM", $logger_pid;
      waitpid($logger_pid, 0);
      exit 1;
    }

    my $logger_waited = 0;
    for (1 .. 50) {
      $logger_waited = waitpid($logger_pid, WNOHANG);
      last if $logger_waited == $logger_pid;
      select(undef, undef, undef, 0.01);
    }
    if ($logger_waited != $logger_pid) {
      kill "TERM", $logger_pid;
      for (1 .. 10) {
        $logger_waited = waitpid($logger_pid, WNOHANG);
        last if $logger_waited == $logger_pid;
        select(undef, undef, undef, 0.01);
      }
    }
    if ($logger_waited != $logger_pid) {
      kill "KILL", $logger_pid;
      waitpid($logger_pid, 0);
    }
    close($fh) or exit 1;

    if (POSIX::WIFEXITED($command_status)) {
      exit POSIX::WEXITSTATUS($command_status);
    }
    if (POSIX::WIFSIGNALED($command_status)) {
      exit 128 + POSIX::WTERMSIG($command_status);
    }
    exit 1;
  ' "$log_path" "$parent_identity" "$@"
}

# The PostToolUse payload carries the original command and session, while Git's
# pre-push boundary carries the exact remote ref updates. This opaque key is the
# fixed meeting point; the manifest itself is still validated before use.
pr_watch_attachment_key() {  # session-scope command-sha256
  local session_scope="${1-}" command_hash="${2-}" digest
  [[ "$session_scope" =~ ^git-[0-9a-f]{40}([0-9a-f]{24})?$ \
     && "$command_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  digest="$(LC_ALL=C printf 'scope=%s\ncommand=%s' "$session_scope" "$command_hash" \
    | verdict_audit_sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'attach-%s' "$digest"
}

# Print `pid<TAB>watch_id<TAB>ready` for the live producer that owns LOCK_DIR.
# Fails unless owner.json has the exact schema, its start token matches the live
# PID, WATCH_ID (when given) matches, and the lock directory kept its identity
# across the read.
pr_watch_owner_read() {  # lock-dir [watch-id]
  local lock_dir="$1" expected_watch_id="${2-}" identity snapshot body pid token
  identity="$(pr_watch_state_directory_identity "$lock_dir" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$lock_dir/owner.json" 2>/dev/null)" \
    || return 1
  body="${snapshot#*$'\n'}"
  pid="$(jq -er --arg watch_id "$expected_watch_id" '
    select(type == "object"
      and (keys | sort) == ["pid","ready","schema","start_token","watch_id"]
      and .schema == 1
      and (.pid | type == "number" and . > 0 and floor == .)
      and (.start_token | type == "string" and test("^cksum-[0-9]+-[0-9]+$"))
      and (.watch_id | type == "string" and test("^watch-[0-9a-f]{24}$"))
      and ($watch_id == "" or .watch_id == $watch_id)
      and (.ready | type == "boolean"))
    | .pid' <<<"$body" 2>/dev/null)" || return 1
  token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" || return 1
  [[ "$(pr_watch_state_directory_identity "$lock_dir" 2>/dev/null)" == "$identity" ]] \
    || return 1
  jq -er --arg token "$token" \
    'select(.start_token == $token) | [.pid, .watch_id, .ready] | @tsv' <<<"$body"
}

# Compare-and-swap the attachment manifest record. The claim JSON is the only
# consumable capability after selection; the manifest becomes a small
# non-authoritative recovery record via atomic replace, never truncated in place.
# Every target first proves the exact manifest, claim, live lease, and prompt
# epoch. `check` only proves them; `discard` also retires the claim. Prints the
# manifest's new device:inode.
pr_watch_attachment_transition() {  # manifest generation-identity marker-identity claim claim-identity sha256 check|acquire|retry|discard expected-record replacement-record lease-path lease-identity lease-nonce epoch-path epoch-record
  perl -MFcntl=:DEFAULT,:flock -MDigest::SHA -MIO::Handle -e '
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
      && $target =~ /\A(?:check|acquire|retry|discard)\z/
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
  ' "$@"
}

# Hold the recovery lease flock for a live parent, then exit. Run it as the whole
# process of a process substitution: the first line reports
# `lease:<pid>:<nonce>:<device>:<inode>`, and the read end is the owner identity.
pr_watch_attachment_lease_hold() {  # lease-path parent-pid
  exec perl -MFcntl=:DEFAULT,:flock -MIO::Handle -e '
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
  ' "$1" "$2"
}
