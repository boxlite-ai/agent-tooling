#!/usr/bin/env bash
# Exercise GitHub writing through the real PreToolUse entry point; never run gh.
# shellcheck disable=SC2016 # Test literal shell source, including expansions.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  'api --hostname github.com markdown -f mode=gfm -f text='*) [[ "${8#text=}" == *https://github.com/example/repo/issues/123* ]] || exit 2; printf '<a href="https://github.com/example/repo/issues/123">Design</a>' ;;
  'api --hostname github.com repos/example/repo/issues/123') printf '{"html_url":"https://github.com/example/repo/issues/123","body":"Design and validation."}' ;;
  'repo view '*) printf '{"nameWithOwner":"example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api repos/example/repo/commits/'*) jq -nc --arg sha "$(git rev-parse HEAD)" '{sha:$sha}' ;;
  'api repos/example/repo/compare/'*)
    jq -nc --arg sha "$(git rev-parse HEAD)" '{base_commit:{sha:$sha},files:[{additions:1,deletions:0}]}' ;;
  *) exit 2 ;;
esac
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch/repo"
cd "$scratch/repo" || exit 2
bash "$PLUGIN/scripts/design-doc.sh" bind https://github.com/example/repo/issues/123 >/dev/null

check() {
  local name="$1" command="$2" expected="$3" output status=0 actual
  output="$(jq -nc --arg command "$command" '{tool_input:{command:$command}}' | bash "$HOOK")" || status=$?
  actual="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty')"
  [[ -n "$actual" ]] || actual=allow
  if [[ "$actual" == "$expected" && "$status" == 0 ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: expected %s, got %s (exit %s)\n%s\n' "$name" "$expected" "$actual" "$status" "$output"
  fi
}

dense="$(printf 'word %.0s' {1..81})"
long="$(printf 'word %.0s' {1..121})"
bullet="- $(printf 'word %.0s' {1..41})"
for operation in 'pr create --draft' 'pr comment 7' 'pr review 7 --comment' \
  'issue create --title Bug' 'issue edit 7' 'issue comment 7' 'discussion create --title Topic'; do
  check "$operation rejects dense prose" "gh $operation --body '$dense'" deny
  check "$operation accepts a summary" "gh $operation --body 'Retry only failed requests. Verified with the timeout test. https://github.com/example/repo/issues/123'" allow
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
check 'attached short body' 'gh issue comment 7 -bFixed.' allow
check 'attached long body' "gh issue comment 7 --body='$dense'" deny
check 'paragraph limit' "gh issue comment 7 --body '$dense'" deny
check 'bullet limit' "gh issue comment 7 --body '$bullet'" deny
check 'fences do not evade total' "gh issue comment 7 --body '~~~
$long
~~~'" deny
check 'Chinese counts per character' "gh issue comment 7 --body '$(printf '字%.0s' {1..81})'" deny
check '120 words in short blocks' "gh issue comment 7 --body '$(printf 'word %.0s' {1..60})

$(printf 'word %.0s' {1..60})'" allow
check '121 words in short blocks' "gh issue comment 7 --body '$(printf 'word %.0s' {1..60})

$(printf 'word %.0s' {1..61})'" deny
check 'release notes' "gh release create v1 --notes '$dense'" deny
check 'short release notes' 'gh release create v1 --notes Fixed.' allow
check 'generated notes are opaque' 'gh release create v1 --generate-notes' deny
check 'close comment' "gh issue close 7 --comment '$dense'" deny
check 'reopen comment' "gh pr reopen 7 -c '$dense'" deny
for operation in 'pr close' 'issue close' 'pr reopen' 'issue reopen'; do
  check "$operation without a comment" "gh $operation 7" allow
  check "$operation short comment" "gh $operation 7 --comment Fixed." allow
  check "$operation dense comment" "gh $operation 7 -c '$dense'" deny
  check "$operation empty comment" "gh $operation 7 --comment ''" deny
  check "$operation expanded comment" "gh $operation 7 --comment \"\$BODY\"" deny
done
check 'REST raw body' "gh api repos/o/r/issues/7/comments -f body='$dense'" deny
check 'REST typed body' "gh api repos/o/r/issues/7/comments -Fbody='$dense'" deny
check 'REST concise body' 'gh api repos/o/r/issues/7/comments -f body=Fixed.' allow
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
  check "$wrapper permits inspectable writing" "$wrapper gh issue comment 7 --body Fixed." allow
done
for wrapper in nohup sudo doas 'nice -n 5' 'stdbuf -oL' setsid 'timeout 30' 'xargs -I{}' 'xargs -I{item}' 'xargs -I {item}' /usr/bin/env 'sudo nohup'; do
  check "$wrapper cannot bypass writing checks" "$wrapper gh issue comment 7 --body '$dense'" deny
  check "$wrapper leaves execution opaque" "$wrapper gh issue comment 7 --body Fixed." deny
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

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
