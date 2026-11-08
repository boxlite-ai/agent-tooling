#!/usr/bin/env bash
# Print a previous PASS end offset only as a discovery hint. Exit 1 silently
# when no usable hint exists, or 2 for invocation and setup errors.
set -uo pipefail
if [[ $# -ne 3 ]]; then
  printf 'usage: read-verdict-index.sh <repo-root> <parent-session-id> <transcript>\n' >&2
  exit 2
fi
for dependency in git jq perl; do
  command -v "$dependency" >/dev/null || {
    printf 'read-verdict-index: %s is required\n' "$dependency" >&2
    exit 2
  }
done
library="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.agents/lib" && pwd -P)" || exit 2
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$library/verdict-audit-state.sh" || exit 2

[[ -n "$1" && -n "$2" && -n "$3" ]] || exit 1
repo="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || exit 1
state="$repo/.agents/state"
[[ ! -L "$repo/.agents" && ! -L "$state" ]] || exit 1
scope="$(verdict_audit_scope_identity "$2" "$repo" 2>/dev/null)" || exit 1
path="$(verdict_audit_state_path "$state/last-verdict-index.json" "$scope")"
record="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || exit 1
[[ ! -L "$repo/.agents" && ! -L "$state" ]] || exit 1

# The writer emits one compact JSON object. Round-trip before extracting fields
# to reject duplicate keys that jq would otherwise silently collapse.
locator="$(printf '%s' "$record" | jq -eRrs '
  def matches($pattern): type == "string" and test($pattern);
  def byte_offset: type == "number" and . <= 9007199254740991
    and (tostring | test("\\A(0|[1-9][0-9]{0,15})\\z"));
  . as $raw | fromjson | select(tojson == $raw)
  | select(type == "object" and .version == 1
    and (del(.turn_id) | keys == ["generation", "message_id", "native_range", "version"])
    and (.generation | matches("\\A[1-9][0-9]*-[0-9]+-[0-9]+\\z"))
    and (.message_id | matches("\\Acksum-[0-9]+-[0-9]+\\z"))
    and (if has("turn_id") then (.turn_id | matches("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z")) else true end))
  | .native_range
  | select(type == "object" and keys == ["device_inode", "end_byte", "sha256", "start_byte"]
    and (.device_inode | matches("\\A[0-9]+:[0-9]+\\z"))
    and (.sha256 | matches("\\A[0-9a-f]{64}\\z"))
    and (.start_byte | byte_offset) and (.end_byte | byte_offset)
    and .start_byte < .end_byte)
  | [.device_inode, .end_byte] | @tsv
' 2>/dev/null)" || exit 1
IFS=$'\t' read -r identity end_byte <<<"$locator" || exit 1
source_bytes="$(verdict_audit_regular_file_bytes "$3" "$identity" 2>/dev/null)" || exit 1
(( end_byte < source_bytes )) || exit 1
printf '%s\n' "$end_byte"
