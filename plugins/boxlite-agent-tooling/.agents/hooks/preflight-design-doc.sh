#!/usr/bin/env bash
# Library subprocesses use their own request local; this hook captures the returned request.
# shellcheck disable=SC2031
# PreToolUse: before repository edits, require the current design, an independent
# audit verdict for its exact content, and advice on that verdict. Active auditors
# may write their assigned reports.
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
# shellcheck source=../lib/hook-host.sh
source "$plugin_root/.agents/lib/hook-host.sh" || deny 'hook payload library unavailable'
cwd="$(hook_payload_workdir "$payload" "${CLAUDE_PROJECT_DIR:-$PWD}")" \
  || deny 'invalid working directory'
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
# shellcheck source=../lib/audit-report-scope.sh
source "$plugin_root/.agents/lib/audit-report-scope.sh" || deny 'audit report scope unavailable'
if audit_report_write_allowed "$payload" "$cwd" "$targets" >/dev/null 2>&1; then
  exit 0
fi
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
# shellcheck source=../lib/user-question.sh
source "$plugin_root/.agents/lib/user-question.sh" || deny 'question library unavailable'
if (( status != 3 )); then
  instruction="$(subagent_prompt design/design-required "$plugin_root" "plugin_root=$plugin_root")" \
    || deny 'design instruction unavailable'
  deny "$instruction"
fi
# The design is bound and readable, but no audit PASS matches its content yet.
jq -e 'type == "object"' <<<"$request" >/dev/null 2>&1 || deny 'audit request unreadable'
[[ "$(jq -r '.running // false' <<<"$request")" != true ]] || deny 'The assigned design worker is running; wait for the current Bash action.'
listed() { jq -r --arg key "$1" '.[$key][] | "- " + .' <<<"$request"; }
session="$(jq -r '.session_id // "" | strings' <<<"$payload")" || session=''

# A stopped loop waits for a typed choice. Apply the recorded choice once.
design_decision() {
  local root decisions spec decision choice reason approval reply_format id
  # shellcheck source=../lib/timed-user-prompt.sh
  source "$plugin_root/.agents/lib/timed-user-prompt.sh" || deny 'design decision unavailable'
  root="$(jq -r .repo_root <<<"$request")"
  mkdir -p "$root/.agents/state" || deny 'design decision state unavailable'
  decisions="$root/.agents/state/design-decision-request.json"
  if ! spec="$(jq -c --arg session "$session" --arg head "$(git -C "$root" rev-parse HEAD 2>/dev/null)" \
      --arg branch "$(git -C "$root" branch --show-current 2>/dev/null)" \
      '{binding:{root:.repo_root, branch:$branch, head:$head, session:$session, url:.design_url,
        content_sha256, history_hash, fails, stop},
        prefix:"design-decision:", fallback:"keep-blocked"}' <<<"$request")"; then
    deny 'design decision unavailable'
  fi
  decision="$(timed_user_prompt request "$decisions" "$spec" 2>&1)" || deny "$decision"
  case "$(jq -r .status <<<"$decision")" in
    accepted)
      if ! choice="$(user_question design-choice "$plugin_root" "$decision")" \
         || ! design_doc_binding decide "$cwd" "$choice" >/dev/null \
         || ! timed_user_prompt consume "$decisions" "$(jq -r .id <<<"$decision")" >/dev/null; then
        deny 'the design decision could not be applied'
      fi
      status=0
      request="$(design_doc_binding edit "$cwd")" || status=$?
      (( status != 0 )) || exit 0
      (( status == 3 )) || deny 'audit request unreadable' ;;
    expired)
      approval="$(user_question redesign-approval "$plugin_root")" || deny 'redesign question unavailable'
      decision="$(user_question render "$plugin_root" design/audit-expired \
        "findings=$(listed open_findings)" "approval=$approval")" || deny 'redesign instruction unavailable'
      deny "$decision" ;;
    *)
      reason='the FAIL limit was reached'
      [[ "$(jq -r .stop <<<"$request")" == cap ]] || reason='a blocking finding repeated or their number did not drop'
      id="$(jq -er .id <<<"$decision")" || deny 'request id unavailable'
      if ! decision="$(user_question instruction "$plugin_root" "$decision")" \
         || ! reply_format="$(user_question design-format "$plugin_root" "$id")" \
         || ! decision="$(user_question render "$plugin_root" design/audit-stopped "reason=$reason" \
           "fails=$(jq -r .fails <<<"$request")" "findings=$(listed open_findings)" \
           "instruction=$decision" "reply_format=$reply_format")"; then
        deny 'audit instruction unavailable'
      fi
      deny "$decision" ;;
  esac
}
[[ "$(jq -r .blocked <<<"$request")" != true ]] || design_decision
if [[ "$(jq -r .redesign <<<"$request")" == true ]]; then
  approval="$(user_question redesign-approval "$plugin_root")" || deny 'redesign question unavailable'
  message="$(user_question render "$plugin_root" design/audit-redesign "approval=$approval")" \
    || deny 'redesign instruction unavailable'
  deny "$message"
fi
if [[ "$(jq -r .reflection_due <<<"$request")" == true ]]; then
  message="$(subagent_prompt design/audit-reflect "$plugin_root" "plugin_root=$plugin_root" \
    "history_hash=$(jq -r .history_hash <<<"$request")" "failure_ids=$(jq -c .failure_ids <<<"$request")" \
    "findings=$(listed open_findings)")" || deny 'audit instruction unavailable'
  deny "$message"
fi
# Result publication belongs to the fixed host-owned action, not native subagents.
instruction="$(subagent_prompt design/worker-required "$plugin_root" "plugin_root=$plugin_root")" \
  || deny 'design worker instruction unavailable'
if [[ "$(jq -r .advice_due <<<"$request")" == true ]]; then
  message="$(user_question render "$plugin_root" design/advice-required \
    "verdict=$(jq -r .verdict <<<"$request")" "advisories=$(listed advisories)" "instruction=$instruction")" \
    || deny 'advice instruction unavailable'
elif [[ -n "$(listed findings)" ]]; then
  message="$(subagent_prompt design/audit-failed "$plugin_root" "findings=$(listed findings)" \
    "advice=$(listed advice)" "instruction=$instruction")" || deny 'audit instruction unavailable'
else
  message="$(subagent_prompt design/audit-required "$plugin_root" "instruction=$instruction")" \
    || deny 'audit instruction unavailable'
fi
deny "$message"
