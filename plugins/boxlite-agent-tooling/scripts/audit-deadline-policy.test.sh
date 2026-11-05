#!/usr/bin/env bash
# Deadline acceptance crosses the shared candidate validator and history recorder.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh"
# shellcheck source=../.agents/lib/audit-reflection-gate.sh
source "$plugin/.agents/lib/audit-reflection-gate.sh"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/scripts/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
validator="$plugin/scripts/validate-audit-dossier.sh"
reject() {
  if "$@" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: unexpectedly accepted %s\n' "$*" >&2; exit 1
  fi
}
for kind in verdict commit push; do
  for timing in legacy future elapsed; do
    now="$(date +%s)"; deadline="$((now + 600))"
    [[ "$timing" != elapsed ]] || deadline="$((now - 1))"
    context="$(jq -nc --arg root "$scratch" --arg kind "$kind" --arg session "$kind-$timing" \
      '{repo_root:$root,session:$session,epoch:"1",branch:"main",gate:$kind}')"
    if [[ "$kind" == verdict ]]; then
      result="$(jq -nc '{branch:"main",head:("a"*40),tree_hash:("b"*40),generation:"generation-1",
        verdict:"PASS",proof:[],findings:[],advisories:["unchecked at deadline: execution records remain unread"]}')"
      binding="$(jq '{branch,head,tree_hash,generation}' <<<"$result")"
    else
      result="$(jq -nc --arg kind "$kind" '{branch:"main",head:("a"*40),command_kind:$kind,
        diff_hash:("b"*64),command_hash:("c"*64),commit_subject_hash:"",verdict:"PASS",findings:[],
        advisories:["low: unchecked at deadline: test execution records remain unread"]}')"
      binding="$(jq '{branch,head,command_kind,diff_hash,command_hash,commit_subject_hash}' <<<"$result")"
    fi
    input="$(jq -nc --argjson binding "$binding" --argjson deadline "$deadline" \
      '{binding:$binding,snapshot:{evidence:"captured candidate"},deadline:$deadline}')"
    [[ "$timing" != legacy ]] || input="$(jq 'del(.deadline)' <<<"$input")"
    request="$(audit_reflection_gate "$context" prepare "" "$input")"
    id="$(jq -r .attempt_id <<<"$request")"; history="$(jq -r .history_path <<<"$request")"
    state="$(jq -r .state_path <<<"$request")"
    printf '%s\n' "$result" >"$scratch/result"
    bash "$plugin/scripts/fixtures/audit-history-result.sh" "$request" "$scratch/result" bind
    jq '.history_review.coverage |= {reviewed:[],unread:(.reviewed + .unread)}' \
      "$scratch/result" >"$scratch/unread"
    if [[ "$timing" != elapsed ]]; then
      reject bash "$validator" "$kind" "$history" "$scratch/unread"
      reject audit_reflection_gate "$context" record "$id" "$(cat "$scratch/unread")"
      continue
    fi
    original="$(cat "$state")"
    if ! bash "$validator" "$kind" "$history" "$scratch/unread" >"$scratch/out" 2>"$scratch/err"; then
      printf 'FAIL: %s deadline PASS with unread evidence rejected: %s\n' "$kind" "$(cat "$scratch/err")" >&2
      exit 1
    fi
    [[ "$(cat "$state")" == "$original" ]]
    # An identical request cannot buy more investigation time.
    retry="$(audit_reflection_gate "$context" prepare "" "$(jq '.deadline += 1000' <<<"$input")")"
    [[ "$retry" == "$request" ]]
    jq -e --argjson deadline "$deadline" '.attempts[-1].input.deadline == $deadline' "$history" >/dev/null
    jq '.deadline_review={deadline:1,recorded_at:2}' "$scratch/unread" >"$scratch/forged"
    reject bash "$validator" "$kind" "$history" "$scratch/forged"
    reject audit_reflection_gate "$context" record "$id" "$(cat "$scratch/forged")"
    jq '.history_review.coverage.unread=["invented"]' "$scratch/unread" >"$scratch/partition"
    reject bash "$validator" "$kind" "$history" "$scratch/partition"
    jq '.advisories=[]' "$scratch/unread" >"$scratch/silent"
    reject bash "$validator" "$kind" "$history" "$scratch/silent"
    audit_reflection_gate "$context" record "$id" "$(cat "$scratch/unread")" >/dev/null
    jq -e --argjson deadline "$deadline" '.attempts[-1].outcome |
      .deadline_review.deadline == $deadline and .deadline_review.recorded_at >= $deadline
      and .history_review.coverage.unread == ["evidence"] and .verdict == "PASS"' "$state" >/dev/null
    recorded="$(cat "$state")"
    jq -e -L "$plugin/.agents/lib" 'include "audit-reconciliation";
      .attempts[-1] as $attempt | $attempt.input.deadline as $deadline |
      [$deadline - 1,$deadline,$deadline + 1] |
      map(. as $time | $attempt.outcome | .deadline_review.recorded_at=$time |
        audit_deadline_qualified(.;$attempt)) == [false,true,true]' "$state" >/dev/null
    audit_reflection_gate "$context" record "$id" "$(cat "$scratch/unread")" >/dev/null
    [[ "$(cat "$state")" == "$recorded" ]]
    printf 'PASS: %s deadline coverage, read-only validation, binding and replay\n' "$kind"
  done
  # A deadline cannot erase a confirmed blocker or an insufficient reflection.
  context="$(jq --arg session "$kind-blockers" '.session=$session' <<<"$context")"
  for attempt in first second; do
    request="$(audit_reflection_gate "$context" prepare "$attempt" "$input")"
    id="$(jq -r .attempt_id <<<"$request")"; history="$(jq -r .history_path <<<"$request")"
    state="$(jq -r .state_path <<<"$request")"
    jq '.verdict="FAIL" | .findings=["high: confirmed defect: check produced a wrong result"]' <<<"$result" >"$scratch/blocker"
    bash "$plugin/scripts/fixtures/audit-history-result.sh" "$request" "$scratch/blocker" bind
    if [[ "$attempt" == second ]]; then
      for disposition in open not_assessed; do
        jq --arg disposition "$disposition" '.verdict="PASS" | .findings=[] |
          .history_review.dispositions[].status=$disposition' "$scratch/blocker" >"$scratch/unresolved"
        reject bash "$validator" "$kind" "$history" "$scratch/unresolved"
        reject audit_reflection_gate "$context" record "$id" "$(cat "$scratch/unresolved")"
      done
    fi
    bash "$validator" "$kind" "$history" "$scratch/blocker" >/dev/null
    audit_reflection_gate "$context" record "$id" "$(cat "$scratch/blocker")" >/dev/null
  done
  audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
  request="$(audit_reflection_gate "$context" prepare third "$input")"
  history="$(jq -r .history_path <<<"$request")"
  printf '%s\n' "$result" >"$scratch/reflection"
  bash "$plugin/scripts/fixtures/audit-history-result.sh" "$request" "$scratch/reflection" bind
  jq '.reflection_review.assessment="insufficient"' "$scratch/reflection" >"$scratch/insufficient"
  reject bash "$validator" "$kind" "$history" "$scratch/insufficient"
  jq '.reflection_review.assessment="unchecked" |
    .reflection_review.evidence="deadline elapsed before reflection assessment"' "$scratch/reflection" >"$scratch/unchecked"
  bash "$validator" "$kind" "$history" "$scratch/unchecked" >/dev/null
  audit_reflection_gate "$context" record third "$(cat "$scratch/unchecked")" >/dev/null
  printf 'PASS: %s confirmed blockers remain FAIL; only unchecked reflection is advisory\n' "$kind"
  context="$(jq --arg session "$kind-before-reflection" '.session=$session' <<<"$context")"
  input="$(jq --argjson deadline "$(( $(date +%s) + 600 ))" '.deadline=$deadline' <<<"$input")"
  for attempt in one two; do
    request="$(audit_reflection_gate "$context" prepare "$attempt" "$input")"
    state="$(jq -r .state_path <<<"$request")"
    audit_reflection_gate "$context" error "$attempt" '"fixture runner failure"' >/dev/null
  done
  audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
  request="$(audit_reflection_gate "$context" prepare before "$input")"
  history="$(jq -r .history_path <<<"$request")"
  printf '%s\n' "$result" >"$scratch/before-reflection"
  bash "$plugin/scripts/fixtures/audit-history-result.sh" "$request" "$scratch/before-reflection" bind
  jq '.reflection_review.assessment="unchecked"' "$scratch/before-reflection" >"$scratch/too-early"
  reject bash "$validator" "$kind" "$history" "$scratch/too-early"
  reject audit_reflection_gate "$context" record before "$(cat "$scratch/too-early")"
done
