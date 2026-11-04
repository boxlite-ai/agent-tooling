#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh"
# shellcheck source=../.agents/lib/audit-reflection-gate.sh
source "$plugin/.agents/lib/audit-reflection-gate.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
context="$(jq -nc --arg root "$scratch" \
  '{repo_root:$root,session:"s",epoch:"1",branch:"main",gate:"verdict"}')"
request="$(audit_reflection_gate "$context" prepare a1 \
  '{"binding":{"head":"h"},"snapshot":{"transcript":[],"tree":"t"}}')"
history="$(jq -r .history_path <<<"$request")"
dossier="$(jq '{head:.attempts[-1].input.binding.head,verdict:"IN_PROGRESS",findings:["waiting"],
  history_review:{attempt_id:.attempts[-1].id,history_hash,dispositions:[],findings:[],
    coverage:{reviewed:["transcript"],unread:[]}}}' "$history")"
if audit_reflection_gate "$context" record a1 "$dossier" >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: incomplete coverage accepted\n' >&2; exit 1
fi
if ! grep -Fq 'coverage missing=["tree"]' "$scratch/err"; then
  printf 'FAIL: coverage rejection does not identify missing tree: %s\n' "$(cat "$scratch/err")" >&2
  exit 1
fi
printf 'PASS: coverage rejection identifies the omitted snapshot key\n'
