#!/usr/bin/env bash
# Test model seam: inspect real runner inputs and emit a bound independent result.
set -euo pipefail
task="$(sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }')"
printf 'run\n' >> "$CLAUDE_PROJECT_DIR/.agents/state/model-runs"
index="$(mktemp)"
GIT_INDEX_FILE="$index" git read-tree HEAD
GIT_INDEX_FILE="$index" git add -A
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
rm -f "$index"
history="$(jq -r '.history_path // empty' <<<"$task")"
verdict="${TEST_HISTORY_VERDICT:-FAIL}"
result="$(jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg tree "$tree" --arg generation "$VERDICT_AUDITOR_GENERATION" --arg verdict "$verdict" \
  '{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,verdict:$verdict,
    proof:[],findings:(if $verdict == "PASS" then [] else ["proof absent"] end)}')"
if [[ -n "$history" ]]; then
  cp "$history" "$CLAUDE_PROJECT_DIR/.agents/state/last-model-input"
  result="$(jq -c --argjson result "$result" '
    . as $h | $result + {history_review:{attempt_id:$h.attempts[-1].id,history_hash:$h.history_hash,
      dispositions:[$h.registry[] | select(.status == "open" or .status == "not_assessed") |
        {id,status:(if $result.verdict == "PASS" then "resolved" else "open" end),evidence:"fixture check"}],
      findings:(if ($h.registry | length) == 0 and $result.verdict == "FAIL" then
        [{id:"NEW",invariant:"claims need proof",behavior:"completion",criterion:"show observed check",
          evidence:"missing check",origin:"existing",origin_evidence:"first input",review_gap:"",review_change:"",
          reopening:null,conflict:null,criterion_change:null}] else [] end),
      coverage:{reviewed:($h.attempts[-1].input.snapshot | keys),unread:[]}}}
    + (if $h.attempts[-1].reflection_hash != "" then {reflection_review:{
      reflection_hash:$h.attempts[-1].reflection_hash,assessment:"sufficient",evidence:"fixture check output",
      auditor_assessment:"prior proof gap now checked"}} else {} end)' "$history")"
fi
printf '%s\n' "$result" > "$VERDICT_AUDITOR_OUTPUT_FILE"
