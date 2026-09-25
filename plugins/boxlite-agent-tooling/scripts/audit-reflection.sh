#!/usr/bin/env bash
# Bounded JSON request on stdin, updated cycle on stdout; failures use stderr/exit 2.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in jq perl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'audit-reflection: missing dependency: %s\n' "$dependency" >&2; exit 2;
  }
done
[[ $# == 2 ]] || { printf 'usage: audit-reflection.sh prepare|record|status STATE < REQUEST\n' >&2; exit 2; }
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh" || exit 2
audit_reflection "$@"
