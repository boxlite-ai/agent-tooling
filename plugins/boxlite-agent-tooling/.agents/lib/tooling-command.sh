#!/usr/bin/env bash
# Source-only bounded command runner; requires Perl and date. Never reads stdin.
tooling_command() { # absolute deadline, executable, arguments...
  local deadline="$1" remaining limit="${AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS:-30}"
  shift
  if [[ ! "$deadline" =~ ^[0-9]{1,12}$ || ! "$limit" =~ ^[1-9][0-9]?$ ]] || (( limit > 30 )); then
    printf 'agent-tooling: invalid command deadline or timeout (1-30 seconds required)\n' >&2
    return 2
  fi
  remaining=$((deadline - $(date +%s)))
  (( remaining > 0 )) || { printf 'agent-tooling: update deadline exceeded\n' >&2; return 124; }
  (( remaining < limit )) || remaining="$limit"
  perl -MPOSIX=:sys_wait_h -e '
    my $seconds = shift;
    my $child = fork(); defined($child) or exit 125;
    if (!$child) { setpgrp(0, 0) or exit 125; exec @ARGV; exit 127 }
    my ($interrupted, $reaped, $status) = (0, 0, 0);
    $SIG{ALRM} = sub { $interrupted = 124 };
    $SIG{TERM} = sub { $interrupted = 143 };
    $SIG{INT} = sub { $interrupted = 130 };
    alarm $seconds;
    while (!$interrupted) {
      if (!$reaped) {
        my $done = waitpid($child, WNOHANG);
        if ($done == $child) { $status = $?; $reaped = 1 }
        last if $done == -1 && !$!{EINTR};
      }
      if ($reaped && !kill(0, -$child)) {
        alarm 0; exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
      }
      select undef, undef, undef, 0.02;
    }
    alarm 0;
    kill "TERM", -$child; kill "TERM", $child;
    select undef, undef, undef, 0.2;
    kill "KILL", -$child; kill "KILL", $child;
    waitpid($child, 0) unless $reaped;
    print STDERR "agent-tooling: command interrupted or timed out\n";
    exit($interrupted || 125);
  ' "$remaining" "$@"
}
