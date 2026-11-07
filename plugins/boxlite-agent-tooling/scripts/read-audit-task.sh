#!/usr/bin/env bash
# Prints a claim-checked audit task (design #407) only when the file is a regular,
# non-symlinked file of exactly the stated size and SHA-256. Any mismatch exits 1 with
# a reason on stderr and prints nothing, so the auditor writes no dossier.
# Usage: read-audit-task.sh <path> <sha256> <bytes>
set -uo pipefail
command -v perl >/dev/null 2>&1 || { printf 'read-audit-task: perl is required\n' >&2; exit 2; }
[[ $# -eq 3 ]] || { printf 'usage: read-audit-task.sh <path> <sha256> <bytes>\n' >&2; exit 2; }
[[ "$2" =~ ^[0-9a-f]{64}$ && "$3" =~ ^[1-9][0-9]{0,5}$ ]] \
  || { printf 'read-audit-task: invalid sha256 or byte count\n' >&2; exit 2; }
perl -MFcntl=:DEFAULT -MDigest::SHA=sha256_hex -e '
  my ($path, $digest, $bytes) = @ARGV;
  sub fail { print STDERR "read-audit-task: $_[0]\n"; exit 1 }
  $SIG{ALRM} = sub { fail("timed out reading the task file") };
  alarm 5;
  fail("task file is a symlink") if lstat($path) && -l _;
  my $flags = O_RDONLY | O_NONBLOCK;
  $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
  sysopen(my $fh, $path, $flags) or fail("task file is missing or unreadable");
  my @st = stat($fh);
  fail("task file is not a regular file") unless @st && -f _;
  fail("task file size does not match") unless $st[7] == $bytes;
  my $body = "";
  my $read = read($fh, $body, $bytes + 1);
  fail("task file could not be read") unless defined $read && $read == $bytes;
  fail("task file hash does not match") unless sha256_hex($body) eq $digest;
  print $body;
' "$1" "$2" "$3"
