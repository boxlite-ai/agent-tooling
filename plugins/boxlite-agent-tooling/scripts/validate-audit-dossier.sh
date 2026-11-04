#!/usr/bin/env bash
# Candidate validation only: no state writes, approval, or live freshness checks.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
library="$plugin_root/.agents/lib"
if (( $# < 2 || $# > 3 )) || [[ "$1" != verdict && "$1" != commit && "$1" != push ]]; then
  printf 'usage: validate-audit-dossier.sh <verdict|commit|push> <history-path|-> [dossier-path|-]\n' >&2
  exit 2
fi
for dependency in jq perl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'audit-dossier: required command missing: %s\n' "$dependency" >&2; exit 2;
  }
done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$library/verdict-audit-state.sh" || exit 2
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$library/audit-reflection.sh" || exit 2
kind="$1" history_path="$2" dossier_path="${3:--}"
if [[ "$dossier_path" == - ]]; then
  candidate="$(perl -e '
    $SIG{ALRM} = sub { exit 2 }; alarm 5; binmode STDIN;
    my $body = "";
    while (length($body) <= 1048576) {
      my $n = sysread(STDIN, my $chunk, 1048577 - length($body));
      exit 2 unless defined $n; last unless $n; $body .= $chunk;
    }
    exit 2 if length($body) > 1048576 || $body =~ /\0/;
    print $body;
  ')" || { printf 'audit-dossier: stdin unreadable, oversized, timed out, or contains NUL\n' >&2; exit 2; }
else
  candidate="$(verdict_audit_read_regular_state "$dossier_path" 1048576 json)" || {
    printf 'audit-dossier: dossier must be a readable regular file, at most 1 MiB, without NUL\n' >&2; exit 2;
  }
  candidate="${candidate#*$'\n'}"
fi
if [[ "$kind" == verdict ]]; then
  candidate="$(printf '%s' "$candidate" | verdict_audit_normalize_dossier 2>/dev/null)" || {
    printf 'audit-dossier: invalid verdict dossier shape or verdict/findings\n' >&2; exit 1;
  }
else
  candidate="$(printf '%s' "$candidate" | jq -ecs -L "$library" --arg kind "$kind" '
    include "audit-dossier"; audit_dossier_normalize_git |
    if .command_kind != $kind then error("command_kind does not match requested kind")
    elif (.verdict == "PASS") != ((.findings | length) == 0)
    then error("verdict/findings inconsistent: PASS requires none; FAIL requires findings") else . end
  ')" || { printf 'audit-dossier: invalid Git dossier shape, kind, or verdict/findings\n' >&2; exit 1; }
fi
if [[ "$history_path" == - ]]; then
  printf '%s' "$candidate" | jq -e '.history_review == null and .reflection_review == null' >/dev/null || {
    printf 'audit-dossier: history assessments require the supplied history input\n' >&2; exit 1;
  }
  printf '{"valid":true,"scope":"shape"}\n'
  exit 0
fi
history_limit="$(audit_reflection_history_limit)"
history="$(verdict_audit_read_regular_state "$history_path" "$history_limit" json)" || {
  printf 'audit-dossier: history must be a readable regular file, at most 10 MiB, without NUL\n' >&2; exit 2;
}
history="${history#*$'\n'}"
history_hash="$(_audit_reflection_history_hash "$history")" || exit 1
if ! printf '%s' "$history" | jq -e --arg hash "$history_hash" --arg kind "$kind" '
    .history_hash == $hash and .context.gate == $kind and
    (.attempts | length) > 0 and .attempts[-1].outcome == null
  ' >/dev/null; then
  printf 'audit-dossier: invalid history checksum, audit kind, or pending attempt\n' >&2; exit 1
fi
if [[ "$(printf '%s' "$history" | jq '.reflection != null')" == true ]]; then
  reflection_hash="$(_audit_reflection_body_hash "$history")" || exit 1
  printf '%s' "$history" | jq -e --arg hash "$reflection_hash" '.reflection.hash == $hash' >/dev/null || {
    printf 'audit-dossier: invalid reflection checksum\n' >&2; exit 1;
  }
fi
request="$(printf '%s\n%s\n' "$history" "$candidate" | jq -ces -L "$library" '
  include "audit-dossier";
  .[1] as $dossier | .[0] | audit_dossier_record_request($dossier; .attempts[-1].id)
')" || exit 1
# Exercise the authoritative pure transition; discard its next state. Never call
# the persistence facade here: even its status operation opens a mutex file.
printf '%s\n%s\n' "$history" "$request" | jq -ceSs -L "$library" \
  --arg operation record --argjson history_max_bytes "$history_limit" \
  -f "$library/audit-reflection.jq" >/dev/null || exit 1
printf '{"valid":true,"scope":"history"}\n'
