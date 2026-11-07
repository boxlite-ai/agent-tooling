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

start_prepared_task() { # generation; model the native Start before its Stop delivery
  local status=0
  [[ -e "$LINK" ]] || return 0
  [[ "$(jq -r '.host_agent_id // ""' "$LINK")" == "" ]] || return 0
  jq -nc --arg session "$SESSION" --arg generation "$1" \
    '{hook_event_name:"SubagentStart",session_id:$session,agent_id:$generation,
      agent_type:"boxlite-agent-tooling:commit-push-auditor"}' \
    | (cd "$R" && AUDITOR_PROMPT_AFTER_SECONDS=0 CLAUDE_PROJECT_DIR="$R" bash "$CONTROL") \
      >/dev/null 2>&1 || status=$?
  (( status == 0 || status == 2 )) || return 1
  jq -e --arg generation "$1" '.generation==$generation and .state=="running"' \
    "$R/.agents/state/auditor-control/active.$SCOPE.commit-push-auditor.json" >/dev/null
}

stop() {  # stop_hook_active
  local generation
  generation="auditor-$(jq -r .attempt_id "$LINK" 2>/dev/null || printf closed)"
  start_prepared_task "$generation" || return 1
  jq -nc --arg session "$SESSION" --argjson resumed "$1" --arg generation "$generation" \
    '{hook_event_name:"SubagentStop",session_id:$session,agent_id:$generation,
      agent_type:"boxlite-agent-tooling:commit-push-auditor",stop_hook_active:$resumed,
      last_assistant_message:"FAIL"}' \
    | (cd "$R" && env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$R" \
        bash "$CONTROL" 2>/dev/null)
}

# Codex names its native subagent "default" and identifies it through the subagent
# transcript's spawn metadata.
codex_stop() {  # stop_hook_active
  local generation
  generation="codex-auditor-$(jq -r .attempt_id "$LINK" 2>/dev/null || printf closed)"
  start_prepared_task "$generation" || return 1
  local transcript="$R/.agents/state/codex-auditor.jsonl"
  jq -nc --arg parent "$SESSION" --arg generation "$generation" \
    '{type:"session_meta",payload:{id:$generation,session_id:$parent,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$parent,depth:1,
        agent_path:"/root/commit_push_auditor",agent_nickname:"test",agent_role:null}}}}}' > "$transcript"
  jq -nc --arg session "$SESSION" --argjson resumed "$1" --arg transcript "$transcript" --arg generation "$generation" \
    '{hook_event_name:"SubagentStop",session_id:$session,agent_id:$generation,
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

stop_as_host() {  # host, stop_hook_active
  case "$1" in
    claude) stop "$2" ;;
    codex) codex_stop "$2" ;;
  esac
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
# The reason names the claim-checked task file (#407); the attempt id travels inside it.
task_files="$(grep -l -- "$id" "$R/.agents/state/audit-tasks/"*.md 2>/dev/null || true)"
if [[ -n "$id" && -n "$task_files" \
      && "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" == *"${task_files##*/}"* ]]; then
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

echo "SubagentStop blocks a dossier-less stop past the deadline once (design #328)"
use_session attempt-late
stage_change
preflight >/dev/null
jq -c '.deadline = 0' "$LINK" > "$LINK.tmp" && mv "$LINK.tmp" "$LINK"
late="$(stop false)"
check_eq "a first late stop without a dossier blocks" "$(jq -r .decision <<<"$late")" "block"
check_eq "the late block says record now" \
  "$(jq -r '.reason | startswith("Deadline passed: record your verdict now.")' <<<"$late")" "true"
stop true >/dev/null
check_eq "a resumed late stop without a dossier records ERROR" "$(attempts | sed 's/.*://')" "ERROR"

echo "SubagentStop records a bound dossier"
use_session attempt-pass
stage_change
preflight >/dev/null
write_dossier PASS '[]'
check_eq "a bound dossier does not block" "$(stop false | jq -r '.decision // "allow"')" "allow"
check_eq "SubagentStop records the dossier verdict" "$(attempts | sed 's/.*://')" "PASS"

for host in claude codex; do
  echo "SubagentStop preserves unchecked lifecycle decisions ($host)"
  for prefix in 'unchecked:' 'high: unchecked:'; do
    findings="$(jq -nc --arg prefix "$prefix" \
      '[$prefix + " design doc not read. Evidence: required read absent. Pass if: read the bound design."]')"
    use_session "attempt-$host-${prefix%%:*}-early"
    stage_change
    preflight >/dev/null
    write_dossier FAIL "$findings"
    check_eq "$host $prefix before deadline blocks" \
      "$(stop_as_host "$host" false | jq -r .decision)" "block"
    check_eq "$host $prefix early attempt stays open" "$(attempts | sed 's/.*://')" "open"
    check_eq "$host $prefix early link stays present" \
      "$([[ -e "$LINK" ]] && echo present || echo gone)" "present"
    check_eq "$host $prefix already-resumed stop allows" \
      "$(stop_as_host "$host" true | jq -r '.decision // "allow"')" "allow"
    check_eq "$host $prefix resumed attempt records FAIL" "$(attempts | sed 's/.*://')" "FAIL"
    check_eq "$host $prefix resumed link is removed" \
      "$([[ -e "$LINK" ]] && echo present || echo gone)" "gone"

    use_session "attempt-$host-${prefix%%:*}-late"
    stage_change
    preflight >/dev/null
    write_dossier FAIL "$findings"
    jq -c '.deadline = 0' "$LINK" > "$LINK.tmp" && mv "$LINK.tmp" "$LINK"
    check_eq "$host $prefix after deadline allows" \
      "$(stop_as_host "$host" false | jq -r '.decision // "allow"')" "allow"
    check_eq "$host $prefix late attempt records FAIL" "$(attempts | sed 's/.*://')" "FAIL"
    check_eq "$host $prefix late link is removed" \
      "$([[ -e "$LINK" ]] && echo present || echo gone)" "gone"
  done

  use_session "attempt-$host-ordinary-high"
  stage_change
  preflight >/dev/null
  write_dossier FAIL '["high: correctness: error text contains unchecked: literally. Evidence: reviewed path. Pass if: preserve the result."]'
  check_eq "$host ordinary high finding allows stop" \
    "$(stop_as_host "$host" false | jq -r '.decision // "allow"')" "allow"
  check_eq "$host ordinary high finding records FAIL" "$(attempts | sed 's/.*://')" "FAIL"
  check_eq "$host ordinary high finding removes link" \
    "$([[ -e "$LINK" ]] && echo present || echo gone)" "gone"
done

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
    "$(preflight | jq -r '.hookSpecificOutput.permissionDecisionReason | startswith("Next action: audit") and contains("Existing audit does not match current state:")')" "true"
done

for host in claude codex; do
  use_session "deadline-pass-$host"
  stage_change
  COMMIT_PUSH_AUDITOR_TIMEOUT=1 preflight >/dev/null || exit 1
  deadline="$(jq -r .deadline "$LINK")"
  COMMIT_PUSH_AUDITOR_TIMEOUT=900 preflight >/dev/null || exit 1
  check_eq "$host repeated preflight preserves deadline" "$(jq -r .deadline "$LINK")" "$deadline"
  perl -e 'my $wait=$ARGV[0]-time+1; sleep $wait if $wait>0' "$deadline"
  write_dossier PASS '[]'
  dossier="$R/.agents/state/last-audit.json"
  jq '.advisories=["low: unchecked at deadline: test execution; verify remaining receipts"] |
    .history_review.coverage |= {reviewed:[],unread:.reviewed}' "$dossier" >"$dossier.tmp"
  mv "$dossier.tmp" "$dossier"
  stop_as_host "$host" false >/dev/null
  check_eq "$host deadline PASS retains unread evidence and provenance" \
    "$(inspect_history | jq -r --argjson deadline "$deadline" '.state.attempts[-1].outcome |
      .verdict == "PASS" and .deadline_review.deadline == $deadline and
      (.history_review.coverage.unread | length) > 0')" true
  accepted="$(preflight)"
  check_eq "$host deadline PASS reaches the Git gate" \
    "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$accepted")" allow
  check_eq "$host deadline advisory remains visible" \
    "$([[ "$accepted" == *'unchecked at deadline'* ]] && echo yes || echo no)" yes
done

echo
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
