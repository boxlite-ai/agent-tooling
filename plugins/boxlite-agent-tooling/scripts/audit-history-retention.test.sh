#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
mkdir -p "$scratch/.agents/state"
cli="$plugin/scripts/audit-reflection-gate.sh"
session="git-$(printf '%040d' 1)"
epoch_file="$scratch/.agents/state/verdict-prompt-epoch.$session"
input='{"binding":{"head":"test"},"snapshot":{"diff":"original evidence"}}'
for epoch in 1 2 3 4 5 6 7; do
  printf '%s\n' "$epoch" > "$epoch_file"
  context="$(jq -nc --arg root "$scratch" --arg session "$session" --arg epoch "$epoch" \
    '{repo_root:$root,session:$session,epoch:$epoch,branch:"main",gate:"commit"}')"
  first="$(printf '%s' "$input" | bash "$cli" "$context" prepare)"
  printf '"runner unavailable"' | bash "$cli" "$context" error "$(jq -r .attempt_id <<<"$first")" >/dev/null
  second="$(printf '%s' "$input" | bash "$cli" "$context" prepare)"
  [[ ! -e "$(jq -r .history_path <<<"$first")" && -f "$(jq -r .history_path <<<"$second")" ]]
  jq -e '.attempts[0].input.snapshot.diff == "original evidence"' "$(jq -r .history_path <<<"$second")" >/dev/null
  printf '"canceled"' | bash "$cli" "$context" cancel "$(jq -r .attempt_id <<<"$second")" >/dev/null
done
histories=("$scratch/.agents/state/"audit-history-*.json)
inputs=("$scratch/.agents/state/"audit-input-*.json)
[[ ${#histories[@]} == 5 && ${#inputs[@]} == 5 ]]
printf '8\n' > "$epoch_file"
if printf '%s' "$input" | bash "$cli" "$context" prepare >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: revoked prompt prepared another audit\n' >&2; exit 1
fi
[[ "$(cat "$scratch/err")" == *"prompt epoch changed"* ]]
if printf '{}' | bash "$cli" "$context" record "$(jq -r .attempt_id <<<"$second")" >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: revoked prompt accepted a result\n' >&2; exit 1
fi
printf 'PASS: retired context/input retention and prompt revocation\n'
