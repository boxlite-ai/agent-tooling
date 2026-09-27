#!/usr/bin/env bash
# Exercise storage, retention, and Stop through their public history boundaries.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh"
if [[ $# == 0 ]]; then
  for scenario in large policy capacity; do bash "$0" "$scenario"; done
  exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd -P "$scratch"
git init -q
git config user.name tester
git config user.email test@example.test
printf '.agents/state/\n' > .gitignore
git add .gitignore
git -c core.hooksPath=/dev/null commit -qm base
export CLAUDE_PROJECT_DIR="$PWD" VERDICT_CLASSIFIER_CMD=false
export VERDICT_AUDITOR_CMD='printf invoked > unexpected-auditor'
session="$(verdict_audit_scope_identity capacity-session "$PWD")"
mkdir -p .agents/state
epoch_file="$PWD/.agents/state/verdict-prompt-epoch.$session"
printf '1-1-1\n' > "$epoch_file"
context="$(jq -nc --arg root "$PWD" --arg session "$session" \
  --arg branch "$(git branch --show-current)" \
  '{repo_root:$root,session:$session,epoch:"1-1-1",branch:$branch,gate:"verdict"}')"
cli="$plugin/scripts/audit-reflection-gate.sh"
state=""
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [[ ! -f stopped ]] || cat stopped >&2
  exit 1
}
prepare() {
  jq -nc '{binding:{head:"fixture"},snapshot:{transcript:("x" * 300000),tree:"fixture"}}' \
    | bash "$cli" "$context" prepare "$1" > prepared || return
  state="$(jq -r .state_path prepared)"
}
cancel() { printf '"canceled"' | bash "$cli" "$context" cancel "$1" >/dev/null; }
grow() {
  local index
  for (( index=1; index<=$1; index++ )); do
    prepare "large-$index" || fail "history cannot prepare attempt $index within the 10 MiB budget"
    if (( index < $1 )); then cancel "large-$index"; fi
  done
}

case "$1" in
  large)
    grow 6
    (( $(wc -c < "$state") > 1048576 )) || fail 'fixture did not cross 1 MiB'
    history="$(jq -r .history_path prepared)"
    jq -e '(.attempts | length) == 6 and .attempts[0].input.snapshot.transcript == ("x" * 300000)' \
      "$history" >/dev/null || fail 'immutable history lost earlier evidence'
    cancel large-6
    printf '{}' | bash "$cli" "$context" inspect \
      | jq -e '.state.attempts[-1].outcome.verdict == "CANCELED"' >/dev/null
    printf '1-2-1\n' > "$epoch_file"
    context="$(jq -c '.epoch="1-2-1"' <<<"$context")"
    previous="$state"
    prepare next-epoch || fail 'retention cannot read a retired history larger than 1 MiB'
    [[ -f "$previous" ]] || fail 'retention removed the newest retired evidence'
    cancel next-epoch
    printf 'PASS: larger history survives preparation, recording, immutable input, inspection, and retention\n'
    ;;
  policy)
    prepare policy-1
    cancel policy-1
    # Exercise the production transition with a tight injected byte budget.
    # The state and its completed attempt come from the public CLI above.
    budget="$(jq -cS 'del(.closed)' "$state" | wc -c)"
    budget=$(( budget - 1 + 524288 - 1 ))
    { cat "$state"; jq -nc --argjson context "$context" \
        '{context:$context,attempt:{id:"policy-2",binding:{head:"fixture"},snapshot:{tree:"fixture"}}}'; } \
      | jq -ceSs -L "$plugin/.agents/lib" --arg operation prepare \
        --argjson history_max_bytes "$budget" -f "$plugin/.agents/lib/audit-reflection.jq" \
        > rejected 2> rejection && fail 'preparation did not reserve capacity for the result'
    [[ "$(cat rejection)" == *"exhausted"* ]] || fail 'reservation did not reach the budget check'
    printf 'PASS: preparation reserves room for the audit result and reconciliation\n'
    ;;
  capacity)
    prepare large-1
    # Seed an extreme but schema-valid registry onto the CLI-produced pending state.
    # Escaped control characters exercise serialized bytes, not character counts.
    jq '.attempts[0] as $entry | .attempts=[range(1;14) | . as $index | $entry |
      .id=("large-"+($index|tostring)) | .input.id=.id |
      .outcome=(if $index == 13 then null else {verdict:"CANCELED",evidence:"fixture"} end)] |
      .registry=[range(1;129) | . as $id | ("\u0001" * 2040) as $text |
      {id:("F"+($id|tostring)),invariant:(($id|tostring)+$text),behavior:$text,
       criterion:$text,status:"open",evidence:$text}]' "$state" > large-state
    hash="$(_audit_reflection_history_hash "$(cat large-state)")"
    jq -cS --arg hash "$hash" '.history_hash=$hash' large-state > "$state"
    bytes="$(wc -c < "$state")"
    (( bytes > 10485760 - 524288 && bytes < 10485760 )) || fail 'fixture misses the capacity boundary'
    printf '{}' | bash "$cli" "$context" inspect \
      | jq -e '.pending and (.exhausted == false)' >/dev/null \
      || fail 'pending audit cannot finish near the storage limit'
    cancel large-13 || fail 'reserved capacity cannot record the pending result'
    printf '{}' | bash "$cli" "$context" inspect \
      | jq -e '.exhausted and (.state.attempts | length) < 16' >/dev/null \
      || fail 'capacity exhaustion is not exposed before the attempt limit'
    cp "$state" preserved
    jq -nc '{binding:{head:"fixture"},snapshot:{transcript:"next",tree:"fixture"}}' \
      | bash "$cli" "$context" prepare extra > rejected 2> rejection && fail 'exhausted history accepted another audit'
    [[ "$(cat rejection)" == *"exhausted"* ]] || fail 'capacity rejection lacks a diagnostic'
    jq -nc '{session_id:"capacity-session",stop_hook_active:false,
      last_assistant_message:"## TL;DR\n\nAll tests passed.\n\n## Details\n\nEvidence is ready."}' \
      | bash "$plugin/.agents/hooks/stop-gate.sh" > stopped
    jq -e '.continue == false and (.stopReason | contains("INCOMPLETE"))' stopped >/dev/null \
      || fail 'byte exhaustion keeps the Stop retry loop running'
    [[ ! -e unexpected-auditor ]] || fail 'exhausted Stop launched another auditor'
    cmp "$state" preserved || fail 'exhaustion changed retained evidence'
    # JSON whitespace preserves the valid state and checksum at the exact read bound.
    perl -0777 -pe '$_ .= " " x (10485760 - length($_))' "$state" > boundary
    jq -nc --argjson context "$context" '{context:$context}' \
      | bash "$plugin/scripts/audit-reflection.sh" status "$PWD/boundary" >/dev/null \
      || fail 'history reader rejects the 10 MiB boundary'
    printf ' ' >> boundary
    jq -nc --argjson context "$context" '{context:$context}' \
      | bash "$plugin/scripts/audit-reflection.sh" status "$PWD/boundary" > rejected 2> rejection \
      && fail 'history reader exceeds the 10 MiB boundary'
    printf 'PASS: pending result records, then byte exhaustion stops without a new audit or evidence loss\n'
    ;;
  *) fail 'expected large, policy, or capacity' ;;
esac
