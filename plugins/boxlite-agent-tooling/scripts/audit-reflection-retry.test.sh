#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$plugin/scripts/audit-reflection.sh"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/scripts/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
state="$scratch/cycle.json"
context='{"repo_root":"/fixture","session":"s","epoch":"1","branch":"main","gate":"verdict"}'
prepare() { jq -nc --argjson context "$context" --arg id "$1" \
  '{context:$context,attempt:{id:$id,binding:{head:$id},snapshot:{diff:"candidate"}}}' \
  | bash "$cli" prepare "$state"; }
outcome() { jq -nc --argjson context "$context" --arg id "$1" --arg verdict "$2" \
  '{context:$context,id:$id,outcome:{verdict:$verdict,evidence:"observed runner output"}}'; }
record() { bash "$cli" record "$state"; }
for id in a1 a2; do
  prepare "$id" >/dev/null
  outcome "$id" ERROR | record >/dev/null
done
if prepare a3 >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: third attempt launched without reflection after two failed runs\n' >&2; exit 1
fi
[[ "$(cat "$scratch/err")" == *'reflection required'* ]]
jq -e '.attempts | length == 2' "$state" >/dev/null
reject() {
  local before
  before="$(cat "$state")"
  if printf '%s' "$2" | bash "$cli" "$1" "$state" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: invalid %s accepted\n' "$1" >&2; exit 1
  fi
  [[ -s "$scratch/err" && "$(cat "$state")" == "$before" ]]
}
for mutation in '.reflection.failure_ids=["a1"]' '.reflection.checks=[]' '.reflection.history_hash=("0"*64)'; do
  reject submit "$(audit_test_reflection "$state" | jq "$mutation")"
done
audit_test_reflection "$state" | bash "$cli" submit "$state" >/dev/null
prepare a3 >/dev/null
reject submit "$(audit_test_reflection "$state")"
reject record "$(outcome a3 PASS)"
assessment="$(audit_test_assessment "$state")"
reject record "$(outcome a3 PASS | jq --argjson assessment "$assessment" \
  '.outcome.reflection_review=($assessment | .assessment="insufficient")')"
outcome a3 ERROR | record >/dev/null
if prepare a4 >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: a new failure reused stale reflection\n' >&2; exit 1
fi
audit_test_reflection "$state" | bash "$cli" submit "$state" >/dev/null
prepare a4 >/dev/null
assessment="$(audit_test_assessment "$state")"
reject record "$(outcome a4 PASS | jq --argjson assessment "$assessment" \
  '.outcome.reflection_review=($assessment | .reflection_hash=("0"*64))')"
outcome a4 PASS | jq --argjson assessment "$assessment" '.outcome.reflection_review=$assessment' \
  | record >/dev/null
jq -e '.attempts[-1].outcome.verdict == "PASS"' "$state" >/dev/null
printf 'PASS: reflection threshold, coverage, freshness, execution assessment, and recovery\n'
