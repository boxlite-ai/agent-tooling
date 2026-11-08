#!/usr/bin/env bash
# PreToolUse: verify the current design, an independent audit verdict for its exact
# content, and advice on that verdict (design #335), before repository edits except
# active auditors writing their assigned reports (#403).
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
# After any #309 stop, a recorded PASS or FAIL waits for one fresh advisor run, before
# findings are shown. Advice never changes the verdict (design #335).
if [[ "$(jq -r .advice_due <<<"$request")" == true ]]; then
  advice_input="$(jq -c '{repo_root, design_url, content_sha256, verdict, findings, advisories}' \
    <<<"$request")" || deny 'advice request unreadable'
  advice_deadline="$(design_doc_advice_task "$(jq -r .repo_root <<<"$request")" \
    "$(jq -r .design_url <<<"$request")" "$(jq -r .content_sha256 <<<"$request")")" \
    || deny 'design advice deadline unavailable'
  advisories="$(listed advisories)" || deny 'advice request unreadable'
  if ! privacy="$(subagent_prompt audit/probe-privacy "$plugin_root")" \
     || ! task="$(subagent_prompt audit/design-advice-task "$plugin_root" "plugin_root=$plugin_root" \
       "probe_rules=$privacy" "deadline=$advice_deadline" "task_input_json=$advice_input")" \
     || ! instruction="$(subagent_instruction --agent design-advisor --root "$plugin_root" \
       --description 'Design advice' --task "$task")" \
     || ! message="$(user_question render "$plugin_root" design/advice-required \
       "verdict=$(jq -r .verdict <<<"$request")" "advisories=${advisories:-- none}" \
       "instruction=$instruction")"; then
    deny 'design advice instruction unavailable'
  fi
  deny "$message"
fi
if ! task_input="$(jq -c '{repo_root, design_url, content_sha256}
       + (if (.prior_findings | length) > 0 then {prior_findings} else {} end)' <<<"$request")" \
   || ! findings="$(listed findings)"; then
  deny 'audit request unreadable'
fi
# The task states the deadline that audit-deadline.sh enforces (#328).
deadline="$(design_doc_audit_task "$(jq -r .repo_root <<<"$request")" \
  "$(jq -r .design_url <<<"$request")" "$(jq -r .content_sha256 <<<"$request")")" \
  || deny 'design audit deadline unavailable'
# The outline checks sit beside the criteria, which keep their 2,048-byte cap (design #335);
# the probe rule rides in the task too, because Codex receives the spec only by path (#327).
if ! criteria="$(subagent_prompt audit/design-criteria "$plugin_root" "plugin_root=$plugin_root")" \
   || ! outline="$(subagent_prompt audit/design-outline "$plugin_root")" \
   || ! privacy="$(subagent_prompt audit/probe-privacy "$plugin_root")" \
   || ! deadline_policy="$(subagent_prompt audit/deadline-policy "$plugin_root")" \
   || ! task="$(subagent_prompt audit/design-task "$plugin_root" \
     "audit_criteria=$criteria"$'\n\n'"$outline"$'\n\n'"$privacy"$'\n\n'"$deadline_policy" "deadline=$deadline" \
     "task_input_json=$task_input")" \
   || ! instruction="$(subagent_instruction --agent design-auditor --root "$plugin_root" \
     --description 'Design audit' --task "$task")"; then
  deny 'design audit instruction unavailable'
fi
if [[ -n "$findings" ]]; then
  advice="$(listed advice)" || deny 'audit request unreadable'
  message="$(subagent_prompt design/audit-failed "$plugin_root" \
    "findings=$findings" "advice=${advice:-- none}" "instruction=$instruction")"
else
  message="$(subagent_prompt design/audit-required "$plugin_root" "instruction=$instruction")"
fi || deny 'audit instruction unavailable'
deny "$message"
