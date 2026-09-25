#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/scripts/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
git config user.email test@example.test
git config user.name tester
printf '.agents/state/\n' > .gitignore
git add .gitignore
git -c core.hooksPath=/dev/null commit -qm base
export CLAUDE_PROJECT_DIR="$PWD"
export VERDICT_AUDITOR_CMD="bash $plugin/scripts/fixtures/audit-history-auditor.sh"
export VERDICT_CLASSIFIER_CMD=false
run() {
  jq -nc --arg text "All tests passed. Revision $1." \
    '{session_id:"history-session",last_assistant_message:$text,stop_hook_active:false}' \
    | bash "$plugin/.agents/hooks/preflight-verdict-check.sh"
}
run 1 > first
jq -e '.decision == "block" and (.reason | contains("proof absent"))' first >/dev/null
run 2 > second
jq -e '.decision == "block" and (.reason | contains("proof absent"))' second >/dev/null
run 3 > third
if [[ "$(wc -l < .agents/state/model-runs | tr -d ' ')" != 2 ]]; then
  printf 'FAIL: third full audit launched without reflection\n' >&2; exit 1
fi
jq -e '.decision == "block" and (.reason | contains("reflection"))' third >/dev/null
state="$(printf '%s\n' "$PWD"/.agents/state/audit-history-*.json)"
jq -e '(.attempts | length) == 2 and (.registry | length) == 1 and .registry[0].id == "F1"' "$state" >/dev/null
audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
TEST_HISTORY_VERDICT=PASS run 4 > fourth
if [[ -s fourth ]]; then jq -e '.decision != "block"' fourth >/dev/null; fi
jq -e '.attempts[-1].outcome.verdict == "PASS" and .registry[0].status == "resolved"' "$state" >/dev/null
[[ "$(wc -l < .agents/state/model-runs | tr -d ' ')" == 3 ]]
printf 'PASS: real Stop runner blocks repeated failure, carries F1, and resumes after reflection\n'
context="$(jq -c .context "$state")"
history_cli="$plugin/scripts/audit-reflection-gate.sh"
for attempt in 1 2 3 4 5 6 7 8; do
  if (( attempt >= 3 )); then
    audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
  fi
  printf '{"binding":{"head":"fixture"},"snapshot":{"diff":"unchanged"}}' \
    | bash "$history_cli" "$context" prepare "budget-$attempt" >/dev/null
  printf '"transport unavailable"' | bash "$history_cli" "$context" error "budget-$attempt" >/dev/null
done
jq -nc '{session_id:"history-session",last_assistant_message:"## TL;DR\n\nAll tests passed.",stop_hook_active:false}' \
  | bash "$plugin/.agents/hooks/stop-gate.sh" > exhausted
if ! jq -e '.continue == false and (.stopReason | contains("INCOMPLETE"))' exhausted >/dev/null; then
  printf 'FAIL: exhausted audit budget did not terminate the Stop loop as incomplete\n' >&2; exit 1
fi
[[ "$(wc -l < .agents/state/model-runs | tr -d ' ')" == 3 ]]
jq -e '.attempts[-1].outcome.verdict == "ERROR"' "$state" >/dev/null
printf 'PASS: budget exhaustion terminates Stop without another auditor or fabricated PASS\n'
