#!/usr/bin/env bash
# New policy/generation contract plus preserved writing boundaries, using shipped code.
set -euo pipefail
skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
cp -R "$skill" "$scratch/skill copy"
fixture="$scratch/skill copy"
cp "$fixture/rules.json" "$scratch/original.json"
# shellcheck source=check.sh
source "$fixture/scripts/check.sh"
pass=0
expect() { # label, status, command and arguments
  local label="$1" wanted="$2" status=0
  shift 2
  "$@" > "$scratch/out" 2> "$scratch/err" || status=$?
  if [[ "$status" != "$wanted" ]]; then
    printf 'FAIL %s: exit %s, expected %s\n' "$label" "$status" "$wanted" >&2
    cat "$scratch/out" "$scratch/err" >&2
    exit 1
  fi
  pass=$((pass + 1))
}
words() { perl -e 'print "word " x $ARGV[0]' "$1"; }
change() {
  jq "$1" "$scratch/original.json" > "$fixture/rules.json"
}
summary=$'## TL;DR\n\n'
expect 'standalone package validates' 0 boxlite_writing_rules
expect 'generated limits agree' 0 bash "$fixture/scripts/sync-rules.sh" --check
expect '80 words are short' 0 reply_summary_is_short "$(words 80)"
expect '81 words need a summary' 1 reply_summary_is_short "$(words 81)"
expect '80-word paragraph is not dense' 1 reply_summary_is_dense "$(words 80)"
expect '81-word paragraph is dense' 0 reply_summary_is_dense "$(words 81)"
expect '40-word item is not dense' 1 reply_summary_is_dense "- $(words 40)"
expect '41-word item is dense' 0 reply_summary_is_dense "- $(words 41)"
expect '39-word summary passes policy cap' 0 concise_writing_check_summary "$summary$(words 39)" first policy
expect '40-word summary fails policy cap' 1 concise_writing_check_summary "$summary$(words 40)" first policy
expect 'omitted cap stays unlimited' 0 concise_writing_check_summary "$summary$(words 40)"
expect 'numeric cap remains supported' 1 concise_writing_check_summary "${summary}One two three." first 2
expect 'short comment stays exempt' 0 boxlite_writing_check_body Short comment
expect 'short document still needs summary' 1 boxlite_writing_check_body Short
expect 'dense details after summary still pass' 0 boxlite_writing_check_body "${summary}Short."$'\n\n## Details\n\n'"$(words 81)"
expect 'new structure checks stay deferred' 0 boxlite_writing_check_body $'- First.\n  - Nested.\n- Second.' comment

# These settings used to share one variable; changing either must affect only its rule.
change '.enforced.paragraph_max_words = 2'
expect 'paragraph setting controls density' 0 reply_summary_is_dense 'one two three'
expect 'paragraph setting leaves exemption alone' 0 reply_summary_is_short 'one two three'
expect 'policy edits stale the presentation' 255 bash "$fixture/scripts/sync-rules.sh" --check
expect 'render changed policy' 0 bash "$fixture/scripts/sync-rules.sh"
expect 'rendered table contains the production value' 0 grep -F 'At most 2 / 40 words' "$fixture/SKILL.md"
expect 'regeneration is stable' 0 bash "$fixture/scripts/sync-rules.sh" --check
change '.enforced.short_reply_max_words = 2'
expect 'exemption setting controls short replies' 1 reply_summary_is_short 'one two three'
expect 'exemption setting leaves density alone' 1 reply_summary_is_dense 'one two three'
change '.enforced.summary_max_words = 2'
expect 'named cap reads current policy' 1 concise_writing_check_summary "${summary}One two three." first policy
expect 'legacy uncapped caller stays uncapped' 0 concise_writing_check_summary "${summary}One two three."
change '.enforced.summary_max_words = 1'
expect 'minimum numeric policy value is valid' 0 boxlite_writing_rules
change '.enforced.summary_max_words = 100000'
expect 'maximum numeric policy value is valid' 0 boxlite_writing_rules

for mutation in '.version = 2' 'del(.enforced.item_max_words)' '.extra = 1' \
  '.enforced.item_max_words = "40"' '.enforced.item_max_words = null' \
  '.enforced.item_max_words = true' '.enforced.item_max_words = 1.5' \
  '.enforced.item_max_words = 0' '.enforced.item_max_words = -1' \
  '.enforced.item_max_words = 100001' '.guidance.list_min_items = 8' \
  '.guidance.table_min_columns = 6' '.guidance.prose_max_sentences = 4'; do
  change "$mutation"
  expect "invalid policy: $mutation" 2 boxlite_writing_rules
  expect 'invalid policy cannot allow a short reply' 2 reply_summary_is_short Short
  expect 'invalid policy cannot allow a summary' 1 concise_writing_check_summary "${summary}Short."
  expect 'invalid policy cannot allow a body' 1 boxlite_writing_check_body "${summary}Short."
done
for data in '{broken' '{}' '[]' '{} {}'; do
  printf '%s' "$data" > "$fixture/rules.json"
  expect 'malformed policy fails closed' 2 boxlite_writing_rules
done
rm "$fixture/rules.json"
expect 'missing policy fails closed' 2 boxlite_writing_rules
ln -s "$scratch/original.json" "$fixture/rules.json"
expect 'policy symlink fails closed' 2 boxlite_writing_rules
rm "$fixture/rules.json"
mkfifo "$fixture/rules.json"
expect 'policy FIFO is rejected without reading' 2 boxlite_writing_rules
rm "$fixture/rules.json"
cp "$scratch/original.json" "$fixture/rules.json"
expect 'restore generated table' 0 bash "$fixture/scripts/sync-rules.sh"
cp "$fixture/SKILL.md" "$scratch/skill.md"
printf '\n<!-- writing-limits:begin -->\n' >> "$fixture/SKILL.md"
cp "$fixture/SKILL.md" "$scratch/invalid.md"
expect 'ambiguous markers reject generation' 255 bash "$fixture/scripts/sync-rules.sh"
expect 'rejected generation leaves document intact' 0 cmp "$fixture/SKILL.md" "$scratch/invalid.md"
cp "$scratch/skill.md" "$fixture/SKILL.md"
perl -pi -e 's/\n/\r\n/g' "$fixture/SKILL.md"
expect 'CRLF skill validates without rewrite' 0 bash "$fixture/scripts/sync-rules.sh" --check
# shellcheck disable=SC2016 # This program runs in the child shell, not the test shell.
expect 'source consumes no stdin and changes no options or cwd' 0 bash -c '
  before="$(set +o)"; directory="$PWD"
  source "$1" > "$2/source.out" 2> "$2/source.err"
  [[ "$(set +o)" == "$before" && "$PWD" == "$directory" ]]
  [[ ! -s "$2/source.out" && ! -s "$2/source.err" ]]
  IFS= read -r input; [[ "$input" == sentinel ]]
' -- "$fixture/scripts/check.sh" "$scratch" <<< sentinel
rm "$fixture/SKILL.md"
expect 'runtime does not parse skill prose' 0 concise_writing_check_summary "${summary}Short." first policy

# Exercise the new dependency failures at real hook boundaries, without calling gh.
plugin="$(cd "$skill/../../.." && pwd -P)"
cp -R "$plugin" "$scratch/plugin"
hook_plugin="$scratch/plugin"
printf '{invalid' > "$hook_plugin/.agents/skills/boxlite-writing/rules.json"
expect 'Stop returns a correction for invalid policy' 0 bash "$hook_plugin/.agents/hooks/stop-gate.sh" \
  <<< '{"last_assistant_message":"Short.","stop_hook_active":false}'
cp "$scratch/out" "$scratch/stop.json"
expect 'Stop cannot allow invalid policy' 0 jq -e '.decision == "block"' "$scratch/stop.json"
expect 'GitHub denies invalid policy' 0 bash "$hook_plugin/.agents/hooks/preflight-pr-review.sh" \
  <<< '{"tool_input":{"command":"gh issue comment 1 --body Short"}}'
cp "$scratch/out" "$scratch/github.json"
expect 'GitHub cannot allow invalid policy' 0 jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$scratch/github.json"
rm "$hook_plugin/.agents/skills/boxlite-writing/scripts/check.sh"
expect 'Stop aborts when the checker is missing' 2 bash "$hook_plugin/.agents/hooks/stop-gate.sh" \
  <<< '{"last_assistant_message":"Short.","stop_hook_active":false}'
expect 'GitHub aborts when the checker is missing' 2 bash "$hook_plugin/.agents/hooks/preflight-pr-review.sh" \
  <<< '{"tool_input":{"command":"gh issue comment 1 --body Short"}}'
cp "$skill/scripts/check.sh" "$hook_plugin/.agents/skills/boxlite-writing/scripts/check.sh"
rm "$hook_plugin/.agents/skills/boxlite-writing/scripts/policy.sh"
expect 'Stop aborts when the policy loader is missing' 2 bash "$hook_plugin/.agents/hooks/stop-gate.sh" \
  <<< '{"last_assistant_message":"Short.","stop_hook_active":false}'
expect 'GitHub aborts when the policy loader is missing' 2 bash "$hook_plugin/.agents/hooks/preflight-pr-review.sh" \
  <<< '{"tool_input":{"command":"gh issue comment 1 --body Short"}}'
printf 'RESULT: %s passed, 0 failed\n' "$pass"
