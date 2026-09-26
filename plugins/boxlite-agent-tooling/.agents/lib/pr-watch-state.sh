#!/usr/bin/env bash
# Shared, side-effect-free state identity helpers for the PR watch producer and
# its post-write consumer. Callers own dependency checks and error reporting.

# A fixed-size digest avoids both slash/dash aliases and filesystem component
# limits. The branch remains present in every JSON event for human inspection.
pr_watch_branch_key() {
  local branch="${1-}" digest
  [[ -n "$branch" ]] || return 1
  digest="$(LC_ALL=C printf '%s' "$branch" | shasum -a 256 | awk '{print $1}')" \
    || return 1
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
  digest="$(LC_ALL=C printf '%s' "$seed" | shasum -a 256 | awk '{print $1}')" \
    || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'watch-%s' "${digest:0:24}"
}

pr_watch_id_is_valid() {
  [[ "${1-}" =~ ^watch-[0-9a-f]{24}$ ]]
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
# recovery record. The no-destination form gives the final consumer the same
# exact-inode one-shot rule.
_pr_watch_consume_regular_file() {  # source destination-or-empty identity sha256
  perl -MFcntl=:DEFAULT,:flock -MDigest::SHA -MFile::Basename=dirname \
    -MIO::Handle -e '
    my ($source, $destination, $expected_identity, $expected_hash) = @ARGV;
    my $max = 65536;
    $SIG{ALRM} = sub { exit 1 };
    alarm 3;
    exit 1 unless $expected_identity =~ /\A[0-9]+:[0-9]+\z/
      && $expected_hash =~ /\A[0-9a-f]{64}\z/;
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
    if ($destination ne "") {
      exit 1 unless dirname($source) eq dirname($destination);
      if (lstat($destination)) {
        exit 1 if lstat($destination) && -l _;
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
    }

    my $verified_body = $read_body->();
    @source_opened = stat($input);
    @source_named = lstat($source);
    exit 1 unless Digest::SHA::sha256_hex($verified_body) eq $expected_hash
      && @source_opened && @source_named
      && ($source_opened[0] . ":" . $source_opened[1]) eq $expected_identity
      && $source_opened[0] == $source_named[0]
      && $source_opened[1] == $source_named[1];
    if ($destination ne "") {
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
    }

    my $tombstone = "consumed:" . $expected_identity . ":" . $expected_hash . "\n";
    truncate($input, 0) or exit 1;
    sysseek($input, 0, 0) or exit 1;
    syswrite($input, $tombstone) == length($tombstone) or exit 1;
    $input->sync or exit 1;
    @source_named = lstat($source);
    exit 1 unless @source_named
      && $source_opened[0] == $source_named[0]
      && $source_opened[1] == $source_named[1];
    close($input) or exit 1;
    alarm 0;
  ' "$1" "$2" "$3" "$4"
}

pr_watch_claim_regular_file() {  # source selected identity sha256 -> selected identity
  _pr_watch_consume_regular_file "$1" "$2" "$3" "$4"
}

pr_watch_consume_regular_file() {  # source identity sha256
  _pr_watch_consume_regular_file "$1" "" "$2" "$3" >/dev/null
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
    | shasum -a 256 | awk '{print $1}')" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'attach-%s' "$digest"
}
