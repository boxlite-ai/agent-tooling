#!/usr/bin/env bash
# Source-only facade. Requires Bash, jq, perl; stdin/stdout are bounded JSON.

audit_reflection() { # operation state-path; request on stdin
  local library directory
  library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
  directory="$(dirname "$2")"
  [[ -d "$directory" && ! -L "$directory" ]] || {
    printf 'audit-reflection: state directory is unavailable\n' >&2; return 2;
  }
  # Keep the transition lease separate from the atomic writer's directory anchor.
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($library, $operation, $path) = @ARGV;
    my $child = 0;
    $SIG{ALRM} = sub {
      if ($child) { kill "KILL", -$child; kill "KILL", $child; waitpid($child, 0) }
      print STDERR "audit-reflection: state transition timed out\n"; exit 2;
    };
    alarm 5;
    my $lock = "$path.mutex";
    sysopen(my $fh, $lock, O_CREAT|O_RDWR|O_NONBLOCK|O_NOFOLLOW, 0600) or exit 2;
    my @opened = stat($fh); my @named = lstat($lock);
    exit 2 unless -f $fh && $opened[3] == 1 && @named
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX) or exit 2;
    @named = lstat($lock);
    exit 2 unless @named && $opened[0] == $named[0] && $opened[1] == $named[1];
    $child = fork(); exit 2 unless defined $child;
    if (!$child) {
      setpgrp(0, 0) or exit 2;
      exec "/bin/bash", "-c", q{
        set -uo pipefail
        source "$1/verdict-audit-state.sh" && source "$1/audit-reflection.sh" || exit 2
        _audit_reflection_transition "$@"
      }, "audit-reflection", $library, $operation, $path;
      exit 2;
    }
    waitpid($child, 0) == $child or exit 2;
    my $status = $?; alarm 0;
    exit($status & 127 ? 2 : $status >> 8);
  ' "$library" "$1" "$2" || {
    printf 'audit-reflection: rejected %s for %s\n' "$1" "$2" >&2; return 2;
  }
}

_audit_reflection_transition() { # library operation state-path; lease already held
  local library="$1" operation="$2" path="$3" request state=null snapshot next history_hash
  local LC_ALL=C
  request="$(perl -e '
    my $body = "";
    while (length($body) <= 1048576) {
      my $count = read(STDIN, my $chunk, 1048577 - length($body));
      exit 2 unless defined $count; last unless $count; $body .= $chunk;
    }
    exit 2 if length($body) > 1048576 || $body =~ /\0/;
    print $body;
  ')" || return 2
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot="$(verdict_audit_read_regular_state "$path" 1048576 json)" || return 2
    state="${snapshot#*$'\n'}"
    history_hash="$(_audit_reflection_history_hash "$state")" || return 2
    [[ "$(jq -r '.history_hash' <<<"$state")" == "$history_hash" ]] || {
      printf 'audit-reflection: history checksum changed\n' >&2; return 2;
    }
  fi
  next="$(printf '%s\n%s\n' "$state" "$request" \
    | jq -ceSs -L "$library" --arg operation "$operation" -f "$library/audit-reflection.jq")" || return 2
  history_hash="$(_audit_reflection_history_hash "$next")" || return 2
  next="$(jq -cS --arg hash "$history_hash" '.history_hash=$hash' <<<"$next")" || return 2
  (( ${#next} <= 1048576 )) || return 2
  if [[ "$operation" != status ]]; then
    printf '%s\n' "$next" | verdict_audit_write_atomic "$path" || return 2
  fi
  printf '%s\n' "$next"
}

_audit_reflection_history_hash() {
  printf '%s' "$1" | jq -cS '{context,registry,attempts:[.attempts[] | select(.outcome != null)]}' \
    | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
}
