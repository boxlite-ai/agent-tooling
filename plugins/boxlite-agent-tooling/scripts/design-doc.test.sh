#!/usr/bin/env bash
# Provider responses cross the public CLI boundary; never contact live services.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/repo"
export DOC_FIXTURE="$scratch/response.json" DOC_CALLS="$scratch/calls"
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
github_doc $'## TL;DR\n\nVerify designs before edits.\n\nProblem: undocumented edits. Approach: verify a design doc. Validation: gate tests.'
expect 'GitHub doc can be registered' 0 bind "$url"
expect 'matching branch verifies again' 0 check
[[ "$(cat "$scratch/out")" == "$url" ]] || fail=$((fail+1))
[[ "$(wc -l < "$DOC_CALLS")" -ge 2 ]] || fail=$((fail+1))
git checkout -qb different
expect 'another branch cannot reuse binding' 1 check
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
github_doc "$(printf 'word %.0s' {1..81})"
expect 'wall of text blocks' 1 check
github_doc $'## TL;DR\n\nVerify designs before edits.\n\n- Problem: undocumented changes.\n- Approach: gate edits.\n- Validation: tests.'
expect 'compact bullet design passes' 0 check
expect 'untrusted hosts are rejected' 1 bind https://github.com.attacker.invalid/example/project/issues/1
for unsafe_url in 'https://user:sensitive-fixture@github.com/example/project/issues/1' $'https://invalid.example/\nsensitive-fixture'; do
  expect 'unsafe URL blocks' 1 bind "$unsafe_url"
  if [[ "$(cat "$scratch/err")" == *sensitive-fixture* ]]; then
    printf 'FAIL rejected URL leaks into diagnostics\n'; fail=$((fail+1))
  else
    printf 'PASS rejected URL stays out of diagnostics\n'; pass=$((pass+1))
  fi
done
state="$(git rev-parse --absolute-git-dir)/agent-tooling-design-doc.json"
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
notion_block bulleted_list_item "$(printf 'word %.0s' {1..41})"
expect 'Notion bullets keep the item density limit' 1 check
notion_block numbered_list_item "$(printf 'word %.0s' {1..41})"
expect 'Notion numbered items keep the item density limit' 1 check
notion_block to_do "$(printf 'word %.0s' {1..41})"
expect 'Notion checkboxes keep the item density limit' 1 check
notion_block code "$(printf 'word %.0s' {1..81})"
jq '.results = [{type:"heading_2",heading_2:{rich_text:[{plain_text:"TL;DR"}]}},
  {type:"paragraph",paragraph:{rich_text:[{plain_text:"A concise design."}]}},
  {type:"heading_2",heading_2:{rich_text:[{plain_text:"Examples"}]}}] + .results' \
  "$DOC_FIXTURE" > "$scratch/with-summary"
mv "$scratch/with-summary" "$DOC_FIXTURE"
expect 'Notion code examples are not prose walls' 0 check
notion_block code $'```\nexample'
jq --arg text "$(printf 'word %.0s' {1..81})" \
  '.results += [{type:"paragraph",paragraph:{rich_text:[{plain_text:$text}]}}]' \
  "$DOC_FIXTURE" > "$scratch/with-prose"
mv "$scratch/with-prose" "$DOC_FIXTURE"
expect 'code fences cannot hide the next Notion paragraph' 1 check
notion_block paragraph $'```\n'
jq --arg text "$(printf 'word %.0s' {1..81})" \
  '.results += [{type:"paragraph",paragraph:{rich_text:[{plain_text:$text}]}}]' \
  "$DOC_FIXTURE" > "$scratch/literal-fence"
mv "$scratch/literal-fence" "$DOC_FIXTURE"
expect 'literal paragraph markup cannot hide prose' 1 check
notion_block bulleted_list_item "$(printf 'word %.0s' {1..30})"$'\n\n'"$(printf 'word %.0s' {1..30})"
expect 'line breaks cannot split one Notion list item' 1 check
printf '{"object":"page","id":"01234567-89ab-cdef-0123-456789abcdef","archived":true}' > "$DOC_PAGE"
expect 'archived Notion page blocks' 1 check
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
