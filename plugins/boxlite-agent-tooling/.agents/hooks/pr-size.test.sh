#!/usr/bin/env bash
# Exercise size enforcement through the existing public PR hook.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
SIZE_TEST_BASE="$(git -C "$scratch/repo" rev-parse HEAD)"
git -C "$scratch/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m feature
SIZE_TEST_HEAD="$(git -C "$scratch/repo" rev-parse HEAD)"
export SIZE_TEST_BASE SIZE_TEST_HEAD
export SIZE_TEST_LINES=401
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api --hostname github.com markdown -f mode=gfm -f text='*) [[ "${8#text=}" == *https://github.com/example/repo/issues/123* ]] || exit 2; printf '<h2>How it works</h2><p>The handler retries a failed call once.</p><a href="https://github.com/example/repo/issues/123">Design</a>' ;;
  'api --hostname github.com repos/example/repo/issues/123') printf '{"html_url":"https://github.com/example/repo/issues/123","body":"## TL;DR\\n\\nDesign and validation."}' ;;
  'repo view '*) printf '{"nameWithOwner":"example/repo","defaultBranchRef":{"name":"main"}}' ;;
  'api repos/example/repo/commits/'*) jq -nc --arg sha "$SIZE_TEST_HEAD" '{sha:$sha}' ;;
  'api repos/example/repo/compare/'*)
    jq -nc --arg base "$SIZE_TEST_BASE" --argjson lines "$SIZE_TEST_LINES" \
      '{base_commit:{sha:$base},files:[{additions:$lines,deletions:0}]}' ;;
  'pr view '*)
    jq -nc --arg base "$SIZE_TEST_BASE" --arg head "$SIZE_TEST_HEAD" --argjson lines "$SIZE_TEST_LINES" \
      '{baseRefOid:$base,headRefOid:$head,headRefName:"feature",additions:$lines,deletions:0,body:"## TL;DR\n\nFixture summary.\n\n## How it works\n\nRetry failed calls once.\n\nhttps://github.com/example/repo/issues/123"}' ;;
  *) exit 2 ;;
esac
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
export CLAUDE_PROJECT_DIR="$scratch/repo"
cd "$scratch/repo"
bash "$plugin/scripts/design-doc.sh" bind https://github.com/example/repo/issues/123 >/dev/null
call_hook() {
  jq -nc --arg command "$1" '{tool_input:{command:$command}}' \
    | bash "$plugin/.agents/hooks/preflight-pr-review.sh"
}
long_body="$(printf 'word %.0s' {1..81})"
out="$(call_hook "gh pr create --title 'feat: validate text first' --body '$long_body'")"
[[ "$out" == *'paragraph'* && "$out" != *'401'* ]] \
  || { printf 'FAIL: size lookup preceded invalid-body rejection\n' >&2; exit 1; }
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out")" == deny ]] \
  || { printf 'FAIL: 401-line draft creation was allowed\n' >&2; exit 1; }
[[ "$out" == *401* ]] || { printf 'FAIL: denial did not report measured size\n' >&2; exit 1; }
[[ "$out" == *'one tracking issue'* && "$out" == *'checklist'* ]] \
  || { printf 'FAIL: size exception prompt must default to one tracking issue with a checklist\n' >&2; exit 1; }
export SIZE_TEST_LINES=400
[[ -z "$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')" ]] \
  || { printf 'FAIL: 400-line draft creation was denied\n' >&2; exit 1; }
printf 'pr-size: draft boundary passed\n'

export SIZE_TEST_LINES=401
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
state="$scratch/repo/.agents/state/pr-size-request.json"
id="$(jq -r .id "$state")"
deadline="$(jq -r .deadline "$state")"
reason='pr-size-exception: This dependency update regenerates 612 lockfile lines; splitting it from the manifest leaves the dependency graph inconsistent.'
"$plugin/scripts/timed-user-prompt.sh" respond "$state" "$id" "$reason" >/dev/null
[[ -z "$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')" ]]
[[ "$(jq -r .deadline "$state")" == "$deadline" ]]
export SIZE_TEST_BASE=1111111111111111111111111111111111111111
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]
[[ "$(jq -r .id "$state")" != "$id" ]]
id="$(jq -r .id "$state")"
jq '.created_at -= 181 | .deadline -= 181' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$out" == *'deadline expired'* && "$out" == *'split'* ]]
[[ "$out" == *'one tracking issue'* && "$out" == *'checklist'* ]] \
  || { printf 'FAIL: expired size denial must default to one tracking issue with a checklist\n' >&2; exit 1; }
if bash "$plugin/scripts/timed-user-prompt.sh" respond "$state" "$id" "$reason" 2>/dev/null; then
  printf 'FAIL: a late exception was accepted\n' >&2; exit 1
fi
[[ "$(jq -r .id "$state")" == "$id" ]]
[[ "$out" == *'Only a new explicit human instruction'* && "$out" == *'timed-user-prompt.sh renew'* ]]
renewed="$(bash "$plugin/scripts/timed-user-prompt.sh" renew "$state" "$id" 'Please request the size exception again.')"
next_id="$(jq -r .id <<<"$renewed")"
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]
[[ "$out" == *"$next_id"* && "$next_id" != "$id" ]]
if bash "$plugin/scripts/timed-user-prompt.sh" respond "$state" "$id" "$reason" 2>/dev/null; then
  printf 'FAIL: superseded exception was accepted after renewal\n' >&2; exit 1
fi
bash "$plugin/scripts/timed-user-prompt.sh" respond "$state" "$next_id" "$reason" >/dev/null
[[ -z "$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')" ]]
export SIZE_TEST_LINES=402
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]
[[ "$(jq -r .id "$state")" != "$next_id" ]]
export SIZE_TEST_LINES=400
out="$(GH_REPO=other/repo call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]
out="$(call_hook 'gh pr create --draft --head other-branch --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" == deny ]]
export SIZE_TEST_HEAD=2222222222222222222222222222222222222222
out="$(call_hook 'gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"')"
[[ "$out" == *'Cannot determine the exact PR size'* ]]
printf 'pr-size: exception binding, timeout, late reply, and target checks passed\n'
