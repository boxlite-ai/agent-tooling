#!/usr/bin/env bash
# Keep existing watch intent alive without delivering pending events.
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../lib/pr-watch-schedule.sh
source "$script_dir/../lib/pr-watch-schedule.sh" || exit 127
[[ $# == 1 ]] || { printf 'usage: pr-watch-keepalive.sh TARGETS_JSON\n' >&2; exit 2; }
for dependency in git jq perl shasum gh; do
  command -v "$dependency" >/dev/null || exit 127
done
pr_watch_schedule_tick "$script_dir/pr-watch-session.sh" "$1"
