#!/usr/bin/env bash
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
context="$(jq -nc --arg root "$scratch" '{repo_root:$root,session:"s",epoch:"1",branch:"main",gate:"verdict"}')"
input='{"binding":{"head":"h"},"snapshot":{"diff":"candidate bytes"}}'
gate() { audit_reflection_gate "$context" "$@"; }
reject() { if gate "$@" >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: gate accepted %s\n' "$*" >&2; exit 1; fi; }
first="$(gate prepare a1 "$input")"
history="$(jq -r .history_path <<<"$first")"
state="$(jq -r .state_path <<<"$first")"
original="$(cat "$history")"
[[ "$(gate prepare a1 "$input")" == "$first" ]]
reject prepare a1 "$(jq '.binding.head="changed"' <<<"$input")"
reject prepare a2 "$input"
result="$(jq -nc --arg hash "$(jq -r .history_hash "$history")" '{head:"h",verdict:"PASS",findings:[],
  history_review:{attempt_id:"a1",history_hash:$hash,dispositions:[],findings:[],coverage:{reviewed:["diff"],unread:[]}}}')"
reject record stale "$result"
reject record a1 "$(jq '.head="wrong"' <<<"$result")"
reject record a1 "$(jq '.history_review.attempt_id="wrong"' <<<"$result")"
gate record a1 "$result" >/dev/null
gate record a1 "$result" >/dev/null
[[ "$(gate prepare a1 "$input")" == "$first" && "$(cat "$history")" == "$original" ]]
gate prepare a2 "$input" >/dev/null
jq -e '(.closed | length) == 1 and (.attempts | length) == 1' "$state" >/dev/null
gate cancel a2 '"new prompt"' >/dev/null
gate prepare a3 "$input" >/dev/null
gate error a3 '"model transport failed"' >/dev/null
gate prepare a4 "$input" >/dev/null
gate error a4 '"malformed result"' >/dev/null
gate inspect | jq -e '.reflection_due and (.pending | not)' >/dev/null
reject prepare a5 "$input"
[[ "$(cat "$scratch/err")" == *"$state"* ]]
jq -e '[.attempts[].outcome.verdict] == ["CANCELED","ERROR","ERROR"]' "$state" >/dev/null
for verdict in IN_PROGRESS PASS; do
  audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
  retry="$(gate prepare "retry-$verdict" "$input")"
  jq -nc --arg verdict "$verdict" '{verdict:$verdict,findings:[],advisories:[]}' > "$scratch/result.json"
  bash "$plugin/scripts/fixtures/audit-history-result.sh" "$retry" "$scratch/result.json" bind
  gate record "retry-$verdict" "$(cat "$scratch/result.json")" >/dev/null
  if [[ "$verdict" == IN_PROGRESS ]]; then
    gate inspect | jq -e '.reflection_due' >/dev/null
    reject prepare still-needs-reflection "$input"
  elif ! gate inspect | jq -e '(.reflection_due | not) and
      .state.reflection.body.history_hash != .state.history_hash' >/dev/null; then
    printf 'FAIL: terminal PASS requested reflection after advancing history\n' >&2
    exit 1
  fi
done
context="$(jq '.epoch="2"' <<<"$context")"
gate inspect | jq -e '(.state.attempts | length) == 0 and (.reflection_due | not)' >/dev/null
native_cli="$plugin/scripts/audit-reflection-gate.sh"
native="$(printf '%s' "$input" | bash "$native_cli" "$context" prepare)"
native_id="$(jq -r .attempt_id <<<"$native")"
[[ "$native_id" =~ ^[0-9a-f]{32}$ ]]
if printf '%s' "$input" | bash "$native_cli" "$context" prepare >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: native retry replaced an unfinished audit\n' >&2; exit 1
fi
printf '"native attempt failed"' | bash "$native_cli" "$context" error "$native_id" >/dev/null
printf '{}' | bash "$native_cli" "$context" inspect | jq -e '.state.attempts[-1].outcome.verdict == "ERROR"' >/dev/null
if printf '{}\0' | bash "$native_cli" "$context" inspect >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: native CLI accepted raw NUL\n' >&2; exit 1
fi
printf 'PASS: gate binding, immutable audit inputs, replay, cancellation, and prompt isolation\n'
