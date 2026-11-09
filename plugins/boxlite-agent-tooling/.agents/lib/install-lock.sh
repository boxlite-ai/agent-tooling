#!/usr/bin/env bash
# Source-only installer lease: an flock on .install.guard that the setup child inherits
# on descriptor 9, so a killed installer cannot free the lock while setup still runs.
install_lock_native() {  # cache directory
  case "${OSTYPE:-}" in
    darwin*)
      LC_ALL=C /bin/df -lP -- "$1" >/dev/null 2>&1 \
        && LC_ALL=C /bin/df -PT apfs,hfs -- "$1" >/dev/null 2>&1 || return 1 ;;
    linux*)
      case "$(stat -f -c %T -- "$1" 2>/dev/null)" in
        ext2/ext3|xfs|btrfs|f2fs|zfs|tmpfs) ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
  perl -MConfig -e 'exit($Config{d_flock} eq "define" ? 0 : 1)'
}

install_lock_lease() {  # enter|verify, cache directory, [command...]
  local perl_command=(perl)
  [[ "$1" != enter ]] || perl_command=(exec perl)
  "${perl_command[@]}" -MFcntl=:DEFAULT,:flock,:mode -MPOSIX=dup2 -e '
    my ($mode, $cache, @command) = @ARGV;
    my $guard = "$cache/.install.guard";
    my $unavailable = sub {
      print STDERR "agent-tooling: another installation is already in progress or the lock is unavailable: $guard\n"
        if $mode eq "enter";
      exit 1;
    };
    my $same_file = sub {
      my ($fh, $path) = @_;
      my @opened = stat($fh);
      my @named = lstat($path);
      return @opened && @named && S_ISREG($opened[2]) && S_ISREG($named[2])
        && $opened[0] == $named[0] && $opened[1] == $named[1];
    };
    if ($mode eq "verify") {
      open(my $lease, "<&=9") or exit 1;
      exit 1 unless flock($lease, LOCK_EX | LOCK_NB) && $same_file->($lease, $guard);
      exit 0;
    }
    exit 1 unless $mode eq "enter";
    sysopen(my $lease, $guard, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CREAT, 0600) or $unavailable->();
    $unavailable->() unless -f $lease && flock($lease, LOCK_EX | LOCK_NB)
      && $same_file->($lease, $guard);
    dup2(fileno($lease), 9) == 9 or $unavailable->();
    open(my $inherited, "<&=9") or $unavailable->();
    fcntl($inherited, F_SETFD, 0) or $unavailable->();
    exec @command;
    exit 127;
  ' "$@"
}
