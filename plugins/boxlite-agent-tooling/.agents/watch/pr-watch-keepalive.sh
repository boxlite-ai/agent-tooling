#!/usr/bin/env bash
# Reconcile existing watch intent; optionally read pending events without acknowledgment.
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../lib/pr-watch-schedule.sh
source "$script_dir/../lib/pr-watch-schedule.sh" || exit 127
mode=keepalive
if [[ ${1:-} == --events ]]; then mode=events; shift; fi
[[ $# == 1 ]] || { printf 'usage: pr-watch-keepalive.sh [--events] TARGETS_JSON\n' >&2; exit 2; }
for dependency in git jq perl shasum gh; do
  command -v "$dependency" >/dev/null || {
    printf 'pr-watch-schedule: missing dependency %s\n' "$dependency" >&2; exit 127;
  }
done
pr_watch_schedule_tick "$script_dir/pr-watch-session.sh" "$1" "$mode"
