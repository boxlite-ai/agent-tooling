#!/usr/bin/env bash
# PreToolUse: verify the current design, and an independent research verdict for its
# exact content, before explicit edits inside a repository.
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

# shellcheck source=../lib/edit-scope.sh
source "$plugin_root/.agents/lib/edit-scope.sh" || deny 'edit scope library unavailable'
# Editor paths or apply_patch file headers (openai/codex codex-rs/apply-patch/src/parser.rs:39-42);
# Codex passes the patch as tool_input.command (codex-rs/core/src/hook_runtime.rs:233-234).
# A path holding a newline or NUL cannot be listed, so it keeps the gate; \A and \z
# anchor the whole path, where jq's $ would also match before a final newline.
targets="$(jq -r --arg tool "$tool" '
  (if $tool == "apply_patch" then
     [.tool_input.command | strings | splits("\n")
      | capture("^\\s*\\*\\*\\* (?:(?:Add|Delete|Update) File|Move to): (?<path>.*\\S)").path]
   elif $tool == "NotebookEdit" then [.tool_input.notebook_path]
   else [.tool_input.file_path] end)
  | select(length > 0 and all(.[]; type == "string" and test("\\A[^\n\u0000]+\\z"))) | .[]' \
  <<<"$payload")" || targets=''
# Scratch, memory and plan files are not repository code, so they need no design doc.
if edit_scope_outside_repositories "$cwd" "$targets"; then
  exit 0
fi

# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin_root/.agents/lib/verdict-audit-state.sh" || deny 'state library unavailable'
# shellcheck source=../lib/reply-summary.sh
source "$plugin_root/.agents/lib/reply-summary.sh" || deny 'writing checks unavailable'
# shellcheck source=../lib/concise-writing.sh
source "$plugin_root/.agents/lib/concise-writing.sh" || deny 'summary check unavailable'
# shellcheck source=../lib/design-doc.sh
source "$plugin_root/.agents/lib/design-doc.sh" || deny 'document verifier unavailable'
status=0
request="$(design_doc_binding edit "$cwd")" || status=$?
(( status != 0 )) || exit 0
# shellcheck source=../lib/subagent.sh
source "$plugin_root/.agents/lib/subagent.sh" || deny 'prompt loader unavailable'
if (( status != 3 )); then
  instruction="$(subagent_prompt design/design-required "$plugin_root" "plugin_root=$plugin_root")" \
    || deny 'design instruction unavailable'
  deny "$instruction"
fi
# The design is bound and readable, but no research PASS matches its content yet.
if ! task_input="$(jq -c '{repo_root, design_url, content_sha256}' <<<"$request")" \
   || ! findings="$(jq -r '.findings[] | "- " + .' <<<"$request")"; then
  deny 'research request unreadable'
fi
if ! criteria="$(subagent_prompt audit/design-research-criteria "$plugin_root" "plugin_root=$plugin_root")" \
   || ! task="$(subagent_prompt audit/design-research-task "$plugin_root" \
     "audit_criteria=$criteria" "task_input_json=$task_input")" \
   || ! instruction="$(subagent_instruction --agent design-research-auditor --root "$plugin_root" \
     --description 'Design research audit' --task "$task")"; then
  deny 'research audit instruction unavailable'
fi
if [[ -n "$findings" ]]; then
  message="$(subagent_prompt design/research-failed "$plugin_root" \
    "findings=$findings" "instruction=$instruction")"
else
  message="$(subagent_prompt design/research-required "$plugin_root" "instruction=$instruction")"
fi || deny 'research instruction unavailable'
deny "$message"
