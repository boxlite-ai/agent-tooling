#!/usr/bin/env bash
# Runtime edits cross the real renderer and standalone hook boundaries.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/plugin/.agents" "$scratch/consumer"
cp -R "$plugin/.agents/lib" "$plugin/.agents/prompts" "$scratch/plugin/.agents/"
# shellcheck source=../.agents/lib/timed-user-prompt.sh
source "$scratch/plugin/.agents/lib/timed-user-prompt.sh"
request='{"id":"quote\" and newline\n", "spec":{"prefix":"reviewed:","fallback":"keep-draft"}}'
question="$(_timed_user_prompt_question "$request")"
jq -e '.questions[0].question | contains("quote\" and newline\n")' <<<"$question" >/dev/null
# Change the shipped question, then call the same production renderer again.
sed 's/Keep draft/Edited choice/' "$plugin/.agents/prompts/questions/timed-question-review.md" \
  > "$scratch/plugin/.agents/prompts/questions/timed-question-review.md"
question="$(_timed_user_prompt_question "$request")"
jq -e '.questions[0].options[0].label == "Edited choice"' <<<"$question" >/dev/null
rm "$scratch/plugin/.agents/prompts/questions/timed-question-review.md"
status=0
question="$(_timed_user_prompt_question "$request" 2>/dev/null)" || status=$?
[[ "$status" == 2 && -z "$question" ]]
printf 'PASS native questions reload Markdown and reject missing templates\n'

# The renderer still validates commands before composing its Markdown instruction.
# shellcheck source=../.agents/lib/hook-interactive-prompt.sh
source "$scratch/plugin/.agents/lib/hook-interactive-prompt.sh"
spec='{"question":"Wait?","header":"Audit","options":[{"label":"Wait","description":"Wait","command":"true"},{"label":"Stop","description":"Stop","command":"false"}]}'
out="$(hook_interactive_prompt_render_claude "$spec")"
[[ "$out" == *'"Wait": true'* && "$out" == *'"Stop": false'* ]]
printf '%s\n' '{{payload}}' '{{commands}}' 'edited $(literal)' \
  > "$scratch/plugin/.agents/prompts/questions/interactive-question.md"
out="$(hook_interactive_prompt_render_claude "$spec")"
[[ "$out" == *'edited $(literal)'* ]]
rm "$scratch/plugin/.agents/prompts/questions/interactive-question.md"
status=0
out="$(hook_interactive_prompt_render_claude "$spec" 2>/dev/null)" || status=$?
[[ "$status" == 2 && -z "$out" ]]
printf 'PASS interactive instructions reload without executing template text\n'

cp "$plugin/.agents/hooks/rule-recency.sh" "$plugin/.agents/hooks/rule-recency.md" "$scratch/consumer/"
hook="$scratch/consumer/rule-recency.sh"
out="$(printf '{"prompt":"explain the code"}' | bash "$hook")"
[[ "$out" == "$(cat "$plugin/.agents/hooks/rule-recency.md")" ]]
printf '%s\n' 'edited standalone reminder' > "$scratch/consumer/rule-recency.md"
out="$(printf '{"prompt":"explain the code"}' | bash "$hook")"
[[ "$out" == 'edited standalone reminder' ]]
rm "$scratch/consumer/rule-recency.md"
out="$(printf '{"prompt":"explain the code"}' | bash "$hook")"
[[ -z "$out" ]]
mkfifo "$scratch/consumer/rule-recency.md"
out="$(printf '{"prompt":"explain the code"}' | bash "$hook")"
[[ -z "$out" ]]
printf 'PASS copied standalone hook reloads its companion and skips missing or nonregular files\n'
