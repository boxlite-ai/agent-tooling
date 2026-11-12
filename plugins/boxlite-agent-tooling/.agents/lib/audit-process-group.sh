#!/usr/bin/env bash
# Shared headless audit control for POSIX process groups. Source only.

audit_group_uses_controller() {
  [[ "$OSTYPE" == darwin* || "$OSTYPE" == linux* ]]
}

audit_group_open_controller() {  # private run directory
  local request="$1/group-request" lifetime="$1/group-lifetime"
  if ! mkfifo "$request" "$lifetime"; then
    rm -f "$request" "$lifetime"
    return 1
  fi
  # Temporary read/write ends let us open both halves before the group exists.
  # shellcheck disable=SC2094 # Both paths are FIFOs, opened on separate descriptors.
  if ! { exec 10<>"$request" 11<>"$lifetime" &&
         exec 12<"$request" 13>"$request" 14<"$lifetime" 15>"$lifetime"; }; then
    exec 10>&- 11>&- 12<&- 13>&- 14<&- 15>&-
    rm -f "$request" "$lifetime"
    return 1
  fi
  exec 10>&- 11>&-
  if ! rm -f "$request" "$lifetime"; then
    exec 12<&- 13>&- 14<&- 15>&-
    return 1
  fi
}

audit_group_process() {  # control directory grace | observe pgid
  local -a interpreter=(perl)
  [[ "$1" != control ]] || interpreter=(exec perl)
  # shellcheck disable=SC2016 # Variables belong to Perl.
  "${interpreter[@]}" -MPOSIX -MIO::Select -MTime::HiRes=alarm,sleep,time -e '
    sub live_members {
      my ($group, $leader, $controller) = @_;
      my $inspector = open(my $processes, "-|", "ps", "-axo", "pid=,pgid=,stat=");
      return undef unless defined $inspector;
      my $live = 0;
      while (<$processes>) {
        next unless /^\s*(\d+)\s+(\d+)\s+(\S+)/;
        $live = 1 if $2 == $group && $3 !~ /^Z/ &&
          $1 != $leader && $1 != $controller && $1 != $inspector;
      }
      return close($processes) ? $live : undef;
    }

    sub escalate {
      my $directory = shift;
      if (open(my $status, ">", "$directory/group-kill")) {
        print {$status} "escalated\n";
        close($status);
      }
      kill "KILL", 0;
      exit 125;
    }

    my ($mode, $value, $grace) = @ARGV;
    $SIG{ALRM} = sub { POSIX::_exit(125) };
    if ($mode eq "observe") {
      alarm 2;
      while (1) {
        my $live = live_members($value, 0, 0);
        exit 125 unless defined $live;
        exit 0 unless $live;
        sleep 0.02;
      }
    }

    my $group = getpgrp(0);
    my $leader = getppid();
    exit 125 unless $group > 1 && $group == $leader;
    $SIG{$_} = "IGNORE" for qw(TERM INT HUP);
    alarm 3;
    exit 125 unless live_members($group, 0, 0);
    open(my $ready, ">", "$value/group-ready") or exit 125;
    print {$ready} "$$\n" or exit 125;
    close($ready) or exit 125;
    alarm 0;

    # Either supervisor EOF or leader death ends the independently owned group.
    my $input = IO::Select->new(\*STDIN);
    while (getppid() == $leader) {
      next unless $input->can_read(0.05);
      defined(sysread(STDIN, my $request, 1)) or exit 125;
      last;
    }
    kill("TERM", 0) or exit 125;
    $SIG{ALRM} = sub { escalate($value) };
    alarm $grace + 1;
    my $until = time + $grace;
    while (time < $until && live_members($group, $leader, $$)) { sleep 0.05; }
    alarm 0;
    escalate($value);
  ' "$@"
}

audit_group_start_controller() {  # private run directory, grace seconds
  local directory="$1" grace="$2" controller attempt
  set +m
  exec 13>&- 14<&-
  audit_group_process control "$directory" "$grace" <&12 >&15 \
    12<&- 15>&- 4>&- 7>&- 8>&- 9>&- &
  controller=$!
  exec 12<&- 15>&-
  for (( attempt=0; attempt<150; attempt++ )); do
    [[ ! -s "$directory/group-ready" ]] || return 0
    kill -0 "$controller" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

audit_group_stop_controller() {  # private run directory, grace seconds, PGID to observe
  local directory="$1" grace="$2" pgid="$3" unexpected status=0
  exec 13>&-
  read -r -t "$((grace + 2))" unexpected <&14 || status=$?
  exec 14<&-
  # EOF means the controller closed its lifetime writer. Observe survivors before return.
  [[ "$status" == 1 && -z "$unexpected" && -s "$directory/group-kill" ]] || return 1
  audit_group_process observe "$pgid"
}
