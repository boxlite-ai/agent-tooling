#!/usr/bin/env bash
# A referee result enters commit/push history once per stalled loop, retracts only with
# cited evidence, and never passes (design #563). Rounds go through the public CLI.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../audit/fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cli="$plugin/scripts/audit-reflection.sh"

select_loop() {  # gate, name
  state="$scratch/$2.json"
  context="$(jq -nc --arg gate "$1" --arg session "$2" \
    '{repo_root:"/fixture",session:$session,epoch:"1",branch:"main",gate:$gate}')"
}
prepare() {
  audit_test_submit_due "$cli" "$state"
  jq -nc --argjson context "$context" --arg id "$1" \
    '{context:$context,attempt:{id:$id,binding:{head:$id},snapshot:{diff:"candidate"},deadline:4102444800}}' \
    | bash "$cli" prepare "$state" >/dev/null
}
new_findings() {  # count
  jq -nc --argjson n "$1" '[range($n) | {id:"NEW",invariant:"invariant \(.)",behavior:"behavior \(.)",
    criterion:"criterion",evidence:"test output",origin:"existing",origin_evidence:"baseline",
    review_gap:"",review_change:"",reopening:null,conflict:null,criterion_change:null}]'
}
dispositions() {  # "F1:open:evidence words" ... -> dispositions
  local item; for item in "$@"; do
    jq -nc --arg id "${item%%:*}" --arg rest "${item#*:}" \
      '{id:$id,status:($rest | split(":")[0]),evidence:($rest | split(":")[1:] | join(":"))}'
  done | jq -cs .
}
outcome() {  # attempt id, verdict, dispositions JSON, findings JSON
  jq -nc --argjson context "$context" --arg id "$1" --arg verdict "$2" \
    --arg hash "$(jq -r .history_hash "$state")" --argjson dispositions "$3" --argjson findings "$4" \
    --argjson reflection "$(audit_test_assessment "$state")" \
    '{context:$context,id:$id,outcome:{verdict:$verdict,evidence:"audit dossier",history_review:{
      attempt_id:$id,history_hash:$hash,dispositions:$dispositions,findings:$findings,
      coverage:{reviewed:["diff"],unread:[]}},reflection_review:($reflection | .assessment=(if $verdict == "PASS" then "sufficient" else "insufficient" end))}}'
}
record() { bash "$cli" record "$state" >/dev/null 2>"$scratch/err"; }
accept() { outcome "$@" | record || { printf 'FAIL: rejected %s %s: %s\n' "$1" "$2" "$(cat "$scratch/err")" >&2; exit 1; }; }
refuse() {  # expected error text, then outcome arguments
  local expected="$1" before; shift
  before="$(cat "$state")"
  if outcome "$@" | record; then printf 'FAIL: accepted %s %s\n' "$1" "$2" >&2; exit 1; fi
  grep -Fq -- "$expected" "$scratch/err" || { printf 'FAIL: wrong error for %s: %s\n' "$1" "$(cat "$scratch/err")" >&2; exit 1; }
  [[ "$(cat "$state")" == "$before" ]]
}
class() { jq -r -L "$plugin/.agents/lib" 'include "audit-loop"; audit_loop_history_rounds | audit_loop_class' "$state"; }
due() { jq -r -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; audit_referee_due' "$state"; }
kept='F2:open:still fails at src/gate.sh:40'
retracted='F1:retracted:src/gate.sh:12 already holds the lock'

for gate in commit push; do
  select_loop "$gate" "$gate-stalled"
  prepare a1; accept a1 FAIL '[]' "$(new_findings 2)"
  [[ "$(due)" == false ]]
  prepare r0; refuse 'no referee is due' r0 REFEREE "$(dispositions "$retracted" "$kept")" '[]'
  accept r0 FAIL "$(dispositions 'F1:open:again' 'F2:open:again')" '[]'
  [[ "$(class):$(due)" == stalled:true ]]

  prepare r1
  refuse 'a retraction cites evidence' r1 REFEREE "$(dispositions 'F1:retracted:not a real problem' "$kept")" '[]'
  refuse 'upholds or retracts each open finding' r1 REFEREE "$(dispositions 'F1:resolved:fixed at src/gate.sh:12' "$kept")" '[]'
  refuse 'upholds or retracts each open finding' r1 REFEREE "$(dispositions "$retracted" "$kept")" "$(new_findings 1)"
  refuse 'dispositions must cover each open/not_assessed ID' r1 REFEREE "$(dispositions "$retracted")" '[]'
  accept r1 REFEREE "$(dispositions "$retracted" "$kept")" '[]'
  jq -e '[.registry[] | .status] == ["retracted","open"] and .attempts[-1].outcome.verdict == "REFEREE"' "$state" >/dev/null
  # Round two now counts the one upheld finding: 2 then 1 converges, and no second referee runs.
  [[ "$(class):$(due)" == converging:false ]]
  jq -e -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; audit_failure_ids | length == 2' "$state" >/dev/null

  prepare a3; accept a3 FAIL "$(dispositions 'F2:open:unchanged')" '[]'
  [[ "$(class):$(due)" == stalled:false ]]
  jq -e -L "$plugin/.agents/lib" 'include "audit-reflection-contract"; audit_git_decision_due' "$state" >/dev/null
  prepare r2 2>/dev/null && { printf 'FAIL: %s prepared past the human checkpoint\n' "$gate" >&2; exit 1; }

  select_loop "$gate" "$gate-all-retracted"
  prepare b1; accept b1 FAIL '[]' "$(new_findings 1)"
  prepare b2; accept b2 FAIL "$(dispositions 'F1:open:again')" '[]'
  prepare b3; accept b3 REFEREE "$(dispositions 'F1:retracted:`make test` exits 0 with the guard in place')" '[]'
  [[ "$(class)" == converging ]]
  jq -e '.attempts[-1].outcome.verdict != "PASS" and ([.registry[] | select(.status == "open")] | length) == 0' "$state" >/dev/null
  prepare b4; accept b4 PASS '[]' '[]'
done

select_loop verdict verdict-stalled
prepare v1; accept v1 FAIL '[]' "$(new_findings 1)"
prepare v2; accept v2 FAIL "$(dispositions 'F1:open:again')" '[]'
[[ "$(class):$(due)" == stalled:false ]]
prepare v3; refuse 'no referee is due' v3 REFEREE "$(dispositions 'F1:retracted:src/gate.sh:12 holds')" '[]'
printf 'PASS: a referee result records once per stalled commit/push loop, needs cited evidence, and never passes\n'
