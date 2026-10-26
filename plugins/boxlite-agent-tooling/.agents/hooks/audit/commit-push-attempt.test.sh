#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Contract tests for the hook-owned commit/push attempt: the preflight prepares it and
# the Claude SubagentStop hook closes it, recorded from a bound dossier or as ERROR.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/preflight-commit-push.sh"
CONTROL="$REPO_ROOT/.agents/hooks/auditor-control.sh"
FIXTURE="$REPO_ROOT/scripts/fixtures/audit-history-result.sh"
# shellcheck source=../../../scripts/fixtures/audit-reflection-fixture.sh
source "$REPO_ROOT/scripts/fixtures/audit-reflection-fixture.sh"
unset CODEX_SANDBOX CLAUDECODE AGENT_GATED GITHOOK_DELEGATED GITHOOK_KEEP_AUDIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got=$2 want=$3)"; fi
}

R="$(mktemp -d)"
trap 'rm -rf "$R"' EXIT
git -C "$R" init -q
git -C "$R" config user.email t@t.test
git -C "$R" config user.name tester
printf '.agents/state/\n' > "$R/.gitignore"
printf 'x\n' > "$R/f"
git -C "$R" add -A
git -C "$R" commit -qm base
mkdir -p "$R/.agents/state"
COMMAND='git commit -m "fix: change"'

# Each case group gets its own session, so failures in one never trigger another's
# reflection requirement.
use_session() {  # session name
  SESSION="$1"
  SCOPE="git-$(printf '%s' "$SESSION" | git -C "$R" hash-object --stdin)"
  printf '%s\n' 901-902-1 > "$R/.agents/state/verdict-prompt-epoch.$SCOPE"
  CONTEXT="$(jq -nc --arg root "$(cd "$R" && pwd -P)" --arg session "$SCOPE" \
    --arg branch "$(git -C "$R" branch --show-current)" \
    '{repo_root:$root,session:$session,epoch:"901-902-1",branch:$branch,gate:"commit"}')"
  LINK="$R/.agents/state/auditor-control/audit-task.$SCOPE.commit-push-auditor.json"
  rm -f "$R/.agents/state/last-audit.json"
}

stage_change() {
  printf 'y\n' >> "$R/f"
  git -C "$R" add -A
}

preflight() {
  jq -nc --arg command "$COMMAND" --arg session "$SESSION" \
    '{session_id:$session,tool_input:{command:$command}}' \
    | (cd "$R" && env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$R" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='' bash "$HOOK")
}

stop() {  # stop_hook_active
  jq -nc --arg session "$SESSION" --argjson resumed "$1" \
    '{hook_event_name:"SubagentStop",session_id:$session,agent_id:"auditor-1",
      agent_type:"boxlite-agent-tooling:commit-push-auditor",stop_hook_active:$resumed,
      last_assistant_message:"FAIL"}' \
    | (cd "$R" && env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$R" \
        bash "$CONTROL" 2>/dev/null)
}

# Codex names its native subagent "default" and identifies it through the subagent
# transcript's spawn metadata.
codex_stop() {  # stop_hook_active
  local transcript="$R/.agents/state/codex-auditor.jsonl"
  jq -nc --arg parent "$SESSION" \
    '{type:"session_meta",payload:{id:"codex-auditor-1",session_id:$parent,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$parent,depth:1,
        agent_path:"/root/commit_push_auditor",agent_nickname:"test",agent_role:null}}}}}' > "$transcript"
  jq -nc --arg session "$SESSION" --argjson resumed "$1" --arg transcript "$transcript" \
    '{hook_event_name:"SubagentStop",session_id:$session,agent_id:"codex-auditor-1",
      agent_type:"default",agent_transcript_path:$transcript,stop_hook_active:$resumed,
      last_assistant_message:"FAIL"}' \
    | (cd "$R" && env -u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$R" \
        bash "$CONTROL" 2>/dev/null)
}

inspect_history() {
  (
    # shellcheck source=../../lib/verdict-audit-state.sh
    source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
    # shellcheck source=../../lib/audit-reflection.sh
    source "$REPO_ROOT/.agents/lib/audit-reflection.sh"
    # shellcheck source=../../lib/audit-reflection-gate.sh
    source "$REPO_ROOT/.agents/lib/audit-reflection-gate.sh"
    audit_reflection_gate "$CONTEXT" inspect
  )
}

attempts() {  # -> "id:verdict" per attempt
  inspect_history | jq -r '[.state.attempts[] | "\(.id):\(.outcome.verdict // "open")"] | join(" ")'
}

# Write a dossier bound to the prepared attempt: verdict, findings, binding, history review.
write_dossier() {  # verdict findings-json
  local input="$R/.agents/state/last-audit.json" history
  # shellcheck disable=SC2012  # fixture names are hex; newest is the prepared input
  history="$(ls -t "$R"/.agents/state/audit-input-*.json | head -1)"
  jq -nc --arg verdict "$1" --argjson findings "$2" \
    '{verdict:$verdict,findings:$findings,advisories:[],commit_subject_hash:""}' > "$input"
  bash "$FIXTURE" "$(jq -nc --arg path "$history" '{history_path:$path}')" "$input" bind
}

echo "Preflight prepares one attempt per binding"
use_session attempt-prepare
stage_change
out="$(preflight)"
first="$(attempts)"
check_eq "deny prepares one open attempt" "$(awk '{print NF}' <<<"$first"):${first##*:}" "1:open"
id="${first%%:*}"
if [[ -n "$id" && "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" == *"$id"* ]]; then
  ok "the auditor instruction carries the attempt id"
else
  bad "the auditor instruction omits the attempt id"
fi
check_eq "the link names the attempt and a future deadline" \
  "$(jq -r --argjson now "$(date +%s)" '"\(.attempt_id) \(.deadline > $now)"' "$LINK")" "$id true"
preflight >/dev/null
check_eq "a repeated deny reuses the open attempt" "$(attempts)" "$id:open"
stage_change
preflight >/dev/null
second="$(attempts)"
check_eq "a changed binding cancels the stale attempt" "${second%% *}" "$id:CANCELED"
check_eq "a changed binding opens a new attempt" "${second##*:}" "open"

echo "SubagentStop blocks once without a dossier, then records ERROR"
use_session attempt-missing
stage_change
preflight >/dev/null
check_eq "a first stop without a dossier blocks" "$(stop false | jq -r .decision)" "block"
check_eq "a blocked stop leaves the attempt open" "$(attempts | sed 's/.*://')" "open"
stop true >/dev/null
check_eq "a resumed stop without a dossier records ERROR" "$(attempts | sed 's/.*://')" "ERROR"
check_eq "a closed attempt removes its link" "$([[ -e "$LINK" ]] && echo present || echo gone)" "gone"

echo "SubagentStop records a bound dossier"
use_session attempt-pass
stage_change
preflight >/dev/null
write_dossier PASS '[]'
check_eq "a bound dossier does not block" "$(stop false | jq -r '.decision // "allow"')" "allow"
check_eq "SubagentStop records the dossier verdict" "$(attempts | sed 's/.*://')" "PASS"

echo "SubagentStop resumes an early unchecked finding"
use_session attempt-unchecked
stage_change
preflight >/dev/null
write_dossier FAIL '["unchecked: design doc not read"]'
check_eq "an unchecked finding before the deadline blocks" "$(stop false | jq -r .decision)" "block"
jq -c '.deadline = 0' "$LINK" > "$LINK.tmp" && mv "$LINK.tmp" "$LINK"
stop false >/dev/null
check_eq "an unchecked finding after the deadline is recorded" "$(attempts | sed 's/.*://')" "FAIL"

echo "Codex SubagentStop closes the attempt the same way"
use_session attempt-codex
stage_change
preflight >/dev/null
check_eq "a first Codex stop without a dossier blocks" "$(codex_stop false | jq -r .decision)" "block"
codex_stop true >/dev/null
check_eq "a resumed Codex stop without a dossier records ERROR" "$(attempts | sed 's/.*://')" "ERROR"

for host in claude codex; do
  echo "Recorded retry PASS permits the identical commit ($host)"
  use_session "attempt-retry-$host"
  for (( round=1; round<=2; round++ )); do
    stage_change
    preflight >/dev/null || exit 1
    write_dossier FAIL '["test: missing evidence"]' || exit 1
    if [[ "$host" == codex ]]; then codex_stop false; else stop false; fi >/dev/null
  done
  history="$(inspect_history)"
  state="$(jq -r .state_path <<<"$history")"
  check_eq "$host requires reflection after two failures" \
    "$(jq -r '.reflection_due' <<<"$history")" "true"
  audit_test_reflection "$state" | bash "$REPO_ROOT/scripts/audit-reflection.sh" submit "$state" >/dev/null || exit 1
  reflection="$(jq -c .reflection "$state")"
  stage_change
  preflight >/dev/null || exit 1
  write_dossier PASS '[]' || exit 1
  cp "$R/.agents/state/last-audit.json" "$R/.agents/state/retry-pass-$host.json"
  if [[ "$host" == codex ]]; then codex_stop false; else stop false; fi >/dev/null
  history="$(inspect_history)"
  check_eq "$host records both failures and the assessed PASS" \
    "$(jq -c '[.state.attempts[].outcome.verdict]' <<<"$history")" '["FAIL","FAIL","PASS"]'
  check_eq "$host requires sufficient reflection assessment" \
    "$(jq -r '.state.attempts[-1].outcome.reflection_review.assessment' <<<"$history")" "sufficient"
  check_eq "$host preserves the reflection after PASS" "$(jq -c '.state.reflection' <<<"$history")" "$reflection"
  check_eq "$host advances history when PASS is recorded" \
    "$(jq -r '.state.history_hash != .state.reflection.body.history_hash' <<<"$history")" "true"
  check_eq "$host terminal PASS needs no new reflection" "$(jq -r .reflection_due <<<"$history")" "false"
  check_eq "$host identical retry is accepted" "$(preflight)" ""
  check_eq "$host consumes the matching approval" \
    "$([[ -e "$R/.agents/state/last-audit.json" ]] && echo present || echo gone)" "gone"
  check_eq "$host cannot reuse the consumed approval" \
    "$(preflight | jq -r .hookSpecificOutput.permissionDecision)" "deny"
  stage_change
  cp "$R/.agents/state/retry-pass-$host.json" "$R/.agents/state/last-audit.json"
  check_eq "$host changed staged diff rejects the old PASS" \
    "$(preflight | jq -r '.hookSpecificOutput.permissionDecisionReason | startswith("Existing audit does not match current state:")')" "true"
done

echo
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
