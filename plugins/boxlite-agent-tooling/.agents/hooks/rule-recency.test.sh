#!/usr/bin/env bash
# Public-boundary tests for the standalone prompt-rule hook.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/rule-recency.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

emit() {
  printf '{"session_id":"%s","prompt":"%s"}' "$1" "$2" \
    | TMPDIR="$TMP" RULE_RECENCY_INTERVAL=2 bash "$HOOK"
}

assert_skip() {
  if [[ -z "$2" ]]; then
    ok "$1"
  else
    bad "$1 (expected silence)"
  fi
}

assert_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing: $3)" ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$3"*) bad "$1 (unexpected: $3)" ;;
    *) ok "$1" ;;
  esac
}

printf '## Bare acknowledgements, answers, and controls are silent\n'
i=0
for prompt in ok okay k kk yes yep yeah ya yup no nope sure cool nice "got it" \
              thanks "thank you" ty thx proceed continue go "go ahead" "go on" \
              "done" next stop nvm; do
  i=$((i + 1))
  assert_skip "skip '$prompt'" "$(emit "ack-$i" "$prompt")"
done
for prompt in "OK." "Thanks!" "  proceed  "; do
  i=$((i + 1))
  assert_skip "skip normalized '$prompt'" "$(emit "normalized-$i" "$prompt")"
done

printf '\n## Substantive prompts get the same compact, stateless reminder\n'
first="$(emit same-session "explain the pull path")"
second="$(emit same-session "now fix the pull path")"
if [[ -n "$first" ]]; then
  ok "substantive prompt emits"
else
  bad "substantive prompt emits"
fi
if [[ "$first" == "$second" ]]; then
  ok "output is independent of session cadence"
else
  bad "output is independent of session cadence"
fi
for prompt in "ok explain it" "yes because it failed" "stop the server" \
              "next invoice" "thanks, explain invoices"; do
  assert_contains "do not suppress substantive near-match '$prompt'" \
    "$(emit "near-match" "$prompt")" "REPLY SHAPE:"
done

# Every substantive prompt pays for this block, so the budget is a hard stop rather
# than a guideline: raising it must be a deliberate edit here, not a side effect of a
# reworded rule. It went 640 -> 700 for the worked-example rule, which costs 668 and
# misses the old cap even with the data points unnamed (643). Getting back under means
# cutting a clause the rule needs — the per-step state requirement (633) or the escape
# hatch (639) — so the cap moved instead of the rule.
# A bullet of its own for the answer-first rule lands at 701, so the clause shares the
# framing bullet (699) instead of moving the cap again.
# It went 700 -> 720 for comments, which rode out on `exempt code` — a comment ships
# inside code, so it inherited the exemption and no prose rule reached it. Narrowing
# that clause (714) is the cheapest of the three fixes and the only one that adds no
# rule: answer-first, no-recap, and the word cap all bind a comment through the bullet
# it already sits under. Naming "why, not what" here instead costs 728 folded into the
# framing bullet and 757 as its own, and both duplicate guidance/workflow.md.
bytes="$(LC_ALL=C printf '%s' "$first" | wc -c | tr -d ' ')"
if (( bytes <= 720 )); then
  ok "reminder stays within 720 bytes ($bytes)"
else
  bad "reminder stays within 720 bytes ($bytes)"
fi

assert_contains "keeps reply-shape marker" "$first" "REPLY SHAPE:"
assert_contains "keeps prose budget" "$first" "<=80"
# Comments left through this exemption: `code` covered the block and everything written
# inside it. Assert the narrowing and the surviving list apart, so restoring the blanket
# clause fails on its own instead of passing on the leftovers.
assert_contains "keeps evidence exemptions" "$first" \
  "visuals, tables, paths, uncertainty, risk, failing tests"
assert_contains "exempts code but not its comments" "$first" \
  "exempt code (not comments)"
assert_not_contains "does not exempt comments along with the code" "$first" \
  "exempt code, visuals"
assert_contains "keeps concise-prose rule" "$first" \
  "No preamble, recap, praise, repetition, or closing offer."
assert_contains "answer leads, in one sentence" "$first" \
  "Answer first, in one sentence."
assert_contains "prefers renderable visuals when clearer" "$first" \
  "renderable diagram, graph, image, or table over prose when clearer"
assert_contains "visualizes relationships first" "$first" \
  "Visualize relationships or 3+ entities"
# The worked example carries the explanation; a reader who cannot follow the abstract
# rule follows the trace. Assert each half on its own — subject scope, a step-by-step
# walk, real data points rather than placeholders, the state each step changes, the tie
# back to the rule — so dropping any one fails loudly instead of degrading into a
# summary. The data enumeration is spelled out because "concrete example" alone reads
# as satisfied by a named-but-unvalued one.
assert_contains "examples apply to any subject" "$first" "Any subject:"
assert_contains "an example is the default, not a fallback" "$first" \
  "whenever possible"
assert_contains "walks one example step by step" "$first" \
  "walk one example step by step"
assert_contains "grounds the walk in real data points" "$first" \
  "on real data (values, facts, numbers)"
assert_contains "shows what each step changes" "$first" \
  "showing what changed at each step"
assert_contains "connects examples to the general rule" "$first" \
  "tied to the general rule"
assert_contains "omits an example only when none applies" "$first" \
  "omit only when none applies"
assert_not_contains "does not force examples into every explanation" "$first" \
  "Ground every explanation"
assert_not_contains "does not ban supported render formats" "$first" \
  "no Mermaid, images, or task boxes"
assert_contains "keeps depth escape hatch" "$first" "bare why does not"
assert_contains "keeps host-neutral workflow pointer" "$first" "repository Workflow"
assert_contains "keeps research-before-design" "$first" "research prior art before design"

printf '\n## The hook creates no state\n'
if [[ -z "$(find "$TMP" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  ok "no counter, directory, or session file"
else
  bad "no counter, directory, or session file"
fi

printf '\n## Malformed prompt parsing fails open without stderr\n'
malformed_err="$TMP.err"
malformed="$(printf '{"session_id":"rob","prompt":"a \\"quoted\\" thing"}' \
  | TMPDIR="$TMP" bash "$HOOK" 2>"$malformed_err")"
if [[ -n "$malformed" ]]; then
  ok "unparseable prompt emits"
else
  bad "unparseable prompt emits"
fi
if [[ ! -s "$malformed_err" ]]; then
  ok "unparseable prompt is silent on stderr"
else
  bad "unparseable prompt is silent on stderr"
fi

# Escaped quotes are ordinary JSON, not malformed input. The compact parser used to
# stop at the first escaped quote, normalize `ok \\` to the bare acknowledgement `ok`,
# and suppress a substantive request.
quoted_request="$(jq -nc --arg p 'ok "now fix it"' \
  '{session_id:"quoted",prompt:$p}' | TMPDIR="$TMP" bash "$HOOK")"
if [[ -n "$quoted_request" ]]; then
  ok "a substantive prompt after an escaped quote is not suppressed"
else
  bad "a substantive prompt after an escaped quote is not suppressed"
fi

printf '\n## Standalone contract has no model/runtime or state dependency\n'
code_only="$(sed 's/#.*//' "$HOOK")"
if printf '%s' "$code_only" \
  | grep -qE '\b(claude|codex|gpt|openai|anthropic|gemini|ollama|python3?|curl|wget)\b|bash -c|--model'; then
  bad "no vendor/model/runtime call"
else
  ok "no vendor/model/runtime call"
fi
if printf '%s' "$code_only" \
  | grep -qE 'RULE_RECENCY_INTERVAL|state_dir|state_file|shasum|mkdir|find[[:space:]]'; then
  bad "no cadence or filesystem state"
else
  ok "no cadence or filesystem state"
fi
if printf '%s' "$code_only" | grep -qE 'PLUGIN_ROOT|\bsource\b|^[[:space:]]*\.[[:space:]]|/\.\./'; then
  bad "no dependency on the plugin tree"
else
  ok "no dependency on the plugin tree"
fi

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
