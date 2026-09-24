#!/usr/bin/env bash
# PreToolUse: verify the current design before explicit editing operations.
# Native tool names/denials: openai/codex codex-rs/hooks/src/events/pre_tool_use.rs:30-44.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deny() {
  printf 'design-doc: %s\n' "$1" >&2
  exit 2
}
for dependency in jq perl git curl; do
  command -v "$dependency" >/dev/null 2>&1 || deny "required command missing: $dependency"
done
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || deny 'tool input exceeds the inspection limit'
tool="$(jq -er '.tool_name | strings | select(length > 0)' <<<"$payload")" || deny 'invalid tool input'
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit|apply_patch) ;;
  *) deny 'unrecognized tool at the code-edit boundary' ;;
esac
cwd="$(jq -er --arg fallback "${CLAUDE_PROJECT_DIR:-$PWD}" \
  '.tool_input.workdir // .tool_input.cwd // .cwd // $fallback | strings | select(length > 0)' \
  <<<"$payload")" || deny 'invalid working directory'
[[ -d "$cwd" ]] || deny 'working directory is unavailable'

# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin_root/.agents/lib/verdict-audit-state.sh" || deny 'state library unavailable'
# shellcheck source=../lib/reply-summary.sh
source "$plugin_root/.agents/lib/reply-summary.sh" || deny 'writing checks unavailable'
# shellcheck source=../lib/concise-writing.sh
source "$plugin_root/.agents/lib/concise-writing.sh" || deny 'summary check unavailable'
# shellcheck source=../lib/design-doc.sh
source "$plugin_root/.agents/lib/design-doc.sh" || deny 'document verifier unavailable'
if ! design_doc_binding check "$cwd" >/dev/null; then
  deny "Before writing code, create a concise 1–3 page design doc, then run:
bash \"$plugin_root/scripts/design-doc.sh\" bind <GitHub-issue/Notion/Linear-URL>
Shell investigation and document registration remain available."
fi
