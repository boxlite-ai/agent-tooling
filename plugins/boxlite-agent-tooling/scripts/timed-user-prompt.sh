#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Confirmation lifecycle CLI. Replies come from the host prompt hook.
set -euo pipefail
[[ $# -ge 3 && $# -le 4 && "$1" =~ ^(request|status|renew|consume|fallback)$ ]] || {
  printf 'usage: timed-user-prompt.sh request|status|renew|consume|fallback STATE SPEC_OR_ID [RENEWAL_INSTRUCTION]\n' >&2
  exit 2
}
for dependency in jq perl date; do
  command -v "$dependency" >/dev/null || { printf 'missing dependency: %s\n' "$dependency" >&2; exit 2; }
done
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/timed-user-prompt.sh
source "$plugin/.agents/lib/timed-user-prompt.sh"
timed_user_prompt "$@"
