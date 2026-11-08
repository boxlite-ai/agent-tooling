#!/usr/bin/env bash
# Adapt existing model fixtures to the history contract without changing their verdict.
set -euo pipefail
history="$(jq -r '.history_path // empty' <<<"$1")"
[[ -n "$history" ]] || exit 0
result="$(cat "$2")"
jq -c --argjson result "$result" --arg bind "${3:-}" '
  . as $h | $result + (if $bind == "bind" then $h.attempts[-1].input.binding else {} end)
  + {history_review:{attempt_id:$h.attempts[-1].id,history_hash:$h.history_hash,
    dispositions:[$h.registry[] | select(.status == "open" or .status == "not_assessed") |
      {id,status:(if $result.verdict == "PASS" then "resolved" else "open" end),evidence:"fixture check"}],
    findings:(if ($h.registry | length) == 0 and $result.verdict == "FAIL" then
      [{id:"NEW",invariant:"claims need proof",behavior:"completion",criterion:"show observed check",
        evidence:"fixture finding",origin:(if ($h.attempts | length) == 1 then "existing" else "unknown" end),
        origin_evidence:"fixture input",review_gap:"",review_change:"",
        reopening:null,conflict:null,criterion_change:null}] else [] end),
    coverage:{reviewed:($h.attempts[-1].input.snapshot | keys),unread:[]}}}
  + (if $h.attempts[-1].reflection_hash != "" then {reflection_review:{
    reflection_hash:$h.attempts[-1].reflection_hash,assessment:"sufficient",evidence:"fixture output",
    auditor_assessment:"fixture assessment"}} else {} end)' "$history" > "$2"
