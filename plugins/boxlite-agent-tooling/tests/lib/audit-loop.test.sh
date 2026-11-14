#!/usr/bin/env bash
# Tests for .agents/lib/audit-loop.jq, the loop classifier shared by the design gate and the
# commit/push checkpoint (design #563).
#
# Run with:  bash tests/lib/audit-loop.test.sh
# Exits non-zero on any failure.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.agents/lib" && pwd)"
# shellcheck source=assert.sh
source "$LIB_DIR/../../tests/lib/assert.sh"

classify() {  # rounds JSON -> class, or "error" when the classifier rejects the input
  jq -r -L "$LIB_DIR" 'include "audit-loop"; audit_loop_class' <<<"$1" 2>/dev/null || printf 'error'
}
fail_round() {  # count [repeated] -> one FAIL round
  jq -nc --argjson count "$1" --argjson repeated "${2:-false}" '{verdict:"FAIL",count:$count,repeated:$repeated}'
}
error_round='{"verdict":"ERROR","count":0,"repeated":false}'
rounds() { local IFS=,; printf '[%s]' "$*"; }

echo "## Fewer than two comparable rounds have no class"
check_eq "no rounds"            "$(classify '[]')" none
check_eq "one FAIL"             "$(classify "$(rounds "$(fail_round 3)")")" none
check_eq "one ERROR"            "$(classify "$(rounds "$error_round")")" none
check_eq "a FAIL then an ERROR" "$(classify "$(rounds "$(fail_round 3)" "$error_round")")" none

echo "## The last two FAIL rounds decide the class"
check_eq "fewer findings converge" \
  "$(classify "$(rounds "$(fail_round 5)" "$(fail_round 3)")")" converging
check_eq "fewer findings converge even when one repeats" \
  "$(classify "$(rounds "$(fail_round 5)" "$(fail_round 3 true)")")" converging
check_eq "as many findings with a repeat stall" \
  "$(classify "$(rounds "$(fail_round 3)" "$(fail_round 3 true)")")" stalled
check_eq "more findings with a repeat stall" \
  "$(classify "$(rounds "$(fail_round 2)" "$(fail_round 4 true)")")" stalled
check_eq "as many findings, all new, churn" \
  "$(classify "$(rounds "$(fail_round 3)" "$(fail_round 3)")")" churning
check_eq "more findings, all new, churn" \
  "$(classify "$(rounds "$(fail_round 2)" "$(fail_round 3)")")" churning
check_eq "only the last two FAIL rounds count" \
  "$(classify "$(rounds "$(fail_round 2)" "$(fail_round 5)" "$(fail_round 4)")")" converging
check_eq "a loop that converged and then stopped shrinking stalls" \
  "$(classify "$(rounds "$(fail_round 5)" "$(fail_round 3)" "$(fail_round 3 true)")")" stalled

echo "## ERROR rounds"
check_eq "two ERROR rounds in a row are infra" \
  "$(classify "$(rounds "$(fail_round 3)" "$error_round" "$error_round")")" infra
check_eq "two ERROR rounds with no FAIL are infra" \
  "$(classify "$(rounds "$error_round" "$error_round")")" infra
check_eq "one ERROR between two FAIL rounds does not hide them" \
  "$(classify "$(rounds "$(fail_round 3)" "$error_round" "$(fail_round 3 true)")")" stalled
check_eq "a FAIL after two ERROR rounds ends infra" \
  "$(classify "$(rounds "$(fail_round 4)" "$error_round" "$error_round" "$(fail_round 2)")")" converging

echo "## Malformed rounds fail closed"
check_eq "a PASS round is rejected"      "$(classify '[{"verdict":"PASS","count":0,"repeated":false}]')" error
check_eq "a negative count is rejected"  "$(classify '[{"verdict":"FAIL","count":-1,"repeated":false}]')" error
check_eq "a missing field is rejected"   "$(classify '[{"verdict":"FAIL","count":1}]')" error
check_eq "a non-array input is rejected" "$(classify '{}')" error

echo "## History gates reduce attempts to rounds"
history_rounds() {  # attempts JSON -> rounds
  jq -c -L "$LIB_DIR" 'include "audit-loop"; {attempts:.} | audit_loop_history_rounds' <<<"$1"
}
review() {  # open IDs JSON, finding IDs JSON -> a FAIL outcome's history review
  jq -nc --argjson open "$1" --argjson findings "$2" '{outcome:{verdict:"FAIL",history_review:{
    dispositions:[$open[] | {id:., status:"open", evidence:"e"}], findings:[$findings[] | {id:.}]}}}'
}
check_eq "new findings count and do not repeat" \
  "$(history_rounds "[$(review '[]' '["NEW","NEW"]')]")" '[{"verdict":"FAIL","repeated":false,"count":2}]'
check_eq "an open registry ID is a repeat" \
  "$(history_rounds "[$(review '["F1"]' '["NEW"]')]")" '[{"verdict":"FAIL","repeated":true,"count":2}]'
check_eq "an ID both dispositioned and re-raised counts once" \
  "$(history_rounds "[$(review '["F1"]' '["F1"]')]")" '[{"verdict":"FAIL","repeated":true,"count":1}]'
check_eq "a resolved disposition is not counted" \
  "$(history_rounds '[{"outcome":{"verdict":"FAIL","history_review":{"dispositions":[{"id":"F1","status":"resolved","evidence":"e"}],"findings":[{"id":"NEW"}]}}}]')" \
  '[{"verdict":"FAIL","repeated":false,"count":1}]'
check_eq "ERROR, PASS and pending attempts" \
  "$(history_rounds '[{"outcome":{"verdict":"ERROR","evidence":{}}},{"outcome":{"verdict":"PASS"}},{"outcome":null}]')" \
  '[{"verdict":"ERROR","count":0,"repeated":false}]'

assert_result
