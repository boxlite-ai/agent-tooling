#!/usr/bin/env bash
# Exercise the CLI across real state-file and process boundaries.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cli="$plugin/scripts/audit-reflection.sh"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/scripts/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
state="$scratch/history.json"
context='{"repo_root":"/fixture","session":"session-a","epoch":"1","branch":"main","gate":"verdict"}'
request() { jq -nc --argjson context "$context" --arg id "$1" \
  '{context:$context,attempt:{id:$id,binding:{head:"before"},snapshot:{text:"original evidence"}}}'; }
run() { bash "$cli" "$1" "$state"; }
expect() { jq -e "$2" <<<"$1" >/dev/null || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; }
record() { jq -nc --argjson context "$context" --arg id "$1" --arg verdict "$2" \
  '{context:$context,id:$id,outcome:{verdict:$verdict,evidence:"runner evidence"}}' | run record; }
reject() {
  if printf '%s' "$2" | run "$1" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: accepted invalid %s\n' "$1" >&2; exit 1
  fi
  [[ -s "$scratch/err" ]]
}

first="$(request a1 | run prepare)"
expect "$first" '.version == 1 and (.attempts | length) == 1 and .attempts[0].outcome == null'
expect "$(request a1 | run prepare)" '.attempts | length == 1'
reject prepare "$(request a1 | jq '.attempt.binding.head="changed"')"
reject prepare "$(request a2)"
expect "$(record a1 FAIL)" '.attempts[0].outcome.verdict == "FAIL"'
expect "$(record a1 FAIL)" '.attempts | length == 1'
reject record "$(jq -nc --argjson context "$context" \
  '{context:$context,id:"a1",outcome:{verdict:"PASS",evidence:"changed result"}}')"
request a2 | run prepare >/dev/null
expect "$(record a2 ERROR)" '.attempts | length == 2'
expect "$(jq -nc --argjson context "$context" '{context:$context}' | run status)" \
  '.attempts[0].input.snapshot.text == "original evidence" and .attempts[1].outcome.verdict == "ERROR"'
reject record "$(jq -nc --argjson context "$context" \
  '{context:$context,id:"foreign",outcome:{verdict:"FAIL",evidence:"wrong attempt"}}')"
reject prepare "$(request a3 | jq '.context.epoch="2"')"
for mutation in '.extra=1' '.context.gate="arbitrary"' '.attempt.id="../escape"'; do
  reject prepare "$(request a3 | jq "$mutation")"
done
before="$(cat "$state")"
for kind in symlink fifo directory malformed; do
  state="$scratch/$kind"
  case "$kind" in
    symlink) ln -s "$scratch/history.json" "$state" ;;
    fifo) mkfifo "$state" ;;
    directory) mkdir "$state" ;;
    malformed) printf '{}\n' > "$state" ;;
  esac
  reject prepare "$(request a1)"
done
[[ "$(cat "$scratch/history.json")" == "$before" ]]
state="$scratch/concurrent.json"
for index in 1 2 3 4; do request concurrent | run prepare >"$scratch/$index.json" & done
wait
expect "$(cat "$state")" '.attempts | length == 1'
for index in 1 2 3 4; do expect "$(cat "$scratch/$index.json")" '.attempts[0].id == "concurrent"'; done
record concurrent PASS >/dev/null
expect "$(request after-pass | run prepare)" '.attempts[0].id == "after-pass" and (.closed | length) == 1'
state="$scratch/bounded.json"
reject prepare "$(request large | jq '.attempt.snapshot.text=("x" * 65537)')"
if { request nul; printf '\0'; } | run prepare >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: raw NUL accepted\n' >&2; exit 1
fi
for index in 1 2 3 4 5 6 7 8; do
  audit_test_submit_due "$cli" "$state"
  request "limit-$index" | run prepare >/dev/null
  record "limit-$index" ERROR >/dev/null
done
reject prepare "$(request ninth)"
printf 'PASS: bounded audit history, identity, replay, unsafe files, and concurrency\n'
