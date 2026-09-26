#!/usr/bin/env bash
# Native auditor entry point; context is data, payload is bounded JSON on stdin.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ $# -ge 2 && $# -le 3 ]] || { printf 'usage: audit-reflection-gate.sh CONTEXT OPERATION [ATTEMPT_ID]\n' >&2; exit 2; }
for dependency in jq perl git; do command -v "$dependency" >/dev/null || exit 2; done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh"
# shellcheck source=../.agents/lib/audit-reflection-gate.sh
source "$plugin/.agents/lib/audit-reflection-gate.sh"
payload="$(perl -e 'my $b=""; while (length($b)<=1048576) {
  my $n=read(STDIN,my $chunk,1048577-length($b)); exit 2 unless defined $n;
  last unless $n; $b.=$chunk;
} exit 2 if length($b)>1048576 || $b=~/\0/; print $b')"
attempt_id="${3:-}"
if [[ "$2" == prepare && -z "$attempt_id" ]]; then
  attempt_id="$(perl -e 'open my $f,"<","/dev/urandom" or exit 2;
    read($f,my $b,16)==16 or exit 2; print unpack("H*",$b)')"
fi
audit_reflection_gate "$1" "$2" "$attempt_id" "$payload"
