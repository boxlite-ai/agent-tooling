#!/usr/bin/env bash
# The commit/push checkpoint asks a human only when the loop stops converging
# (design #563). Rounds come from the public history transitions, as an auditor records them.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../audit/fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
cd -P "$scratch/repo"
git -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.test commit -qm fixture --allow-empty
mkdir -p .agents/state
export CLAUDE_PROJECT_DIR="$PWD"
cli="$plugin/scripts/audit-reflection.sh"
head="$(git rev-parse HEAD)"

select_loop() {  # gate, name: each loop owns a session scope and a history file
  scope="git-$(printf '%s' "$2" | git hash-object --stdin)"
  state="$scratch/$2.json"
  context="$(jq -nc --arg root "$PWD" --arg session "$scope" --arg gate "$1" \
    '{repo_root:$root,session:$session,epoch:"0",branch:"feature",gate:$gate}')"
}
prepare() {
  audit_test_submit_due "$cli" "$state"
  jq -nc --argjson context "$context" --arg id "$1" --arg head "$head" \
    '{context:$context,attempt:{id:$id,binding:{head:$head},snapshot:{diff:"candidate"},deadline:4102444800}}' \
    | bash "$cli" prepare "$state"
}
new_findings() {  # count -> that many distinct NEW findings
  jq -nc --argjson n "$1" '[range($n) | {id:"NEW",invariant:"invariant \(.)",behavior:"behavior \(.)",
    criterion:"criterion",evidence:"test output",origin:"existing",origin_evidence:"baseline",
    review_gap:"",review_change:"",reopening:null,conflict:null,criterion_change:null}]'
}
dispositions() {  # "F1:open F2:resolved" -> dispositions
  jq -nc --arg pairs "$*" '[$pairs | split(" ")[] | split(":")
    | {id:.[0],status:.[1],evidence:"verified current test output"}]'
}
fail_round() {  # attempt id, dispositions JSON, findings JSON
  prepare "$1" >/dev/null
  jq -nc --argjson context "$context" --arg id "$1" --arg hash "$(jq -r .history_hash "$state")" \
    --argjson dispositions "$2" --argjson findings "$3" --argjson reflection "$(audit_test_assessment "$state")" \
    '{context:$context,id:$id,outcome:{verdict:"FAIL",evidence:"audit dossier",history_review:{
      attempt_id:$id,history_hash:$hash,dispositions:$dispositions,findings:$findings,
      coverage:{reviewed:["diff"],unread:[]}},reflection_review:($reflection | .assessment="insufficient")}}' \
    | bash "$cli" record "$state" >/dev/null
}
asks_human() {  # next attempt id: true when preparation stops at the decision checkpoint
  if prepare "$1" >"$scratch/out" 2>"$scratch/err"; then return 1; fi
  [[ "$(cat "$scratch/err")" == *"audit-decision:"* ]]
}

for gate in commit push; do
  select_loop "$gate" "$gate-converging"
  fail_round a1 '[]' "$(new_findings 3)"
  fail_round a2 "$(dispositions F1:resolved F2:open F3:open)" '[]'
  fail_round a3 "$(dispositions F2:resolved F3:open)" '[]'
  if asks_human a4; then
    printf 'FAIL: a converging %s loop (3, 2, 1 findings) asked the human\n' "$gate" >&2; exit 1
  fi
  jq -e '.attempts | length == 4' "$state" >/dev/null

  select_loop "$gate" "$gate-stalled"
  fail_round b1 '[]' "$(new_findings 2)"
  fail_round b2 "$(dispositions F1:open F2:resolved)" '[]'
  fail_round b3 "$(dispositions F1:open)" '[]'
  asks_human b4 || {
    printf 'FAIL: a stalled %s loop (2, 1, 1 findings) launched a fourth audit\n' "$gate" >&2; exit 1; }
  jq -e '.attempts | length == 3' "$state" >/dev/null

  select_loop "$gate" "$gate-two-rounds"
  fail_round c1 '[]' "$(new_findings 1)"
  fail_round c2 "$(dispositions F1:open)" '[]'
  if asks_human c3; then
    printf 'FAIL: %s asked the human before the third failed round\n' "$gate" >&2; exit 1
  fi
done
printf 'PASS: Git asks the human from the third failure only when the loop stops converging\n'
