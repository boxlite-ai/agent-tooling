#!/usr/bin/env bash
# Private POSIX group leader. Descriptor 3 is the supervisor's lifetime channel.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/audit-process-group.sh
source "$plugin_root/.agents/lib/audit-process-group.sh" || exit 2
directory="$1"
shift
audit_group_process control "$directory" 2 <&3 >/dev/null 2>&1 3<&- &
controller=$!
exec 3<&-
for ((attempt=0; attempt<150; attempt++)); do
  [[ ! -s "$directory/group-ready" ]] || exec "$@"
  kill -0 "$controller" 2>/dev/null || exit 2
  sleep 0.02
done
exit 2
