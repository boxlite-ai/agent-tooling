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

# Every substantive prompt pays for this reminder. Keep it small enough that
# the readability guidance does not become another wall of text.
bytes="$(LC_ALL=C printf '%s' "$first" | wc -c | tr -d ' ')"
if (( bytes <= 800 )); then
  ok "reminder stays within 800 bytes ($bytes)"
else
  bad "reminder stays within 800 bytes ($bytes)"
fi

assert_contains "keeps reply-shape marker" "$first" "REPLY SHAPE:"
assert_contains "keeps prose budget" "$first" "<=80"
assert_contains "forbids walls of text" "$first" "no walls of text"
assert_contains "preserves material evidence" "$first" "Keep uncertainty, risks, failures visible"
assert_contains "offers forms by clarity" "$first" \
  "call graph, sequence diagram, real example, bullets, table, or short prose by clarity"
assert_contains "no form is compulsory" "$first" "no form is mandatory"
assert_not_contains "does not force relationship diagrams" "$first" "Visualize relationships"
assert_not_contains "does not force typed source hops" "$first" 'fn (Type, file:LOC)'
assert_contains "examples explain changing state" "$first" \
  "walk one real example step by step, showing what changes"
assert_contains "hypothetical examples are labeled" "$first" "Label hypothetical values"
assert_contains "answer leads" "$first" "Answer first"
assert_contains "explicit depth still avoids dense text" "$first" "never dense text"
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
