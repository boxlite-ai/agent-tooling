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
prepare() { audit_test_submit_due "$cli" "$state"; jq -nc --argjson context "$context" --arg id "$1" \
  '{context:$context,attempt:{id:$id,binding:{head:$id},snapshot:{diff:"reviewed bytes"}}}' \
  | bash "$cli" prepare "$state" >/dev/null; }
finding='{"id":"NEW","invariant":"publication is serialized","behavior":"late writer","criterion":"both event orderings pass","evidence":"test:publication", "origin":"existing","origin_evidence":"baseline:publication","review_gap":"","review_change":"","reopening":null,"conflict":null,"criterion_change":null}'
disposition() { jq -nc --arg id "$1" --arg status "$2" \
  '[{id:$id,status:$status,evidence:"verified current test output"}]'; }
result() {
  jq -nc --argjson context "$context" --arg id "$1" --arg verdict "$2" \
    --arg hash "$(jq -r .history_hash "$state")" --argjson dispositions "$3" --argjson findings "$4" \
    --argjson reflection "$(audit_test_assessment "$state")" \
    '{context:$context,id:$id,outcome:{verdict:$verdict,evidence:"audit dossier",history_review:{
      attempt_id:$id,history_hash:$hash,dispositions:$dispositions,findings:$findings,coverage:{reviewed:["diff"],unread:[]}},
      reflection_review:$reflection}}'
}
record() { printf '%s' "$1" | bash "$cli" record "$state"; }
reject() {
  local before
  before="$(cat "$state")"
  if record "$1" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: invalid reconciliation accepted\n' >&2; exit 1
  fi
  [[ -s "$scratch/err" && "$(cat "$state")" == "$before" ]]
}
expect() { jq -e "$1" "$state" >/dev/null || { printf 'FAIL: %s\n' "$1" >&2; exit 1; }; }

prepare a1
record "$(result a1 FAIL '[]' "[$finding]")" >/dev/null
expect '.registry[0].id == "F1" and .registry[0].status == "open"'
# Compare the schema's ID leaves with the production predicates. Include the ID
# allocated by record, not only IDs invented by this test.
schema="$plugin/.agents/hooks/audit/commit-push-audit.schema.json"
jq -ne -L "$plugin/.agents/lib" --slurpfile schema "$schema" --slurpfile cycle "$state" \
  --argjson finding "$finding" '
  include "audit-reconciliation";
  def accepts($rule; $id):
    (if $rule["$ref"] then
      $schema[0] | getpath($rule["$ref"] | ltrimstr("#/") | split("/"))
     else $rule end) as $leaf |
    ($id | type) == $leaf.type and
    ($id | test($leaf.pattern // ".*"));
  $schema[0]["$defs"] as $defs |
  [$cycle[0].registry[0].id, "NEW", "F9", "F10", "F9999", "F0", "F01",
   "F10000", "F1-detail", "prefixF1", "", " ", "NEW-detail"] as $ids |
  [$ids[] as $id |
    {id:$id, field:"finding",
     schema:accepts($defs.finding.properties.id; $id),
     runtime:($finding | .id=$id | ar_finding)},
    {id:$id, field:"disposition",
     schema:accepts($defs.history.properties.dispositions.items.properties.id; $id),
     runtime:({id:$id,status:"open",evidence:"test"} | ar_disposition)},
    {id:$id, field:"conflict",
     schema:accepts($defs.conflict.properties.previous_id; $id),
     runtime:($finding | .conflict={previous_id:$id,evidence:"test",check:"test",decision:"test"} | ar_finding)} |
    select(.schema != .runtime)] as $mismatches |
  if $mismatches == [] then true
  else error("schema/runtime ID mismatch: " + ($mismatches | tojson)) end
' >/dev/null
prepare a2
coverage="$(jq -c '.attempts[-1].input.snapshot | keys' "$state")"
valid="$(result a2 PASS "$(disposition F1 resolved)" '[]' \
  | jq --argjson keys "$coverage" '.outcome.history_review.coverage={reviewed:$keys,unread:[]}')"
reject "$(jq '.outcome.history_review.coverage.reviewed=[]' <<<"$valid")"
reject "$(jq '.outcome.history_review.coverage.unread=.outcome.history_review.coverage.reviewed' <<<"$valid")"
reject "$(jq '.outcome.history_review.coverage.reviewed += ["invented"]' <<<"$valid")"
reject "$(result a2 PASS '[]' '[]')"
reject "$(result a2 PASS "$(disposition F1 not_assessed)" '[]')"
reject "$(result a2 PASS "$(disposition F1 resolved)" '[]' | jq '.outcome.history_review.history_hash=("0"*64)')"
reject "$(result a2 PASS "$(disposition F1 resolved)" '[]' | jq '.outcome.history_review.coverage={reviewed:[],unread:["diff"]}')"
reject "$(result a2 FAIL "$(disposition F1 open)" "[$finding]")"
changed="$(jq '.id="F1" | .criterion="prove cancellation and publication together"' <<<"$finding")"
reject "$(result a2 FAIL "$(disposition F1 open)" "[$changed]")"
missed="$(jq '.invariant="worker terminates" | .behavior="cleanup" | .origin="missed_earlier"' <<<"$finding")"
reject "$(result a2 FAIL "$(disposition F1 resolved)" "[$missed]")"
missed="$(jq '.review_gap="cleanup path not examined" | .review_change="trace teardown and in-flight work"' <<<"$missed")"
record "$(result a2 FAIL "$(disposition F1 resolved)" "[$missed]")" >/dev/null
expect '.registry[0].status == "resolved" and .registry[1].id == "F2"'
prepare a3
reopened="$(jq '.id="F1"' <<<"$finding")"
reject "$(result a3 FAIL "$(disposition F2 resolved)" "[$reopened]")"
reopened="$(jq '.reopening={reason:"lock removed by new change",evidence:"a3.diff and failing publication check"}' <<<"$reopened")"
record "$(result a3 FAIL "$(disposition F2 resolved)" "[$reopened]")" >/dev/null
expect '.registry[0].id == "F1" and .registry[0].status == "open" and (.registry | length) == 2'
prepare a4
conflicting="$(jq '.id="F1" | .conflict={previous_id:"F99",evidence:"old closure",check:"both event orderings",decision:"retain lock"}' <<<"$finding")"
reject "$(result a4 FAIL "$(disposition F1 open)" "[$conflicting]")"
reject "$(result a4 PASS "$(disposition F1 open)" '[]')"
changed="$(jq '.criterion_change={previous:"both event orderings pass",reason:"include cancellation contract",evidence:"upstream cancellation specification"}' <<<"$changed")"
record "$(result a4 FAIL "$(disposition F1 open)" "[$changed]")" >/dev/null
expect '.registry[0].criterion == "prove cancellation and publication together"'
prepare a5
record "$(result a5 PASS "$(disposition F1 resolved)" '[]')" >/dev/null
expect 'all(.registry[]; .status == "resolved")'
printf 'PASS: stable findings, prior misses, closures, coverage, and justified reopening\n'
