#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture --allow-empty
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
export FILE_PR_URL=https://github.com/example/repo/issues/123
export FILE_PR_SOURCE="$scratch/repo/body file.md" FILE_PR_RENDERED="$scratch/rendered" FILE_PR_SENT="$scratch/sent"
FILE_PR_REAL_PERL="$(command -v perl)"
export FILE_PR_REAL_PERL
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api --hostname github.com markdown --method POST --input - --header Content-Type: application/json; charset=utf-8')
    jq -bje 'select(.mode == "gfm") | .text' > "$FILE_PR_RENDERED"
    grep -Fq "$FILE_PR_URL" "$FILE_PR_RENDERED"
    if [[ -e "$FILE_PR_SOURCE.replace" ]]; then mv "$FILE_PR_SOURCE.replace" "$FILE_PR_SOURCE"; fi
    printf '<h2>How it works</h2><p>Check the snapshot.</p><a href="%s">Design</a>' "$FILE_PR_URL" ;;
  'api --hostname github.com repos/example/repo/issues/123')
    jq -nc --arg url "$FILE_PR_URL" '{html_url:$url,body:"## TL;DR\n\nUse the snapshot."}' ;;
  'repo view --json nameWithOwner,defaultBranchRef,url')
    printf '{"nameWithOwner":"example/repo","url":"https://github.com/example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api --hostname github.com repos/example/repo/git/ref/heads/main')
    jq -nc --arg sha "$(git rev-parse HEAD)" '{object:{type:"commit",sha:$sha}}' ;;
  'api --hostname github.com repos/example/repo/compare/'*'...refs%2Fheads%2Ffeature')
    jq -nc --arg sha "$(git rev-parse HEAD)" '{status:"identical",ahead_by:0,behind_by:0,base_commit:{sha:$sha},merge_base_commit:{sha:$sha}}' ;;
  'api --hostname github.com repos/example/repo/compare/'*)
    jq -nc --arg sha "$(git rev-parse HEAD)" --argjson lines "${FILE_PR_LINES:-1}" \
      '{base_commit:{sha:$sha},files:[{filename:"src/main.sh",additions:$lines,deletions:0}]}' ;;
  'pr view '*)
    jq -nc --arg sha "$(git rev-parse HEAD)" \
      '{number:42,url:"https://github.com/example/repo/pull/42",baseRefName:"main",baseRefOid:$sha,headRefOid:$sha,headRefName:"feature",headRepositoryOwner:{login:"example"},headRepository:{name:"repo"},body:"Previous body.",additions:1,deletions:0}' ;;
  'pr create '*|'pr edit '*)
    printf '%s\n' "$@" > "$FILE_PR_SENT.args"
    grep -Fxq -- --body-file=- "$FILE_PR_SENT.args"
    cat > "$FILE_PR_SENT"
    if [[ -n "${FILE_PR_STDOUT:-}" ]]; then printf '%s\n' "$FILE_PR_STDOUT"; fi
    exit "${FILE_PR_EXIT:-0}" ;;
  *) exit 2 ;;
esac
GH
cat > "$scratch/bin/perl" <<'PERL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FILE_PR_SWAP:-}" && "${4:-}" == "$FILE_PR_SOURCE" ]]; then
  rm "$FILE_PR_SOURCE"
  if [[ "$FILE_PR_SWAP" == fifo ]]; then
    mkfifo "$FILE_PR_SOURCE"
  else
    ln -s "$FILE_PR_SOURCE.original" "$FILE_PR_SOURCE"
  fi
fi
exec "$FILE_PR_REAL_PERL" "$@"
PERL
chmod +x "$scratch/bin/"{gh,perl}
export PATH="$scratch/bin:$PATH" CODEX_THREAD_ID=codex-file-pr
unset CLAUDE_CODE_SESSION_ID GH_HOST GH_REPO GIT_DIR GIT_WORK_TREE BOXLITE_PR_WATCH
cd "$scratch/repo"
bash "$plugin/scripts/design-doc.sh" register "$FILE_PR_URL" >/dev/null
hook="$plugin/.agents/hooks/preflight-pr-review.sh"
launcher="$plugin/scripts/gh-pr.sh"
title='feat: keep the approved description'
request=.agents/state/pr-review-request.json
reply_to_request() {
  jq -nc --arg id "$1" --arg session "$(jq -er .spec.binding.session "$request")" '
    {hook_event_name:"UserPromptSubmit", session_id:$session,
     prompt:("reviewed: " + $id + " checked PR description")}' |
    CLAUDE_PROJECT_DIR="$PWD" bash "$plugin/.agents/hooks/cancel-verdict-audit.sh"
}

approve() {
  reply_to_request "$(jq -er .id "$request")" >/dev/null
  jq -e '.status == "accepted"' "$request" >/dev/null
}

reject() {
  local expected="$1" output
  shift
  rm -f "$FILE_PR_SENT.args"
  if output="$("$@" 2>&1)" || [[ "$output" != *"$expected"* || -e "$FILE_PR_SENT.args" ]]; then
    printf 'FAIL: expected denial matching %s, got %s\n' "$expected" "$output" >&2
    exit 1
  fi
}

launch() {
  bash "$launcher" "$@"
}

hook_command() {
  jq -nc --arg session "$1" --arg command "$2" '{session_id:$session,tool_input:{command:$command}}' | bash "$hook"
}

direct="bash '$launcher' create --title '$title' --body-file 'body file.md'"
[[ -z "$(hook_command "$CODEX_THREAD_ID" "$direct")" ]]
[[ -z "$(hook_command "$CODEX_THREAD_ID" "env -- $direct")" ]]
[[ -z "$(hook_command "$CODEX_THREAD_ID" "printf '%s\\n' '$launcher'")" ]]
for unsafe in "CODEX_THREAD_ID=other $direct" "env CODEX_THREAD_ID=other $direct" \
  "env -- CODEX_THREAD_ID=other $direct" "export CODEX_THREAD_ID=other; $direct" \
  "export CODEX_THREAD_ID=other; source ${direct#bash }" \
  "export CODEX_THREAD_ID=other; command . ${direct#bash }" \
  "timeout 10 $direct" "bash -c \"$direct\"" \
  "zsh -c \"export CODEX_THREAD_ID=other; $direct\"" \
  "dash -c \"export CODEX_THREAD_ID=other; $direct\""; do
  if [[ "$(hook_command "$CODEX_THREAD_ID" "$unsafe" | jq -r .hookSpecificOutput.permissionDecision)" != deny ]]; then
    printf 'FAIL: launcher accepted unsafe context %s\n' "$unsafe" >&2
    exit 1
  fi
done
[[ -z "$(hook_command "$CODEX_THREAD_ID" "env printf '%s\\n' '$launcher'")" ]]
[[ "$(hook_command other "$direct" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]]
[[ "$(hook_command '' "$direct" | jq -r .hookSpecificOutput.permissionDecision)" == deny ]]

printf '## TL;DR\r\n\r\nRésumé with checked bytes.\r\n\n## How it works\n\n%s\n\n```text\n' "$FILE_PR_URL" > "$FILE_PR_SOURCE"
printf '%s\n' $'"quoted" apostrophe: it\x27s, $(exit 99) and `exit 98`' >> "$FILE_PR_SOURCE"
bytes="$(wc -c < "$FILE_PR_SOURCE")"
printf '%*s\n```\r\n\n' "$((24576 - bytes - 7))" '' >> "$FILE_PR_SOURCE"
cp "$FILE_PR_SOURCE" "$FILE_PR_SOURCE.original"
[[ "$(wc -c < "$FILE_PR_SOURCE")" -eq 24576 ]]

reject 'reviewed:' launch create --title "$title" --body-file "$FILE_PR_SOURCE"
old_id="$(jq -r .id "$request")"
[[ "$(jq -r .spec.binding.body_sha256 "$request")" == "$(shasum -a 256 < "$FILE_PR_SOURCE" | awk '{print $1}')" ]]
approve
perl -pe 's/exit 99/exit 97/' "$FILE_PR_SOURCE.original" > "$FILE_PR_SOURCE"
reject 'reviewed:' launch create --title "$title" --body-file "$FILE_PR_SOURCE"
[[ "$(jq -r .id "$request")" != "$old_id" ]]
reply_to_request "$old_id" >/dev/null
jq -e '.status == "pending"' "$request" >/dev/null
approve
CODEX_THREAD_ID=other reject 'reviewed:' launch create --title "$title" --body-file "$FILE_PR_SOURCE"
reject 'one active' env -u CODEX_THREAD_ID bash "$launcher" create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
reject 'one active' env CLAUDE_CODE_SESSION_ID=claude-file-pr bash "$launcher" create --draft --title "$title" --body-file "$FILE_PR_SOURCE"

cp "$FILE_PR_SOURCE.original" "$FILE_PR_SOURCE"
reject 'reviewed:' launch create --title "$title" --body-file "$FILE_PR_SOURCE"
approve
printf 'replacement after the checks start\n' > "$FILE_PR_SOURCE.replace"
launch create --title "$title" --body-file "$FILE_PR_SOURCE" --label 'keep spaces'
cmp "$FILE_PR_SOURCE.original" "$FILE_PR_RENDERED"
cmp "$FILE_PR_SOURCE.original" "$FILE_PR_SENT"
grep -Fxq 'keep spaces' "$FILE_PR_SENT.args"
jq -e '.status == "consumed"' "$request" >/dev/null
[[ "$(< "$FILE_PR_SOURCE")" == 'replacement after the checks start' ]]

cp "$FILE_PR_SOURCE.original" "$FILE_PR_SOURCE"
CODEX_THREAD_ID='' CLAUDE_CODE_SESSION_ID=claude-file-pr reject 'reviewed:' \
  launch edit 42 -t "$title" -F "$FILE_PR_SOURCE"
[[ "$(jq -r .spec.binding.session "$request")" == claude-file-pr ]]
approve
CODEX_THREAD_ID='' CLAUDE_CODE_SESSION_ID=claude-file-pr launch edit 42 -t "$title" -F "$FILE_PR_SOURCE"
cmp "$FILE_PR_SOURCE.original" "$FILE_PR_SENT"
launch create --draft --title "$title" '--body-file=./body file.md'
cmp "$FILE_PR_SOURCE.original" "$FILE_PR_SENT"
pr_url=https://github.com/example/repo/pull/42
repo_digest="$(printf '%s' "$(pwd -P)" | shasum -a 256 | awk '{print $1}')"
result="$(FILE_PR_STDOUT="$pr_url" launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE" 2>&1)"
if [[ "$result" != "$pr_url"$'\n'"boxlite-pr-write $repo_digest $pr_url" ]]; then
  printf 'FAIL: completed checked write did not confirm its PR and checkout\n' >&2
  exit 1
fi
result="$(FILE_PR_STDOUT="$pr_url" launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE" --dry-run 2>&1)"
[[ "$result" == "$pr_url" ]]
status=0
result="$(FILE_PR_STDOUT="$pr_url" FILE_PR_EXIT=17 launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE" 2>&1)" || status=$?
[[ "$status" == 17 && "$result" == "$pr_url" ]]

FILE_PR_LINES=401 reject 'Bypass limit' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
reject 'title must' launch create --title 'Bad title' --body-file "$FILE_PR_SOURCE"
reject 'Supply one PR body' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE" \
  --body "$(< "$FILE_PR_SOURCE")"
reject 'Use gh-pr.sh' launch ready --title "$title" --body-file "$FILE_PR_SOURCE"
reject 'regular PR body file' launch create --draft --title "$title" --body-file -
printf x >> "$FILE_PR_SOURCE"
reject '24 KiB' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf '\377' > "$FILE_PR_SOURCE"
reject 'valid UTF-8' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf 'nul\0byte' > "$FILE_PR_SOURCE"
reject 'without NUL' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf 'Missing summary\n' > "$FILE_PR_SOURCE"
reject 'TL;DR' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf '## TL;DR\n\nRead /Users/example/private/file.\n\n## How it works\n\n%s\n' "$FILE_PR_URL" > "$FILE_PR_SOURCE"
reject 'private context' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf '## TL;DR\n\nMissing design.\n\n## How it works\n\nLink omitted.\n' > "$FILE_PR_SOURCE"
reject 'render the PR body' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"

for swap in fifo symlink; do
  cp "$FILE_PR_SOURCE.original" "$FILE_PR_SOURCE"
  FILE_PR_SWAP="$swap" reject 'Cannot read PR body file' launch create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
  rm "$FILE_PR_SOURCE"
done

mkdir -p "$scratch/broken/scripts" "$scratch/broken/.agents/hooks"
cp "$launcher" "$scratch/broken/scripts/"
cp "$hook" "$scratch/broken/.agents/hooks/"
reject 'No such file' bash "$scratch/broken/scripts/gh-pr.sh" create --draft --title "$title" --body-file "$FILE_PR_SOURCE"
printf 'PR body file: gates, retry binding, file swaps, and byte-exact transport passed\n'
