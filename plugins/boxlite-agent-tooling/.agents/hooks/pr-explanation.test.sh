#!/usr/bin/env bash
# Public-hook regression cases captured from GitHub POST /markdown on 2026-09-26.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GH_HOST GH_REPO
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=test \
  -c user.email=test@example.invalid commit -qm fixture --allow-empty
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
export EXPLANATION_FIXTURE="$scratch/render.json"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api --hostname github.com markdown -f mode=gfm -f text='*)
    jq -er --arg body "${8#text=}" 'select(.body == $body) | .html' "$EXPLANATION_FIXTURE" ;;
  'api --hostname github.com repos/example/repo/issues/1')
    jq -nc '{html_url:"https://github.com/example/repo/issues/1",body:"## TL;DR\n\nDesign the change."}' ;;
  'repo view '*) printf '{"nameWithOwner":"example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api repos/example/repo/commits/'*) jq -nc --arg sha "$(git rev-parse HEAD)" '{sha:$sha}' ;;
  'api repos/example/repo/compare/'*) jq -nc --arg sha "$(git rev-parse HEAD)" '{base_commit:{sha:$sha},files:[]}' ;;
  'pr view '*) jq -c --arg sha "$(git rev-parse HEAD)" \
    '{body,baseRefOid:$sha,headRefOid:$sha,headRefName:"feature",additions:0,deletions:0}' "$EXPLANATION_FIXTURE" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch/repo"
cd "$scratch/repo"
bash "$plugin/scripts/design-doc.sh" bind https://github.com/example/repo/issues/1 >/dev/null
pass=0 fail=0
while IFS= read -r fixture; do
  printf '%s\n' "$fixture" > "$EXPLANATION_FIXTURE"
  name="$(jq -r .name <<<"$fixture")"
  body="$(jq -r .body <<<"$fixture")"
  valid="$(jq -r .valid <<<"$fixture")"
  for operation in draft create edit ready metadata; do
    case "$operation" in
      draft) command="gh pr create --draft --title 'feat: retry once' --body '$body'" ;;
      create) command="gh pr create --title 'feat: retry once' --body '$body'" ;;
      edit) command="gh pr edit 1 --title 'feat: retry once' --body '$body'" ;;
      ready) command='gh pr ready 1' ;;
      metadata) command='gh pr edit 1 --add-label safe' ;;
    esac
    # A denial must leave the caller's approval state untouched.
    printf '{"fixture":"preserve"}\n' > .agents/state/pr-reviewed.json
    cp .agents/state/pr-reviewed.json "$scratch/marker-before"
    output="$(jq -nc --arg command "$command" '{tool_input:{command:$command}}' \
      | bash "$plugin/.agents/hooks/preflight-pr-review.sh")"
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$output")"
    if { [[ "$valid" == false && "$reason" == 'PR description requires a nonempty ## How it works section.'* ]] ||
         [[ "$valid" == true && "$operation" == draft && -z "$output" ]] ||
         [[ "$valid" == true && "$operation" != draft && "$reason" == *'Review required'* ]]; } \
       && cmp -s .agents/state/pr-reviewed.json "$scratch/marker-before"; then
      pass=$((pass+1))
    else
      printf 'FAIL %s/%s: valid=%s; %s\n' "$name" "$operation" "$valid" "$output"
      fail=$((fail+1))
    fi
  done
done < "$plugin/.agents/hooks/fixtures/pr-explanation-render.jsonl"
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
