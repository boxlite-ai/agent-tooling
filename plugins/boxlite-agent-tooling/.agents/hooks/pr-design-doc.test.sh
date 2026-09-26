#!/usr/bin/env bash
# Exercise document-link enforcement through the public PR hook.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture --allow-empty
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
export DESIGN_TEST_URL=https://github.com/example/repo/issues/1
export SUMMARY_PREFIX=$'## TL;DR\n\nFixture summary.\n\n## How it works\n\nVerify the document link.\n\n'
export DESIGN_TEST_BODY="${SUMMARY_PREFIX}Design doc: $DESIGN_TEST_URL"
# Link-fragment fixtures captured from GitHub POST /markdown (mode=gfm), 2026-09-23.
export DESIGN_TEST_RENDER_FIXTURES="$plugin/.agents/hooks/fixtures/pr-design-doc-render.jsonl"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api --hostname github.com markdown -f mode=gfm -f text='*)
    [[ "${DESIGN_TEST_RENDER_FAILURE:-0}" == 0 ]] || exit 1
    if [[ "${DESIGN_TEST_RENDER_OVERSIZE:-0}" == 1 ]]; then printf '%65537s' x; exit; fi
    printf '<h2>How it works</h2><p>Verify the document link.</p>\n'
    body="${8#text=}"
    jq -er --arg body "${body#"${SUMMARY_PREFIX}"}" 'select(.body == $body) | .html' "$DESIGN_TEST_RENDER_FIXTURES" ;;
  'api --hostname github.com repos/example/repo/issues/1')
    [[ "${DESIGN_TEST_DELETED:-0}" == 0 ]] || exit 1
    jq -nc --arg url "$DESIGN_TEST_URL" '{html_url:$url,body:"## TL;DR\n\nVerify documents.\n\nProblem: undocumented code. Approach: verify documents. Validation: gate tests."}' ;;
  'repo view '*) printf '{"nameWithOwner":"example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api repos/example/repo/commits/'*) jq -nc --arg sha "$(git rev-parse HEAD)" '{sha:$sha}' ;;
  'api repos/example/repo/compare/'*) jq -nc --arg sha "$(git rev-parse HEAD)" '{base_commit:{sha:$sha},files:[]}' ;;
  'pr view '*) jq -nc --arg sha "$(git rev-parse HEAD)" --arg body "$DESIGN_TEST_BODY" \
    --arg branch "${DESIGN_TEST_BRANCH:-feature}" \
    '{baseRefOid:$sha,headRefOid:$sha,headRefName:$branch,body:$body,additions:0,deletions:0}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch/repo"
unset GH_HOST GH_REPO GIT_DIR GIT_WORK_TREE
cd "$scratch/repo"
pass=0 fail=0
check() { # label, command, expected reason fragment (empty means allow)
  local label="$1" command="$2" expected="$3" output reason
  output="$(jq -nc --arg command "$command" '{tool_input:{command:$command}}' | bash "$plugin/.agents/hooks/preflight-pr-review.sh")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$output")"
  if [[ -z "$expected" && -z "$output" || -n "$expected" && "$reason" == *"$expected"* ]]; then
    printf 'PASS %s\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL %s: expected %s; got %s\n' "$label" "$expected" "$output"; fail=$((fail+1))
  fi
}
draft="gh pr create --draft --title 'feat: test design links' --body"
check 'missing binding blocks drafts' "$draft '$DESIGN_TEST_BODY'" 'design doc'
bash "$plugin/scripts/design-doc.sh" bind "$DESIGN_TEST_URL" >/dev/null
check 'missing link blocks drafts' "$draft '${SUMMARY_PREFIX}A concise change.'" 'link the registered design doc'
check 'different issue cannot satisfy the link' "$draft '${SUMMARY_PREFIX}${DESIGN_TEST_URL}2'" 'link the registered design doc'
if [[ "${1:-}" == --reproducer ]]; then
  printf '%d passed, %d failed\n' "$pass" "$fail"; [[ "$fail" == 0 ]]; exit
fi
check 'matching draft link passes' "$draft '$DESIGN_TEST_BODY'" ''
check 'Markdown link passes' "$draft '${SUMMARY_PREFIX}[Design]($DESIGN_TEST_URL)'" ''
check 'Markdown link with title passes' "$draft '${SUMMARY_PREFIX}[Design]($DESIGN_TEST_URL \"Title\")'" ''
check 'angle-bracket Markdown destination passes' "$draft '${SUMMARY_PREFIX}[Design](<$DESIGN_TEST_URL> \"Title\")'" ''
for hidden_body in "[unused]: $DESIGN_TEST_URL" "[//]: # ($DESIGN_TEST_URL)" \
  "<a href=\"https://example.invalid\" title=\" $DESIGN_TEST_URL \">text</a>" \
  "<div> $DESIGN_TEST_URL </div>" \
  "<?xml value=\" $DESIGN_TEST_URL \"?>" \
  "<pre> $DESIGN_TEST_URL </pre>" "<code> $DESIGN_TEST_URL </code>" \
  $'[unused]:\n'"$DESIGN_TEST_URL" \
  $'[unused]: https://example.invalid\n" '"$DESIGN_TEST_URL"' "' \
  $'[unused]: https://example.invalid\n"first line\n'"$DESIGN_TEST_URL"$'\nlast line"'; do
  check 'hidden references and HTML do not supply a link' "$draft '${SUMMARY_PREFIX}$hidden_body'" 'link the registered design doc'
done
check 'autolink passes' "$draft '${SUMMARY_PREFIX}<$DESIGN_TEST_URL>'" ''
# GitHub closes the outer anchor and renders this bare URL as a separate real link.
check 'renderer-created autolink passes' "$draft '${SUMMARY_PREFIX}<a href=\"https://example.invalid\"> $DESIGN_TEST_URL </a>'" ''
reference_body=$'[Design][doc]\n\n[doc]: '"$DESIGN_TEST_URL"
check 'used reference link passes' "$draft '${SUMMARY_PREFIX}$reference_body'" ''
for tag in pre code; do
  nested_body="<$tag><$tag>example</$tag><a href=\"$DESIGN_TEST_URL\">Design</a></$tag>"
  check 'nested HTML code example is not a design link' "$draft '${SUMMARY_PREFIX}$nested_body'" 'link the registered design doc'
done
check 'Markdown target inside nested code is not a design link' "$draft '${SUMMARY_PREFIX}<code><code>example</code>[Design]($DESIGN_TEST_URL)</code>'" 'link the registered design doc'
outside_body=$'<pre><pre>example</pre></pre>\n\n'"[Design]($DESIGN_TEST_URL)"
check 'link after nested code remains visible' "$draft '${SUMMARY_PREFIX}$outside_body'" ''
check 'code example is not a link' "$draft '${SUMMARY_PREFIX}\`$DESIGN_TEST_URL\`'" 'link the registered design doc'
fenced_body=$'```text\n'"$DESIGN_TEST_URL"
check 'unclosed code fence is not a link' "$draft '${SUMMARY_PREFIX}$fenced_body'" 'link the registered design doc'
# shellcheck disable=SC2016 # Literal Markdown backticks, never shell substitution.
for fenced_body in $'> ```\n> '"$DESIGN_TEST_URL"$'\n> ```' $'- ```\n  '"$DESIGN_TEST_URL"$'\n  ```' '``example` '"$DESIGN_TEST_URL"' `example``'; do
  check 'nested and multi-backtick examples are not links' "$draft '${SUMMARY_PREFIX}$fenced_body'" 'link the registered design doc'
done
check 'URL inside another URL is not a link' "$draft '${SUMMARY_PREFIX}https://example.invalid/($DESIGN_TEST_URL)'" 'link the registered design doc'
check 'link label cannot disguise another target' "$draft '${SUMMARY_PREFIX}[$DESIGN_TEST_URL](https://example.invalid)'" 'link the registered design doc'
check 'metadata cannot supply the body link' "$draft '${SUMMARY_PREFIX}Summary' --label '$DESIGN_TEST_URL'" 'link the registered design doc'
export DESIGN_TEST_RENDER_FAILURE=1
check 'renderer failure blocks publication' "$draft '$DESIGN_TEST_BODY'" 'Cannot render'
export DESIGN_TEST_RENDER_FAILURE=0 DESIGN_TEST_RENDER_OVERSIZE=1
check 'oversized renderer response blocks publication' "$draft '$DESIGN_TEST_BODY'" 'Cannot render'
export DESIGN_TEST_RENDER_OVERSIZE=0
check 'later body replacement is checked' "$draft '$DESIGN_TEST_BODY' --body '${SUMMARY_PREFIX}Missing design link.'" 'design doc'
export DESIGN_TEST_DELETED=1
check 'deleted document blocks a matching link' "$draft '$DESIGN_TEST_BODY'" 'design doc'
export DESIGN_TEST_DELETED=0 DESIGN_TEST_BODY="${SUMMARY_PREFIX}Missing design link."
printf '{"fixture":"must remain"}\n' > .agents/state/pr-reviewed.json
cp .agents/state/pr-reviewed.json "$scratch/marker-before"
check 'ready checks the published body' 'gh pr ready 42' 'link the registered design doc'
check 'metadata edits check the published body' 'gh pr edit 42 --add-label safe' 'link the registered design doc'
cmp .agents/state/pr-reviewed.json "$scratch/marker-before"
rm .agents/state/pr-reviewed.json
export SUMMARY_PREFIX=$'## TL;DR\n\nFixture summary.\n\n## How it works\n\nVerify the document link.\n\n'
export DESIGN_TEST_BODY="${SUMMARY_PREFIX}Design doc: $DESIGN_TEST_URL"
check 'matching published body reaches human review' 'gh pr ready 42' 'Review required'
export DESIGN_TEST_BODY="Design doc: $DESIGN_TEST_URL"
check 'ready rejects a published body without TL;DR' 'gh pr ready 42' 'TL;DR'
check 'metadata edits reject a published body without TL;DR' 'gh pr edit 42 --add-label safe' 'TL;DR'
export DESIGN_TEST_BRANCH=other
check 'wrong branch is rejected by the earlier size binding' 'gh pr ready 42' 'exact PR size'
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
