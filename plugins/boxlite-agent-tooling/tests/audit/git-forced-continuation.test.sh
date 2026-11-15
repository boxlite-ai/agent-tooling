#!/usr/bin/env bash
# A stuck commit loop whose open findings are all high proceeds as UNRESOLVED and writes the
# ledger; a critical finding still reaches the human question (design #563). Every attempt
# and worker goes through the hooks that own them.
# shellcheck disable=SC2031 # Fixture scope/context stay in the parent; sourced libraries run in subshells.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.test
git -C "$repo" config user.name tester
git -C "$repo" config core.hooksPath /dev/null
printf '.agents/state/\n' > "$repo/.gitignore"
printf 'base\n' > "$repo/source"
git -C "$repo" add -A
git -C "$repo" commit -qm base
mkdir -p "$repo/.agents/state"
export CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$plugin"
unset PLUGIN_ROOT CODEX_SANDBOX CLAUDECODE AGENT_GATED GITHOOK_DELEGATED GITHOOK_KEEP_AUDIT AUDIT_REFEREE_ROUTE
hook="$plugin/.agents/hooks/preflight-commit-push.sh"
control="$plugin/.agents/hooks/auditor-control.sh"
command='git commit -m "test: forced continuation"'
pass=0 fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf 'PASS: %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL: %s (got=%s expected=%s)\n' "$1" "$2" "$3"
  fi
}
session() {
  session_id="$1"
  scope="git-$(printf '%s' "$session_id" | git -C "$repo" hash-object --stdin)"
  printf '901-902-1\n' > "$repo/.agents/state/verdict-prompt-epoch.$scope"
  context="$(jq -nc --arg root "$(cd "$repo" && pwd -P)" --arg scope "$scope" \
    --arg branch "$(git -C "$repo" branch --show-current)" \
    '{repo_root:$root,session:$scope,epoch:"901-902-1",branch:$branch,gate:"commit"}')"
  link="$repo/.agents/state/auditor-control/audit-task.$scope.commit-push-auditor.json"
  rm -f "$repo/.agents/state/last-audit.json"
  printf 'change\n' >> "$repo/source"
  git -C "$repo" add source
}
gate() {
  jq -nc --arg session "$session_id" --arg command "$command" \
    '{session_id:$session,tool_input:{command:$command}}' \
    | (cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
      GIT_CONFIG_VALUE_0='' bash "$hook")
}
history() {
  (
    # shellcheck source=../../.agents/lib/verdict-audit-state.sh
    source "$plugin/.agents/lib/verdict-audit-state.sh"
    # shellcheck source=../../.agents/lib/audit-reflection.sh
    source "$plugin/.agents/lib/audit-reflection.sh"
    # shellcheck source=../../.agents/lib/audit-reflection-gate.sh
    source "$plugin/.agents/lib/audit-reflection-gate.sh"
    audit_reflection_gate "$context" inspect
  )
}
lifecycle() { # event generation
  local status=0
  jq -nc --arg event "$1" --arg generation "$2" --arg session "$session_id" \
    '{hook_event_name:$event,session_id:$session,agent_id:$generation,
      agent_type:"boxlite-agent-tooling:commit-push-auditor",stop_hook_active:false,
      last_assistant_message:"done"}' \
    | (cd "$repo" && AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$control") || status=$?
  [[ "$1" == SubagentStart && "$status" == 2 ]] || return "$status"
}
dossier() { # verdict, findings JSON, advisories JSON, optional jq edit of the bound dossier
  local input="" candidate id
  id="$(jq -r .attempt_id "$link")"
  for candidate in "$repo"/.agents/state/audit-input-*.json; do
    if jq -e --arg id "$id" '.attempts[-1].id==$id' "$candidate" >/dev/null; then input="$candidate"; break; fi
  done
  [[ -n "$input" ]]
  jq -nc --arg verdict "$1" --argjson findings "$2" --argjson advisories "$3" \
    '{verdict:$verdict,findings:$findings,advisories:$advisories,commit_subject_hash:""}' \
    > "$repo/.agents/state/last-audit.json"
  bash "$plugin/tests/audit/fixtures/audit-history-result.sh" \
    "$(jq -nc --arg path "$input" '{history_path:$path}')" "$repo/.agents/state/last-audit.json" bind
  if [[ -n "${4:-}" ]]; then
    jq -c "$4" "$repo/.agents/state/last-audit.json" > "$scratch/dossier" && mv "$scratch/dossier" "$repo/.agents/state/last-audit.json"
  fi
}
round() { # worker id, dossier arguments: one audited attempt through Start and Stop
  local worker="$1"; shift
  lifecycle SubagentStart "$worker" >/dev/null
  dossier "$@"
  lifecycle SubagentStop "$worker" >/dev/null
}
action() { jq -r '.hookSpecificOutput.permissionDecisionReason | split("\n")[0]' <<<"$1"; }
task_text() { # gate output -> the task behind its claim check
  local path
  path="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$1" \
    | grep -oE '/[^ "\\]*/audit-tasks/[0-9a-f]{64}\.md' | tail -1)"
  cat "$path"
}
reflect() { audit_test_submit_due "$plugin/scripts/audit-reflection.sh" "$(history | jq -r .state_path)"; }
fail_finding='["high: test: missing evidence. Evidence: source:1. Pass if: evidence shown"]'

ledger="$repo/.agents/state/audit-ledger.jsonl"
high='.history_review.findings[]?.severity = "high"'
upheld='.history_review.dispositions[0] |= (.status="open" | .evidence="source:1 still lacks it") | del(.reflection_review)'
# Three FAILs with one repeated finding and a referee that upholds it: the loop is stuck.
stuck_loop() { # jq edit for the first round's finding severity
  out="$(gate)"
  round "worker-$session_id-1" FAIL "$fail_finding" '[]' "$1"
  gate >/dev/null
  round "worker-$session_id-2" FAIL "$fail_finding" '[]'
  reflect
  gate >/dev/null
  round "worker-$session_id-r" REFEREE '[]' '[]' "$upheld"
  reflect
  gate >/dev/null
  round "worker-$session_id-3" FAIL "$fail_finding" '[]'
  reflect
}

for host in claude codex; do
  export BOXLITE_HOOK_HOST="$host"
  rm -f "$ledger"
  session "forced-$host"
  stuck_loop "$high"
  check "$host: a stuck loop with only high findings is due to continue" \
    "$(history | jq -r -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; .state | audit_forced_continuation_due')" true
  out="$(gate)"
  check "$host: the commit proceeds, marked UNRESOLVED, without a PASS" \
    "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$out"):$(jq -r '.hookSpecificOutput.additionalContext | startswith("UNRESOLVED: commit proceeds")' <<<"$out")" \
    'none:true'
  check "$host: the ledger holds the open high finding for that attempt" \
    "$(jq -sc --arg id "$(history | jq -r '.state.attempts[-1].id')" \
      '[length, .[0].attempt_id == $id, (.[0].findings | map(.severity))]' "$ledger")" '[1,true,["high"]]'
  check "$host: the history records no PASS" \
    "$(history | jq -r '[.state.attempts[].outcome.verdict] | index("PASS") == null')" true
  check "$host: the FAIL dossier was consumed" "$([[ -e "$repo/.agents/state/last-audit.json" ]] && echo kept || echo consumed)" consumed

  session "critical-$host"
  stuck_loop '.'
  check "$host: a missing severity counts as critical and is not forced" \
    "$(history | jq -r -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; .state | audit_forced_continuation_due')" false
  out="$(gate)"
  check "$host: a stuck loop with a critical finding still asks the human" \
    "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"):$(action "$out")" 'deny:Next action: wait'
  check "$host: nothing is written to the ledger for it" \
    "$(jq -s --arg s "$scope" 'length' "$ledger")" 1
done

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
