#!/usr/bin/env bash
# Serialized command facade for auditor lifecycle state transitions.

auditor_control_state_initialize() {  # canonical-repo control-entrypoint
  auditor_control_state_repo="$1"
  auditor_control_state_entrypoint="$2"
  auditor_control_state_dir="$(auditor_override_control_dir \
    "$auditor_control_state_repo")" || return 1
}

auditor_control_state_retire_cache_entry() {  # exact cache path
  local cache_path="$1" quarantine_path
  [[ -e "$cache_path" || -L "$cache_path" ]] || return 0
  quarantine_path="${cache_path}.retired.$$-${RANDOM:-0}"
  verdict_audit_rename_exact "$cache_path" "$quarantine_path" 2>/dev/null || return 1
  # Regular files, symlinks, and FIFOs unlink; empty directories rmdir. A non-empty
  # directory remains quarantined outside every authoritative cache glob.
  rm -f "$quarantine_path" 2>/dev/null || true
  rmdir "$quarantine_path" 2>/dev/null || true
}

auditor_control_state_with_lock() {  # scope internal-command arguments...
  local scope="$1"
  shift
  local mutex_file="$auditor_control_state_dir/control.$scope.mutex"
  mkdir -p "$auditor_control_state_dir" 2>/dev/null || return 1
  # The parent retains the selected mutex inode while its child performs the state
  # transition. Perl marks descriptors close-on-exec, so directly execing the child
  # would silently drop the flock before the critical section began.
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($lock, @command) = @ARGV;
    my $child = 0;
    $SIG{ALRM} = sub {
      kill("TERM", $child) if $child;
      waitpid($child, 0) if $child;
      exit 2;
    };
    alarm 3;
    exit 2 if lstat($lock) && -l _;
    my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $lock, $flags, 0600) or exit 2;
    my @opened = stat($fh);
    my @named = lstat($lock);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX) or exit 2;
    @opened = stat($fh);
    @named = lstat($lock);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    $child = fork();
    exit 2 unless defined $child;
    if ($child == 0) {
      exec @command;
      exit 2;
    }
    waitpid($child, 0) == $child or exit 2;
    my $status = $?;
    alarm 0;
    exit 2 if $status == -1;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);
  ' "$mutex_file" /usr/bin/env bash "$auditor_control_state_entrypoint" "$@"
}

auditor_control_state_dispatch() {  # operation scope arguments...
  local operation="$1" scope="$2"
  shift 2
  case "$operation" in
    start|escalate|stop|inspect|handle-prompt|select|consume-wake|consume-completion)
      auditor_control_state_with_lock "$scope" "--locked-$operation" "$scope" "$@"
      ;;
    *)
      printf 'auditor-control-state.sh: unknown transition: %s\n' "$operation" >&2
      return 2
      ;;
  esac
}
