#!/usr/bin/env bash
# Exercise GitHub writing through the real PreToolUse entry point; never run gh.
# shellcheck disable=SC2016 # Test literal shell source, including expansions.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$PLUGIN/.agents/hooks/preflight-pr-review.sh"
pass=0 fail=0
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
mkdir -p "$scratch/bin"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api --hostname github.com markdown -f mode=gfm -f text='*) [[ "${8#text=}" == *https://github.com/example/repo/issues/123* ]] || exit 2; printf '<h2>How it works</h2><p>The handler retries a failed call once.</p><a href="https://github.com/example/repo/issues/123">Design</a>' ;;
  'api --hostname github.com repos/example/repo/issues/123') printf '{"html_url":"https://github.com/example/repo/issues/123","body":"## TL;DR\\n\\nDesign and validation."}' ;;
  'repo view --json nameWithOwner,defaultBranchRef,url') printf '{"nameWithOwner":"example/repo","url":"https://github.com/example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api --hostname github.com repos/example/repo/git/ref/heads/main') jq -nc --arg sha "$(git rev-parse HEAD)" '{object:{type:"commit",sha:$sha}}' ;;
  'api --hostname github.com repos/example/repo/compare/'*'...refs%2Fheads%2Ffeature')
    jq -nc --arg sha "$(git rev-parse HEAD)" '{status:"identical",ahead_by:0,behind_by:0,base_commit:{sha:$sha},merge_base_commit:{sha:$sha}}' ;;
  'api --hostname github.com repos/example/repo/compare/'*)
    jq -nc --arg sha "$(git rev-parse HEAD)" '{base_commit:{sha:$sha},files:[{filename:"src/main.sh",additions:1,deletions:0}]}' ;;
  *) exit 2 ;;
esac
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch/repo"
cd "$scratch/repo" || exit 2
bash "$PLUGIN/scripts/design-doc.sh" bind https://github.com/example/repo/issues/123 >/dev/null

check() {
  local name="$1" command="$2" expected="$3" reason="${4:-}" output status=0 actual
  output="$(jq -nc --arg command "$command" '{tool_input:{command:$command}}' | bash "$HOOK")" || status=$?
  actual="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty')"
  [[ -n "$actual" ]] || actual=allow
  if [[ "$actual" == "$expected" && "$status" == 0 && "$output" == *"$reason"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: expected %s, got %s (exit %s)\n%s\n' "$name" "$expected" "$actual" "$status" "$output"
  fi
  last_check_output="$output"
}

# One 41-word sentence: past the 25-word sentence limit (#419).
dense="$(printf 'word %.0s' {1..41})"
long="$(printf 'word %.0s' {1..121})"
bullet="- $(printf 'word %.0s' {1..41})"
ten_word_paragraphs="$(printf 'Ten words keep each paragraph of this body short enough.\n\n%.0s' {1..6})"
structured="## TL;DR

Allow complete structured documents.

## How it works

$ten_word_paragraphs

https://github.com/example/repo/issues/123"
# A leading TL;DR no longer exempts the details from the structure limits (#419).
summary_first="## TL;DR

Keep complete details after the summary.

## How it works

$dense

https://github.com/example/repo/issues/123"
summary_tail=$'\n\n## TL;DR\n\nShort summary.\n\n## How it works\n\nRetry a failed call once.\n\nhttps://github.com/example/repo/issues/123'
for operation in 'pr create --draft' 'pr comment 7' 'pr review 7 --comment' \
  'issue create --title Bug' 'issue edit 7' 'issue comment 7' 'discussion create --title Topic'; do
  check "$operation rejects a long sentence" "gh $operation --body '$dense'" deny 'A sentence has 41 words'
  check "$operation rejects a long sentence before its summary" \
    "gh $operation --body '$dense$summary_tail'" deny 'A sentence has 41 words; keep 25 or fewer'
  check "$operation accepts a structured document over 60 words" \
    "gh $operation --body '$structured'" allow
  check "$operation rejects a long sentence after a leading TL;DR" \
    "gh $operation --body '$summary_first'" deny 'A sentence has 41 words'
  check "$operation accepts a summary" "gh $operation --body '## TL;DR

Retry only failed requests.

## How it works

Retry a failed call once. Verified with the timeout test. https://github.com/example/repo/issues/123'" allow
done
check 'draft requires inspectable body' 'gh pr create --draft --title WIP' deny
check 'issue requires inspectable body' 'gh issue create --title Bug' deny
check 'interactive comment' 'gh pr comment 7' deny
check 'body file cannot bind published bytes' 'gh issue comment 7 --body-file /tmp/body.md' deny
check 'stdin is opaque' 'gh pr comment 7 -F -' deny
check 'expanded body is opaque' 'gh issue comment 7 --body "$BODY"' deny
check 'globbed body is opaque' 'gh issue comment 7 --body *' deny
check 'editor can overwrite body' "gh issue comment 7 --body Short --editor" deny
check 'metadata operand is not a body' 'gh issue create --label --body --title Bug' deny
check 'attached short body' "gh issue comment 7 -b'## TL;DR

Fixed.'" allow
check 'attached long body' "gh issue comment 7 --body='$dense'" deny
check 'sentence limit' "gh issue comment 7 --body '$dense'" deny 'A sentence has 41 words; keep 25 or fewer'
check 'no denial suggests a TL;DR for structure' "gh issue comment 7 --body '$dense'" deny 'Structure limits broken'
[[ "$last_check_output" != *'TL;DR'* ]] && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); printf 'FAIL structure denial mentions a TL;DR: %s\n' "$last_check_output"; }
check '25-word sentence' "gh issue comment 7 --body '$(printf 'word %.0s' {1..24})word.'" allow
check '26-word sentence' "gh issue comment 7 --body '$(printf 'word %.0s' {1..25})word.'" deny 'A sentence has 26 words'
check 'two-item list' "gh issue comment 7 --body '- One.
- Two.'" allow
check 'bullet limit' "gh issue comment 7 --body '$bullet'" deny 'A list has 1 items; keep 2–7'
check 'two-level list' "gh issue comment 7 --body '- One.
  - A.
  - B.
- Two.'" allow
check 'one-item sub-list' "gh issue comment 7 --body '- One.
  - Inner.
- Two.'" deny 'A sub-list has 1 items; keep 2–3'
check 'four-level list' "gh issue comment 7 --body '- One.
  - A.
    - x.
      - deep.
      - deeper.
    - y.
  - B.
- Two.'" deny 'A list nests 4 levels; keep 3 or fewer'
check 'a later TL;DR leaves the sentence limit' "gh issue comment 7 --body '$dense

## TL;DR

Summary last.'" deny 'A sentence has 41 words'
check 'one denial lists both corrections' "gh issue create --title Bug --body '$(printf 'word %.0s' {1..25})word.'" deny 'TL;DR heading missing'
[[ "$last_check_output" == *'A sentence has 26 words'* ]] && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); printf 'FAIL one denial lists both corrections: %s\n' "$last_check_output"; }
check 'long code example keeps its summary' "gh issue comment 7 --body '## TL;DR

Explain the example.

## Example

~~~
$long
~~~'" allow
check '41 Chinese characters skip the word limit' "gh issue comment 7 --body '$(printf '字%.0s' {1..41})。'" allow
check '4 Chinese sentences exceed a block' "gh issue comment 7 --body '它失败了。然后重试。再来一次。最后一次。'" deny 'A prose block has 4 sentences'
check '39-word summary' "gh issue create --title Bug --body '## TL;DR

$(printf 'word %.0s' {1..39})'" allow
check '40-word summary' "gh issue create --title Bug --body '## TL;DR

$(printf 'word %.0s' {1..40})'" deny 'TL;DR has 40 words (limit 39)'
# A comment of 80 words or fewer reads whole, so it needs no TL;DR; documents and
# longer comments keep the summary (#265). Structure limits apply at any length (#419).
eighty="$(printf 'Ten more words keep this comment body under the exemption.\n\n%.0s' {1..8})"
check 'short comment needs no summary' "gh issue comment 7 --body 'Fixed in #263.'" allow
check '80-word comment needs no summary' "gh pr comment 7 --body '$eighty'" allow
check '81-word comment needs a summary' "gh issue comment 7 --body '$eighty

word'" deny 'TL;DR'
check 'short review body needs no summary' "gh pr review 7 --comment --body 'Looks right.'" allow
check 'short close comment needs no summary' "gh issue close 7 --comment 'Fixed by #263.'" allow
check 'short REST comment needs no summary' "gh api repos/o/r/issues/7/comments -f body='Thanks.'" allow
check 'short issue body keeps the summary' "gh issue create --title Bug --body 'Fixed in #263.'" deny 'TL;DR'
check 'short REST issue body keeps the summary' "gh api repos/o/r/issues -f title=Bug -f body='Short.'" deny 'TL;DR'
check 'REST owner named comments keeps the summary' "gh api repos/comments/r/issues -f title=Bug -f body='Short.'" deny 'TL;DR'
check 'short comment keeps the privacy check' "gh issue comment 7 --body 'See /Users/me/notes.'" deny 'private context'
check 'short comment keeps the structure limits' "gh issue comment 7 --body '- $(printf 'word %.0s' {1..50})'" deny 'A sentence has 50 words'
# GitHub enforces its own body limit, so the hook adds none (#310).
long_document="$structured

## Example

~~~
$(printf 'x%.0s' {1..8001})
~~~"
check 'structured document over 8,000 characters' "gh issue comment 7 --body '$long_document'" allow
check 'privacy check past 8,000 characters' "gh issue comment 7 --body '$long_document

See /Users/me/notes.'" deny 'private context'
# The checks after the shell scan stay fast at the largest body GitHub accepts, 125,000
# characters of release notes, including whitespace runs in the privacy scan and in a
# heading. Time them directly; the shell scan's cost grows with the whole command.
timed_writing_check() { # name, check function, text, expected status, optional size
  local timed status elapsed
  timed="$(
    source "$PLUGIN/.agents/lib/reply-summary.sh"
    source "$PLUGIN/.agents/lib/concise-writing.sh"
    source "$PLUGIN/.agents/lib/github-writing.sh"
    start="$(perl -MTime::HiRes=time -e 'print time')"
    "$2" "$3" >/dev/null
    status=$?
    perl -MTime::HiRes=time -e 'printf "%s %.3f", $ARGV[0], time - $ARGV[1]' -- "$status" "$start"
  )"
  read -r status elapsed <<< "$timed"
  if (( ${#3} == ${5:-125000} )) && [[ "$status" == "$4" ]] \
     && perl -e 'exit($ARGV[0] < 2 ? 0 : 1)' -- "$elapsed"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: %s characters, status %s (want %s) in %s s (limit 2 s)\n' \
      "$1" "${#3}" "$status" "$4" "$elapsed"
  fi
}
max_prefix="$structured"$'\n\n~~~\n'
timed_writing_check '125,000-character document' github_writing_check_body \
  "$max_prefix$(perl -e 'print "x" x shift' $((125000 - ${#max_prefix} - 4)))"$'\n~~~' 0
timed_writing_check 'privacy scan of "<" before a whitespace run' github_writing_check_privacy \
  "<$(perl -e 'print " " x 124999')" 0
heading_tail=$'\n\nShort.'
timed_writing_check 'heading holding a whitespace run' github_writing_check_body \
  "## a$(perl -e 'print " " x shift' $((125000 - 5 - ${#heading_tail})))b$heading_tail" 1
large_document="$max_prefix$(perl -e 'print "x" x shift' $((262145 - ${#max_prefix} - 4)))"$'\n~~~'
timed_writing_check 'document above the former character ceiling' \
  github_writing_check_body "$large_document" 0 262145
private_tail=$'\n\nSee /home/test/notes.'
timed_writing_check 'privacy still applies above the former ceiling' \
  github_writing_check_body "$large_document$private_tail" 1 "$((262145 + ${#private_tail}))"
check 'release notes' "gh release create v1 --notes '$dense'" deny
check 'short release notes' "gh release create v1 --notes '## TL;DR

Fixed.'" allow
check 'generated notes are opaque' 'gh release create v1 --generate-notes' deny
check 'close comment' "gh issue close 7 --comment '$dense'" deny
check 'reopen comment' "gh pr reopen 7 -c '$dense'" deny
for operation in 'pr close' 'issue close' 'pr reopen' 'issue reopen'; do
  check "$operation without a comment" "gh $operation 7" allow
  check "$operation short comment" "gh $operation 7 --comment '## TL;DR

Fixed.'" allow
  check "$operation dense comment" "gh $operation 7 -c '$dense'" deny
  check "$operation empty comment" "gh $operation 7 --comment ''" deny
  check "$operation expanded comment" "gh $operation 7 --comment \"\$BODY\"" deny
done
check 'REST raw body' "gh api repos/o/r/issues/7/comments -f body='$dense'" deny
check 'REST typed body' "gh api repos/o/r/issues/7/comments -Fbody='$dense'" deny
check 'REST concise body' "gh api repos/o/r/issues/7/comments -f 'body=## TL;DR

Fixed.'" allow
for field in body description 'comments[][body]'; do
  check 'REST structured document over 120 words' \
    "gh api repos/o/r/issues/7 -f '$field=$structured'" allow
done
check 'REST typed structured document over 120 words' \
  "gh api repos/o/r/issues/7 -F 'body=$structured'" allow
check 'structured release notes over 120 words' \
  "gh release create v1 --notes '$structured'" allow
check 'REST nested review body' "gh api repos/o/r/pulls/7/reviews -f 'comments[][body]=$dense'" deny
check 'REST input is opaque' 'gh api repos/o/r/issues/7/comments --input /tmp/body.json' deny
check 'REST explicit GET has no published body' "gh api repos/o/r/issues -X GET -f body='$dense'" allow
check 'GraphQL text mutation is opaque' 'gh api graphql -f query="mutation { addComment(input: {subjectId: \"x\", body: \"Hi\"}) { clientMutationId } }"' deny
check 'read-only list' 'gh issue list --label "$LABEL"' allow
check 'read-only API' 'gh api repos/o/r/issues/7/comments' allow
check 'read-only API with dynamic endpoint' 'gh api "$ENDPOINT"' allow
check 'GraphQL query' 'gh api graphql -f query="query { viewer { login } }"' allow
check 'GraphQL non-writing mutation' 'gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \"x\"}) { clientMutationId } }"' allow
for separator in $' # note\n' $'# note\r' $', # first\r\n # second\n,' $'\357\273\277' ','; do
  check 'GraphQL ignored tokens before arguments' \
    "gh api graphql -f 'query=mutation { createIssue${separator}(input: {repositoryId: \"x\", title: \"Bug\", body: \"Hi\"}) { clientMutationId } }'" deny
done
check 'GraphQL comment mentioning a mutation' \
  "gh api graphql -f 'query=query { # addComment(input: ...)
viewer { login } }'" allow
check 'GraphQL quoted mutation mention' \
  'gh api graphql -f '\''query=query { repository(owner: "o", name: "addComment(input: x)") { id } }'\''' allow
check 'GraphQL hash in a string does not hide a later mutation' \
  'gh api graphql -f '\''query=mutation { resolveReviewThread(input: {threadId: "#"}) { clientMutationId } addComment # note
(input: {subjectId: "x", body: "Hi"}) { clientMutationId } }'\''' deny
check 'GraphQL block string mutation mention' \
  'gh api graphql -f '\''query=query { repository(owner: "o", name: """addComment(input: x)""") { id } }'\''' allow
check 'GraphQL escaped quotes do not hide a later mutation' \
  'gh api graphql -f '\''query=mutation { resolveReviewThread(input: {threadId: "\"#"}) { clientMutationId } addComment # note
(input: {subjectId: "x", body: "Hi"}) { clientMutationId } }'\''' deny
check 'metadata edit' 'gh issue edit 7 --add-label bug' allow
check 'bodyless approval' 'gh pr review 7 --approve' allow
check 'comment deletion' 'gh pr comment 7 --delete-last --yes' allow
check 'literal mention' "echo 'gh issue comment 7 --body $dense'" allow
check 'absolute gh path' "/usr/local/bin/gh issue comment 7 --body '$dense'" deny
check 'command wrapper' "command gh issue comment 7 --body '$dense'" deny
for wrapper in command exec env; do
  check "$wrapper permits inspectable writing" "$wrapper gh issue comment 7 --body '## TL;DR

Fixed.'" allow
done
for wrapper in nohup sudo doas 'nice -n 5' 'stdbuf -oL' setsid 'timeout 30' 'xargs -I{}' 'xargs -I{item}' 'xargs -I {item}' /usr/bin/env 'sudo nohup'; do
  check "$wrapper cannot bypass writing checks" "$wrapper gh issue comment 7 --body '$dense'" deny
  check "$wrapper leaves execution opaque" "$wrapper gh issue comment 7 --body '## TL;DR

Fixed.'" deny
  check "$wrapper read-only command" "$wrapper gh issue list" allow
done
check 'launcher with global flags' "nohup gh -R o/r issue comment 7 --body '$dense'" deny
check 'launcher with REST writing' "sudo gh api repos/o/r/issues/7/comments -f body='$dense'" deny
check 'launcher with release notes' "timeout 30 gh release create v1 --notes '$dense'" deny
check 'nested shell with launcher' "bash -c \"nohup gh issue comment 7 --body '$dense'\"" deny
check 'repo flag between noun and verb' "gh issue -R o/r comment 7 --body '$dense'" deny
check 'PR repo flag between noun and verb' "gh pr -R o/r comment 7 --body '$dense'" deny
check 'compound command catches later write' "true && gh issue comment 7 --body '$dense'" deny
check 'nested shell catches write' "bash -c \"gh issue comment 7 --body '$dense'\"" deny

# gh parses options with pflag (#308): each spelling gh 2.92.0 accepts gets the same
# decision, and an option gh rejects gets a parse diagnostic instead of writing advice.
for command in 'gh api --help' 'gh api -p corsair repos/o/r' 'gh issue close 7 --duplicate-of 5' \
  'gh release edit v1 --tag v2' 'gh release edit v1 --prerelease=false' \
  'gh pr comment 7 --delete-last --yes=true' "gh issue create --title Bug --body '## TL;DR

Fixed.' -a@me" 'gh api -HAccept:x repos/o/r' 'gh api -iq .name repos/o/r' 'gh api -- repos/o/r' \
  "gh issue comment 7 --body '$dense' --help" "gh issue comment 7 -h --body '$dense'" \
  'gh issue comment 7 --body-file notes.md --help=T' \
  'gh issue close 7 2>/dev/null' 'gh pr comment 7 --body "Done." 2>&1' 'gh issue close 7 > out' \
  'gh issue close 7 >>log 2>&1' 'gh issue close 7 >|out 1>&2 2>&-'; do
  check "gh accepts: ${command//$dense/<dense>}" "$command" allow
done
for rejection in 'gh api repos/o/r --output x|Unrecognized gh api option `--output`; nothing was authorized. Check `gh help api`.' \
  'gh api repos/o/r --output=x|Unrecognized gh api option `--output`' \
  'gh api -Z repos/o/r|Unrecognized gh api option `-Z`' \
  'gh api repos/o/r -H|gh api option `-H` needs a value' \
  'gh issue comment 7 --help=maybe|gh issue comment option `--help` takes true or false'; do
  check "gh rejects: ${rejection%%|*}" "${rejection%%|*}" deny "${rejection#*|}"
  if [[ "$last_check_output" != *boxlite-writing* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf 'FAIL option error carries the writing reminder: %s\n' "${rejection%%|*}"
  fi
done
for command in 'gh issue comment 7 --body-file notes.md --help=false' \
  "gh pr comment 7 --help --help=false --body '$dense'" \
  'gh pr comment 7 >! --body --body-file=x' \
  "gh api repos/o/r/issues/1/comments --jq 12>&1 -fbody='$dense'" \
  "gh api repos/o/r/issues/1/comments --jq \"2\">&1 -fbody='$dense'" \
  "gh api repos/o/r/issues/1/comments --jq \\2>&1 -fbody='$dense'" \
  "gh api repos/o/r/issues/1/comments -f>out body='$dense'" \
  "gh pr comment 7 --body '$dense' 2>&1" \
  "gh api repos/o/r/issues/1/comments -if body='$dense'" \
  "gh api repos/o/r/issues/1/comments -H --help -f body='$dense'" \
  'gh issue comment 7 -- --body x' \
  "gh issue > out comment 7 --body '$dense'" \
  "gh release 2>&1 create v1 --notes '$dense'" \
  'gh api graphql -F query=@- < mutation.graphql' 'gh api graphql -F query=@- 0>&3'; do
  check "still denied: ${command//$dense/<dense>}" "$command" deny
done

private_text='Per our private conversation, PRIVATE_CANARY must stay unpublished.'
private_body="## TL;DR

Fix request validation.

## Context

$private_text

https://github.com/example/repo/issues/123"
for operation in 'pr create --draft' 'pr comment 7' 'pr review 7 --comment' \
  'issue create --title Bug' 'issue edit 7' 'issue comment 7' \
  'discussion create --title Topic' 'pr close 7'; do
  flag=--body
  [[ "$operation" != 'pr close 7' ]] || flag=--comment
  check "$operation blocks private attribution" "gh $operation $flag '$private_body'" deny 'private context'
done
for text in '<oai-mem-citation>PRIVATE_CANARY</oai-mem-citation>' \
  '<hook_prompt>PRIVATE_CANARY</hook_prompt>' '<environment_context>PRIVATE_CANARY</environment_context>' \
  '<  / environment_context>PRIVATE_CANARY' '&lt; user_instructions&gt; PRIVATE_CANARY' \
  'As you told me, PRIVATE_CANARY.' 'The user asked me to add PRIVATE_CANARY.' \
  'From the internal chat: PRIVATE_CANARY.' '根据私聊记录，PRIVATE_CANARY。' \
  '/Users/PRIVATE_CANARY/work/file.txt' '/home/PRIVATE_CANARY/file.txt' \
  'C:\Users\PRIVATE_CANARY\file.txt' '.codex/sessions/PRIVATE_CANARY.jsonl' \
  'See `.codex/sessions/PRIVATE_CANARY.jsonl` for the transcript.'; do
  check 'private context cannot be quoted or hidden' "gh issue comment 7 --body '## TL;DR

Fix validation.

~~~
$text
~~~'" deny 'private context'
done
for option in "--title '$private_text'" "--title='$private_text'" "-t'$private_text'"; do
  check 'issue title privacy' "gh issue edit 7 $option" deny 'private context'
done
check 'opaque REST title file cannot bypass privacy' 'gh api repos/o/r/issues/7 -F title=@private.txt' deny
check 'PR title privacy' "gh pr edit --title 'fix: as you told me, PRIVATE_CANARY' --body '## TL;DR

Fix validation. https://github.com/example/repo/issues/123'" deny 'private context'
check 'release title privacy' "gh release edit v1 --title '$private_text'" deny 'private context'
check 'release notes privacy' "gh release edit v1 --notes '$private_body'" deny 'private context'
for field in body title description notes 'comments[][body]'; do
  check 'REST field privacy' "gh api repos/o/r/issues/7 -f '$field=$private_body'" deny 'private context'
done
check 'REST typed title privacy' "gh api repos/o/r/issues/7 -F 'title=$private_text'" deny 'private context'
if [[ "$last_check_output" != *PRIVATE_CANARY* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL privacy denial echoed rejected text\n'
fi
for text in 'Private messages require authorization before disclosure.' \
  'A public issue requests better retry handling: https://github.com/example/repo/issues/123' \
  'The parser handles user input and the private field.'; do
  check 'public technical writing remains allowed' "gh issue comment 7 --body '## TL;DR

$text'" allow
done
check 'ordinary title needs no summary heading' "gh issue edit 7 --title 'Fix validation'" allow
check 'read-only REST does not publish private parameters' \
  "gh api repos/o/r/issues -X GET -f 'title=$private_text'" allow
mkdir -p .agents/state
jq -nc --arg command "gh pr create --title 'fix: validation' --body '$structured'" \
  '{tool_input:{command:$command}}' | bash "$HOOK" >/dev/null
review_state=.agents/state/pr-review-request.json
request_id="$(jq -r .id "$review_state")"
bash -c '
  source "$1/.agents/lib/timed-user-prompt.sh"
  timed_user_prompt prompt-reply "$2" "$3" "reviewed: $3 fixture validation"
' fixture "$PLUGIN" "$review_state" "$request_id" >/dev/null
cp "$review_state" "$scratch/review-before"
check 'privacy denial precedes acknowledgment consumption' \
  "gh pr create --title 'fix: validation' --body '$private_body'" deny 'private context'
if cmp -s "$review_state" "$scratch/review-before"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL privacy denial changed acknowledgment\n'
fi
check 'safe rewrite can still consume the preserved acknowledgment' \
  "gh pr create --title 'fix: validation' --body '## TL;DR

Fix validation. https://github.com/example/repo/issues/123'" allow
if jq -e '.status=="consumed"' "$review_state" >/dev/null; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); printf 'FAIL safe rewrite did not consume acknowledgment\n'
fi

PRIVACY_TEST_PERL="$(command -v perl)"
export PRIVACY_TEST_PERL
cat > "$scratch/bin/perl" <<'PERL'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" != *'my $private = qr{'* ]] || exit 2
done
exec "$PRIVACY_TEST_PERL" "$@"
PERL
chmod +x "$scratch/bin/perl"
check 'scanner failure blocks publication' "gh issue comment 7 --body '## TL;DR

Fix validation.'" deny 'private context check failed'

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
