#!/usr/bin/env bash
# The commit gate requests a referee for a stalled loop, records its result without
# treating it as a verdict, and returns to ordinary audits (design #563). Every attempt
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
command='git commit -m "test: referee"'
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

for host in claude codex; do
  export BOXLITE_HOOK_HOST="$host"
  session "referee-$host"
  out="$(gate)"
  check "$host: the first audit is an ordinary task" \
    "$(action "$out"):$(task_text "$out" | grep -c '^Referee:' || true)" 'Next action: audit:0'
  round worker-a FAIL "$fail_finding" '[]'
  out="$(gate)"
  round worker-b FAIL "$fail_finding" '[]'
  check "$host: two rounds with the same finding stall" \
    "$(history | jq -r -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; .state | audit_referee_due')" true
  check "$host: a stalled loop first needs its reflection" "$(action "$(gate)")" 'Next action: reflect'
  reflect
  out="$(gate)"
  task="$(task_text "$out")"
  check "$host: the next request is a referee task naming the open finding" \
    "$(action "$out"):$(grep -c '^Referee: recheck the listed findings only' <<<"$task"):$(grep -c '"id":"F1"' <<<"$task")" \
    'Next action: audit:1:1'
  check "$host: the referee task carries no audit criteria and forbids reading the reflection" \
    "$(grep -c '^## Review' <<<"$task" || true):$(grep -c '^- Read no reflection' <<<"$task")" 0:1

  round worker-c REFEREE '[]' '["F1 retracted: source:1 already shows the evidence"]' \
    '.history_review.dispositions[0] |= (.status="retracted" | .evidence="source:1 already shows the evidence") | del(.reflection_review)'
  check "$host: the referee result is recorded, and is no failed round" \
    "$(history | jq -c '[.state.attempts[-1].outcome.verdict, (.state.registry | map(.status)),
      ([.state.attempts[] | select(.outcome.verdict == "FAIL")] | length)]')" '["REFEREE",["retracted"],2]'
  out="$(gate)"
  check "$host: a referee result never lets the commit through" \
    "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out"):$(action "$out")" 'deny:Next action: reflect'
  reflect
  out="$(gate)"
  check "$host: the audit after the referee is ordinary again" \
    "$(action "$out"):$(task_text "$out" | grep -c '^Referee:' || true)" 'Next action: audit:0'
  round worker-d PASS '[]' '[]'
  check "$host: only the ordinary audit passes the commit" "$(gate)" ''
done

# The stubs above write the dossier; the shipped agent spec must also accept the task they stand in for.
spec="$plugin/.claude/agents/commit-push-auditor.md"
check "the auditor spec lets a Referee task replace the review and verdict steps" \
  "$(grep -c 'except a `Referee` task, whose rules replace steps 3–6 and the verdict' "$spec"):$(grep -c '^Referee: ' "$plugin/.agents/prompts/audit/commit-push-referee.md")" 1:1

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
