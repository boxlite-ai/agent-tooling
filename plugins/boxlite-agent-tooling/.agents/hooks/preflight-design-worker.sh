#!/usr/bin/env bash
# The host hook owns launch; the Bash action itself is a read-only status command.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || exit 2
# shellcheck source=../lib/hook-host.sh
source "$plugin_root/.agents/lib/hook-host.sh" || exit 2
host="$(hook_host_kind)" || exit 2
[[ "$host" == claude || "$host" == codex ]] || exit 0
python="$(command -v python3)" || { printf 'design-doc: python3 is required\n' >&2; exit 2; }
selection="$(printf '%s' "$payload" | "$python" -I -c '
import json,os,sys
p=json.load(sys.stdin); command=p.get("tool_input",{}).get("command","")
if not isinstance(command,str): sys.exit(2)
if "design-doc.sh" not in command or "run" not in command: sys.exit(0)
if command != "bash \""+sys.argv[1]+"/scripts/design-doc.sh\" run": sys.exit(2)
cwd=p.get("tool_input",{}).get("workdir") or p.get("tool_input",{}).get("cwd") or p.get("cwd") or os.getcwd()
if not isinstance(cwd,str) or not os.path.isabs(cwd): sys.exit(2)
print(cwd)
' "$plugin_root")" || {
  printf 'design-doc: use only bash "%s/scripts/design-doc.sh" run, without prefixes or extra arguments\n' "$plugin_root" >&2
  exit 2
}
[[ -n "$selection" ]] || exit 0
exec "$python" -I "$plugin_root/scripts/design-worker.py" "$host" "$selection"
