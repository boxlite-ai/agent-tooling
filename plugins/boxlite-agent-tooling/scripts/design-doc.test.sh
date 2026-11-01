#!/usr/bin/env bash
# Provider responses cross the public CLI boundary; never contact live services.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/repo"
export DOC_FIXTURE="$scratch/response.json" DOC_CALLS="$scratch/calls"
: > "$DOC_CALLS"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOC_CALLS"
[[ "${DOC_ERROR:-0}" == 0 ]] || exit 1
cat "$DOC_FIXTURE"
SH
cat > "$scratch/bin/curl" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[[ "${DOC_ERROR:-0}" == 0 ]] || exit 22
case "$*" in
  *'/v1/pages/'*) cat "$DOC_PAGE" ;;
  *) cat "$DOC_FIXTURE" ;;
esac
SH
chmod +x "$scratch/bin/gh" "$scratch/bin/curl"
export PATH="$scratch/bin:$PATH"
unset GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE NOTION_TOKEN LINEAR_API_KEY
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=test \
  -c user.email=test@example.invalid commit -qm initial --allow-empty
git -C "$scratch/repo" branch -m feature
cd "$scratch/repo" || exit 1
cli="$plugin/scripts/design-doc.sh"
url=https://github.com/example/project/issues/1
state="$(git rev-parse --absolute-git-dir)/agent-tooling-design-doc.json"
pass=0 fail=0
expect() { # description, exit status, arguments
  local description="$1" expected="$2" status=0
  shift 2
  bash "$cli" "$@" > "$scratch/out" 2> "$scratch/err" || status=$?
  if [[ "$status" == "$expected" ]]; then
    printf 'PASS %s\n' "$description"; pass=$((pass+1))
  else
    printf 'FAIL %s (exit %s, wanted %s)\n' "$description" "$status" "$expected"
    cat "$scratch/err"; fail=$((fail+1))
  fi
}
github_doc() {
  jq -nc --arg url "$url" --arg body "$1" '{html_url:$url,body:$body}' > "$DOC_FIXTURE"
}
expect 'missing binding blocks' 1 check
expect 'missing binding has nothing to show' 1 show
expect 'missing command prints usage' 2
if [[ "$(cat "$scratch/err")" == *'design-doc.sh register <URL>'* ]]; then
  printf 'PASS usage recommends register\n'; pass=$((pass+1))
else
  printf 'FAIL usage does not recommend register\n'; fail=$((fail+1))
fi
github_doc ''
expect 'register rejects an empty design' 1 register "$url"
github_doc $'## TL;DR\n\nVerify designs before edits.\n\nProblem: undocumented edits. Approach: verify a design doc. Validation: gate tests.'
expect 'register creates an unbound worktree binding' 0 register "$url"
expect 'matching branch verifies again' 0 check
[[ "$(cat "$scratch/out")" == "$url" ]] || fail=$((fail+1))
[[ "$(wc -l < "$DOC_CALLS")" -ge 2 ]] || fail=$((fail+1))
expect 'show prints the bound GitHub design' 0 show
[[ "$(cat "$scratch/out")" == *'Verify designs before edits.'* ]] || fail=$((fail+1))
cd "$scratch" || exit 1
expect 'show targets the bound repository from a writable cwd' 0 show "$scratch/repo"
[[ "$(cat "$scratch/out")" == *'Verify designs before edits.'* ]] || fail=$((fail+1))
expect 'an explicit unbound target cannot reuse another repository binding' 1 show "$scratch"
cd "$scratch/repo" || exit 1
rm -f "$state"
expect 'legacy bind registers an unbound worktree' 0 bind "$url"
expect 'legacy binding verifies again' 0 check
# The research auditor's verdict binds to the exact content it reviewed.
content_hash() { # text -> SHA-256 hex
  printf '%s' "$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
}
verdict() { # SHA-256, PASS|FAIL, findings JSON -> the auditor's record
  jq -nc --arg sha "$1" --arg verdict "$2" --argjson findings "$3" \
    '{content_sha256:$sha,verdict:$verdict,findings:$findings}'
}
record() { # description, exit status, record
  local description="$1" expected="$2" status=0
  bash "$cli" verdict <<<"$3" > "$scratch/out" 2> "$scratch/err" || status=$?
  if [[ "$status" == "$expected" ]]; then
    printf 'PASS %s\n' "$description"; pass=$((pass+1))
  else
    printf 'FAIL %s (exit %s, wanted %s)\n' "$description" "$status" "$expected"
    cat "$scratch/err"; fail=$((fail+1))
  fi
}
reviewed="$(content_hash "$(jq -r .body "$DOC_FIXTURE")")"
record 'a verdict for other content is rejected' 1 "$(verdict "$(content_hash other)" PASS '[]')"
record 'PASS with findings is rejected' 1 "$(verdict "$reviewed" PASS '["research: gap; check"]')"
record 'FAIL without findings is rejected' 1 "$(verdict "$reviewed" FAIL '[]')"
record 'extra fields are rejected' 1 "$(verdict "$reviewed" PASS '[]' | jq -c '. + {note:"x"}')"
record 'malformed input is rejected' 1 'not json'
record 'a FAIL with findings is recorded' 0 "$(verdict "$reviewed" FAIL '["research: gap; check"]')"
record 'a PASS for the reviewed content is recorded' 0 "$(verdict "$reviewed" PASS '[]')"
expect 'recording leaves the binding intact' 0 check

# The research loop (design #309): severity, carried findings, the FAIL cap, and the
# human's choice. Each revision is new design content.
research_state="$(git rev-parse --absolute-git-dir)/agent-tooling-design-audit.json"
revise() { # label -> SHA-256 of the published revision
  github_doc $'## TL;DR\n\nVerify designs before edits.\n\nRevision '"$1"'.'
  content_hash "$(jq -r .body "$DOC_FIXTURE")"
}
gate() { # operation [argument] -> design_doc_binding through the library, as the hook calls it
  bash -c 'for lib in verdict-audit-state reply-summary concise-writing design-doc; do
      source "$1/.agents/lib/$lib.sh" || exit 2; done
    design_doc_binding "$2" "$PWD" "${3:-}"' gate "$plugin" "$@"
}
review() { # SHA-256, findings JSON, advisories JSON -> the auditor's record
  jq -nc --arg sha "$1" --argjson findings "$2" --argjson advisories "${3:-[]}" \
    '{content_sha256:$sha, verdict:(if $findings == [] then "PASS" else "FAIL" end),
      findings:$findings, advisories:$advisories}'
}
high() { jq -nc --arg gap "$1" '["high: research: " + $gap]'; }
outcome() { # description, wanted status, status
  if [[ "$3" == "$2" ]]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s (exit %s, wanted %s)\n' "$1" "$3" "$2"; cat "$scratch/err"; fail=$((fail+1)); fi
}
request_has() { # description, jq condition on the edit gate's request
  local request status=0
  request="$(gate edit 2>"$scratch/err")" || status=$?
  jq -e "$2" <<<"$request" >/dev/null 2>&1 || status="unmatched $status: $request"
  outcome "$1" 3 "$status"
}
decide() { local status=0; gate decide "$3" >/dev/null 2>"$scratch/err" || status=$?; outcome "$1" "$2" "$status"; }
reflect() { local status=0; bash "$cli" reflect <<<"$3" >/dev/null 2>"$scratch/err" || status=$?; outcome "$1" "$2" "$status"; }
reflection() { # gate request -> a reflection bound to its history and FAIL ids
  jq -c '{history_hash, failure_ids, diagnosis:"the first fix edited wording only",
    previous_fixes_failed_because:"no source was re-read", changed_approach:"re-derive claims from sources",
    checks:[{command:"rg -n claim design.md", expected:"one source", observed:"one source",
      evidence:"design.md:3"}], auditor_gaps:[]}' <<<"$1"
}
two='["high: research: Fidelity: quote lacks subject","critical: research: Search: no log"]'
a="$(revise a)"
record 'advisories alone record PASS' 0 "$(review "$a" '[]' '["low: research: Search: wording"]')"
status=0; gate edit >/dev/null 2>"$scratch/err" || status=$?
outcome 'a PASS with advisories allows edits' 0 "$status"
record 'a high advisory is rejected' 1 "$(review "$a" '[]' '["high: research: Search: missed item"]')"
record 'FAIL 1 records its findings' 0 "$(review "$a" "$two")"
b="$(revise b)"
request_has 'findings survive an edit' ".prior_findings == $two and .findings == [] and .fails == 1"
record 'FAIL 2 with fewer, new findings records' 0 "$(review "$b" "$(high 'Alternatives: reuse unexamined')")"
request_has 'a converging FAIL 2 waits for a reflection' '.reflection_due and (.blocked | not) and .fails == 2'
record 'audit 3 is refused before the reflection' 1 "$(review "$b" '[]')"
request="$(gate edit 2>/dev/null)" || true
reflect 'a reflection missing the FAIL ids is refused' 1 "$(reflection "$request" | jq -c '.failure_ids = ["1:x","2:y"]')"
reflect 'a reflection bound to this history is stored' 0 "$(reflection "$request")"
request_has 'the reflected loop asks for audit 3' '(.reflection_due | not) and (.blocked | not)'
c="$(revise c)"
record 'FAIL 3 records' 0 "$(review "$c" "$(high 'Transfer: unsupported')")"
request_has 'FAIL 3 stops for the human' '.blocked and .stop == "cap" and .fails == 3'
record 'a stopped loop refuses another verdict' 1 "$(review "$c" '[]')"
decide 'a choice the gate does not know is refused' 1 'Approve'
decide 'Reflect again reopens one audit' 0 'Reflect again'
request_has 'Reflect again waits for a reflection' '.reflection_due and (.blocked | not)'
request="$(gate edit 2>/dev/null)" || true
reflect 'the second reflection binds all three FAILs' 0 "$(reflection "$request")"
record 'the extra audit fails' 0 "$(review "$c" "$(high 'Transfer: unsupported')")"
request_has 'a FAIL after Reflect again stops again' '.blocked and .stop == "cap" and .fails == 4'
decide 'Overrule ends the loop' 0 Overrule
status=0; gate edit >/dev/null 2>"$scratch/err" || status=$?
outcome 'an overrule allows edits for this content' 0 "$status"
status=0; [[ "$(jq -r .verdict "$research_state")" == OVERRIDDEN ]] || status=1
outcome 'an overrule is recorded as OVERRIDDEN, never PASS' 0 "$status"
decide 'no decision is pending after an overrule' 1 Overrule
d="$(revise d)"
request_has 'overruled findings ride along, marked' \
  '.prior_findings == ["overruled: high: research: Transfer: unsupported"] and .fails == 0'
record 'FAIL 1 of a new cycle' 0 "$(review "$d" "$two")"
e="$(revise e)"
record 'a repeated finding at FAIL 2 records' 0 "$(review "$e" '["high: research: Fidelity: quote lacks subject"]')"
request_has 'a repeated finding stops at FAIL 2' '.blocked and .stop == "early" and .fails == 2'
decide 'Redesign resets the count' 0 Redesign
request_has 'Redesign asks for a fresh draft' '.redesign and .fails == 0 and (.blocked | not)'
record 'the failed draft cannot be audited after Redesign' 1 "$(review "$e" '[]')"
f="$(revise f)"
request_has 'a fresh draft starts a new count' '(.redesign | not) and .fails == 0'
record 'FAIL 1 again' 0 "$(review "$f" "$(high 'Search: thin log')")"
g="$(revise g)"
record 'FAIL 2 with as many new findings records' 0 "$(review "$g" "$(high 'Local fit: unchecked')")"
request_has 'no drop in findings stops at FAIL 2' '.blocked and .stop == "early"'
decide 'Overrule again' 0 Overrule
h="$(revise h)"
record 'FAIL 1 before rebinding' 0 "$(review "$h" "$two")"
other=https://github.com/example/project/issues/2
jq -nc --arg url "$other" --arg body "$(jq -r .body "$DOC_FIXTURE")" '{html_url:$url,body:$body}' > "$DOC_FIXTURE"
expect 'another design URL can be registered' 0 register "$other"
request_has 'another URL gets no prior findings but keeps the count' '.prior_findings == [] and .fails == 1'
record 'FAIL 2 after rebinding records' 0 "$(review "$h" "$two")"
request_has 'rebinding cannot reset the count' '.blocked and .fails == 2'
github_doc $'## TL;DR\n\nVerify designs before edits.\n\nProblem: undocumented edits. Approach: verify a design doc. Validation: gate tests.'
expect 'the original design is registered again' 0 register "$url"
jq -nc --arg root "$(pwd -P)" --arg url "$url" --arg sha "$h" '{root:$root, branch:"feature",
  url:$url, content_sha256:$sha, verdict:"FAIL", findings:["research: legacy finding"]}' > "$research_state"
request_has 'a legacy FAIL counts once and carries its findings' \
  '.prior_findings == ["research: legacy finding"] and .fails == 1'
jq '. + {advisories:[], failures:[], stop:"sideways", extra:false, reflection:null, overruled:[]}' \
  "$research_state" > "$scratch/malformed" && mv "$scratch/malformed" "$research_state"
request="$(gate edit 2>/dev/null)" && status=0 || status=$?
[[ -z "$request" ]] || status="request printed"
outcome 'a malformed loop state fails closed' 3 "$status"
record 'a malformed loop state takes no verdict' 1 "$(verdict "$reviewed" PASS '[]')"
rm -f "$research_state"
# Verdicts recorded before the rename stay readable until the next one is written.
legacy="$(git rev-parse --absolute-git-dir)/agent-tooling-design-research.json"
jq -nc --arg root "$(pwd -P)" --arg url "$url" --arg sha "$reviewed" '{root:$root, branch:"feature",
  url:$url, content_sha256:$sha, verdict:"PASS", findings:[]}' > "$legacy"
status=0; gate edit >/dev/null 2>"$scratch/err" || status=$?
outcome 'a PASS in the old state file still allows edits' 0 "$status"
rm -f "$legacy"
status=0; bash "$cli" research <<<"$(verdict "$reviewed" PASS '[]')" >/dev/null 2>"$scratch/err" || status=$?
outcome 'research remains an alias of verdict' 0 "$status"
git checkout -qb different
expect 'another branch cannot reuse binding' 1 check
expect 'another branch cannot show the binding' 1 show
expect 'explicit target still checks its branch binding' 1 show "$scratch/repo"
git checkout -q feature
export DOC_ERROR=1
expect 'network failures never use previous success' 1 check
export DOC_ERROR=0
github_doc ''
expect 'empty document blocks' 1 check
printf '{broken' > "$DOC_FIXTURE"
expect 'malformed provider response blocks' 1 check
printf '{"html_url":"%s","body":"Design","pull_request":{}}' "$url" > "$DOC_FIXTURE"
expect 'a PR is not a GitHub design issue' 1 check
github_doc $'## TL;DR\n\nA concise design.\n\n## Detail\n\n'"$(printf 'word %.0s' {1..81})"
expect 'a leading TL;DR lets the design keep dense detail' 0 check
github_doc $'## TL;DR\n\nVerify designs before edits.\n\n- Problem: undocumented changes.\n- Approach: gate edits.\n- Validation: tests.'
expect 'compact bullet design passes' 0 check
github_doc $'Preface.\n\n## TL;DR\n\nA concise design.'
expect 'summary must lead the design' 1 check
summary="$(printf 'word %.0s' {1..39})"
github_doc "## TL;DR

$summary

## Design

Validate provider responses."
expect '39-word summary passes' 0 check
github_doc "## TL;DR

${summary}word

## Design

Validate provider responses."
expect '40-word summary blocks' 1 check
design="## TL;DR

Design.

## Detail

$(printf 'word %.0s' {1..59})

$(printf 'word %.0s' {1..58})"
github_doc "$design"
expect 'compact multi-paragraph design passes' 0 check
github_doc "$design word"
expect 'a design over 120 words can be registered' 0 bind "$url"
expect 'a bound design can exceed the reply word budget' 0 check
github_doc $'## TL;DR\n\nA concise design.'
expect 'untrusted hosts are rejected' 1 bind https://github.com.attacker.invalid/example/project/issues/1
for unsafe_url in 'https://user:sensitive-fixture@github.com/example/project/issues/1' $'https://invalid.example/\nsensitive-fixture'; do
  expect 'unsafe URL blocks' 1 bind "$unsafe_url"
  if [[ "$(cat "$scratch/err")" == *sensitive-fixture* ]]; then
    printf 'FAIL rejected URL leaks into diagnostics\n'; fail=$((fail+1))
  else
    printf 'PASS rejected URL stays out of diagnostics\n'; pass=$((pass+1))
  fi
done
mv "$state" "$scratch/saved"
ln -s "$scratch/saved" "$state"
expect 'symlink binding blocks' 1 check
rm "$state"
mkfifo "$state"
expect 'FIFO binding blocks without waiting' 1 check
rm "$state"
mkdir "$state"
expect 'directory binding blocks' 1 check
rmdir "$state"
cp "$scratch/saved" "$state"
linear=https://linear.app/example/issue/EX-1/design
expect 'Linear needs credentials' 1 bind "$linear"
export LINEAR_API_KEY=fixture-only
jq -nc --arg url "$linear" '{data:{issue:{url:$url,description:"## TL;DR\n\nDesign and validation.",archivedAt:null}}}' > "$DOC_FIXTURE"
expect 'Linear document verifies' 0 bind "$linear"
expect 'show reads a Linear design through its API' 0 show
[[ "$(cat "$scratch/out")" == *'Design and validation.'* ]] || fail=$((fail+1))
cp "$DOC_FIXTURE" "$scratch/linear-valid"
jq -nc --arg url "$linear" --arg body "$design word" \
  '{data:{issue:{url:$url,description:$body,archivedAt:null}}}' > "$DOC_FIXTURE"
expect 'Linear designs can exceed the reply word budget' 0 check
cp "$scratch/linear-valid" "$DOC_FIXTURE"
jq '. + {errors:[{message:"denied"}]}' "$DOC_FIXTURE" > "$scratch/errors"
mv "$scratch/errors" "$DOC_FIXTURE"
expect 'GraphQL partial errors block' 1 check
jq -nc --arg url "$linear" '{data:{issue:{url:$url,description:"## TL;DR\n\nDesign and validation.",archivedAt:null}},padding:("x" * 70000)}' > "$DOC_FIXTURE"
expect 'HTTP response bound is independent of curl version' 1 check
notion=https://www.notion.so/Design-0123456789abcdef0123456789abcdef
expect 'Notion needs credentials' 1 bind "$notion"
export NOTION_TOKEN=fixture-only DOC_PAGE="$scratch/page.json"
printf '{"object":"page","id":"01234567-89ab-cdef-0123-456789abcdef","archived":false}' > "$DOC_PAGE"
jq -nc '{object:"list",has_more:false,results:[{type:"heading_2",heading_2:{rich_text:[{plain_text:"TL;DR"}]}},{type:"paragraph",paragraph:{rich_text:[{plain_text:"Design and validation."}]}}]}' > "$DOC_FIXTURE"
expect 'Notion page and content both verify' 0 bind "$notion"
notion_block() {
  jq -nc --arg type "$1" --arg text "$2" --argjson children "${3:-false}" \
    '{object:"list",has_more:false,results:[{type:$type,has_children:$children,
      ($type):{rich_text:[{plain_text:$text}]}}]}' > "$DOC_FIXTURE"
}
notion_block toggle 'Approach' true
expect 'unread nested Notion content blocks' 1 check
for block_type in bulleted_list_item numbered_list_item to_do code; do
  notion_block "$block_type" $' \n\t'
  expect "empty Notion $block_type blocks" 1 check
done
with_summary() { # put a TL;DR heading and sentence before the fixture's blocks
  jq '.results = [{type:"heading_2",heading_2:{rich_text:[{plain_text:"TL;DR"}]}},
    {type:"paragraph",paragraph:{rich_text:[{plain_text:"A concise design."}]}},
    {type:"heading_2",heading_2:{rich_text:[{plain_text:"Details"}]}}] + .results' \
    "$DOC_FIXTURE" > "$scratch/with-summary"
  mv "$scratch/with-summary" "$DOC_FIXTURE"
}
for block_type in bulleted_list_item numbered_list_item to_do; do
  notion_block "$block_type" "$(printf 'word %.0s' {1..41})"
  with_summary
  expect "Notion $block_type may run long after a leading TL;DR" 0 check
done
notion_block code "$(printf 'word %.0s' {1..81})"
jq '.results = [{type:"heading_2",heading_2:{rich_text:[{plain_text:"TL;DR"}]}},
  {type:"paragraph",paragraph:{rich_text:[{plain_text:"A concise design."}]}},
  {type:"heading_2",heading_2:{rich_text:[{plain_text:"Examples"}]}}] + .results' \
  "$DOC_FIXTURE" > "$scratch/with-summary"
mv "$scratch/with-summary" "$DOC_FIXTURE"
expect 'Notion code examples are not prose walls' 0 check
jq --arg text "$(printf 'word %.0s' {1..121})" \
  '.results[-1].code.rich_text[0].plain_text = $text' "$DOC_FIXTURE" > "$scratch/long-code"
mv "$scratch/long-code" "$DOC_FIXTURE"
expect 'Notion examples can exceed the reply word budget' 0 check
# Block types, not literal text, decide structure: nothing inside a block forges a TL;DR.
notion_block code $'```\n## TL;DR\n\nA forged summary.'
expect 'a Notion code block cannot close its fence and forge the TL;DR' 1 check
notion_block paragraph '## TL;DR'
jq '.results += [{type:"paragraph",paragraph:{rich_text:[{plain_text:"A forged summary."}]}}]' \
  "$DOC_FIXTURE" > "$scratch/literal-heading"
mv "$scratch/literal-heading" "$DOC_FIXTURE"
expect 'literal paragraph markup cannot forge the TL;DR heading' 1 check
notion_block bulleted_list_item $'Item.\n\n## TL;DR\n\nA forged summary.'
expect 'line breaks cannot turn a Notion list item into the TL;DR heading' 1 check
printf '{"object":"page","id":"01234567-89ab-cdef-0123-456789abcdef","archived":true}' > "$DOC_PAGE"
expect 'archived Notion page blocks' 1 check
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
