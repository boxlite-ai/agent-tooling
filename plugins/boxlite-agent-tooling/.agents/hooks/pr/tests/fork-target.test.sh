#!/usr/bin/env bash
# Fork regressions exercise the public hook with strict GitHub argument fixtures.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.name=test -c user.email=test@example.invalid commit -qm base --allow-empty
FORK_TEST_BASE="$(git -C "$scratch/repo" rev-parse HEAD)"
export FORK_TEST_BASE
git -C "$scratch/repo" -c user.name=test -c user.email=test@example.invalid commit -qm feature --allow-empty
FORK_TEST_HEAD="$(git -C "$scratch/repo" rev-parse HEAD)"
export FORK_TEST_HEAD
original_base="$FORK_TEST_BASE"
export FORK_TEST_REPO=upstream/project FORK_TEST_HOST=github.com FORK_TEST_OWNER=alice
export FORK_TEST_REMOTE_BRANCH=feature FORK_TEST_BASE_REF=main
export FORK_TEST_SELECTOR='' FORK_TEST_NUMBER=42 FORK_TEST_LINES=400
export FORK_TEST_CALLS="$scratch/calls" FORK_TEST_MOVED="$scratch/moved"
export FORK_TEST_BODY=$'## TL;DR\n\nSupport fork pull requests.\n\n## How it works\n\nResolve the selected fork. https://github.com/example/repo/issues/1'
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
jq -nc --args '$ARGS.positional' -- "$@" >> "$FORK_TEST_CALLS"
if [[ "$1 $2" == 'repo view' ]]; then
  shift 2
  if [[ "$1" != --json ]]; then
    [[ "$1" == "$FORK_TEST_REPO" || "$1" == "$FORK_TEST_HOST/$FORK_TEST_REPO" ]] || exit 2
    shift
  fi
  [[ "$1" == --json && $# == 2 ]] || exit 2
  jq -nc --arg repo "$FORK_TEST_REPO" --arg host "$FORK_TEST_HOST" \
    '{nameWithOwner:$repo,url:("https://"+$host+"/"+$repo),defaultBranchRef:{name:"main"}}'
elif [[ "$1 $2" == 'pr view' ]]; then
  shift 2
  selector=''
  if [[ "$1" != -* ]]; then selector="$1"; shift; fi
  [[ "$selector" == "$FORK_TEST_SELECTOR" && "$1" == --repo \
    && "$2" == "$FORK_TEST_HOST/$FORK_TEST_REPO" && "$3" == --json && $# == 4 ]] || exit 2
  head="$FORK_TEST_HEAD"
  [[ ! -e "$FORK_TEST_MOVED" ]] || head=1111111111111111111111111111111111111111
  jq -nc --arg base "$FORK_TEST_BASE" --arg head "$head" --arg body "$FORK_TEST_BODY" \
    --arg owner "$FORK_TEST_OWNER" --arg repo "$FORK_TEST_REPO" --arg host "$FORK_TEST_HOST" \
    --arg branch "$FORK_TEST_REMOTE_BRANCH" --arg base_ref "$FORK_TEST_BASE_REF" \
    --argjson number "$FORK_TEST_NUMBER" \
    '{number:$number,url:("https://"+$host+"/"+$repo+"/pull/"+($number|tostring)),
      baseRefOid:$base,baseRefName:$base_ref,headRefOid:$head,headRefName:$branch,
      headRepositoryOwner:{login:$owner},headRepository:{name:"renamed-fork",nameWithOwner:($owner+"/renamed-fork")},body:$body}'
elif [[ "$*" == 'api --hostname github.com repos/example/repo/issues/1' ]]; then
  jq -nc '{html_url:"https://github.com/example/repo/issues/1",body:"## TL;DR\n\nResolve fork targets."}'
elif [[ "$1 $2 $3 $4" == "api --hostname $FORK_TEST_HOST markdown" ]]; then
  [[ "$*" == *https://github.com/example/repo/issues/1* ]] || exit 2
  printf '<h2>How it works</h2><p>Resolve forks.</p><a href="https://github.com/example/repo/issues/1">Design</a>'
  [[ "${FORK_TEST_MOVE_ON_RENDER:-0}" == 0 ]] || touch "$FORK_TEST_MOVED"
elif [[ "$1 $2 $3" == "api --hostname $FORK_TEST_HOST" && $# == 4 ]]; then
  encoded="$(jq -rn --arg ref "$FORK_TEST_OWNER:refs/heads/$FORK_TEST_REMOTE_BRANCH" '$ref|@uri')"
  encoded_base="$(jq -rn --arg ref "$FORK_TEST_BASE_REF" '$ref|@uri')"
  case "$4" in
    "repos/$FORK_TEST_REPO/git/ref/heads/$encoded_base")
      jq -nc --arg sha "$FORK_TEST_BASE" '{object:{type:"commit",sha:$sha}}' ;;
    "repos/$FORK_TEST_REPO/compare/$FORK_TEST_HEAD...$encoded")
      [[ "${FORK_TEST_MISSING:-0}" == 0 ]] || exit 1
      status=identical; ahead=0
      if [[ -e "$FORK_TEST_MOVED" ]]; then status=ahead; ahead=1; fi
      jq -nc --arg sha "$FORK_TEST_HEAD" --arg status "$status" --argjson ahead "$ahead" \
        '{status:$status,ahead_by:$ahead,behind_by:0,base_commit:{sha:$sha},merge_base_commit:{sha:$sha},files:[]}' \
        | jq -c "${FORK_TEST_IDENTITY_FILTER:-.}" ;;
    "repos/$FORK_TEST_REPO/compare/$FORK_TEST_BASE...$FORK_TEST_HEAD")
      jq -nc --arg base "$FORK_TEST_BASE" --argjson lines "$FORK_TEST_LINES" \
        '{base_commit:{sha:$base},files:[{filename:"src/main.sh",additions:$lines,deletions:0}]}' ;;
    *) exit 2 ;;
  esac
else
  exit 2
fi
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch/repo"
unset GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE
cd "$scratch/repo"
bash "$plugin/scripts/design-doc.sh" bind https://github.com/example/repo/issues/1 >/dev/null
hook() {
  jq -nc --arg command "$1" '{tool_input:{command:$command}}' \
    | bash "$plugin/.agents/hooks/preflight-pr-review.sh"
}
pass=0 fail=0
check() {
  local label="$1" command="$2" expected="$3" out
  out="$(hook "$command")"
  if [[ -z "$expected" && -z "$out" || -n "$expected" && "$out" == *"$expected"* ]]; then
    printf 'PASS %s\n' "$label"; pass=$((pass+1))
  else
    printf 'FAIL %s: expected %s; got %s\n' "$label" "$expected" "$out" >&2; fail=$((fail+1))
  fi
}
draft="gh pr create --draft --title 'fix: resolve forks' --body '$FORK_TEST_BODY'"
for repo_option in '--repo upstream/project' '--repo=upstream/project' '-R upstream/project' '-Rupstream/project' '-R=upstream/project'; do
  check "fork draft with $repo_option" "$draft $repo_option --head alice:feature" ''
done
check 'repo before pr' "gh --repo upstream/project pr create --draft --head alice:feature --body '$FORK_TEST_BODY'" ''
check 'repo before verb' "gh pr -Rupstream/project create --draft --head alice:feature --body '$FORK_TEST_BODY'" ''
check 'target options before draft' "gh pr create --repo upstream/project --head alice:feature --draft --body '$FORK_TEST_BODY'" ''
check 'target options before draft retain summary check' "gh pr create --repo upstream/project --head alice:feature --draft --body 'Resolve forks. https://github.com/example/repo/issues/1'" 'TL;DR heading missing'
check 'target options before draft retain privacy check' "gh pr create --repo upstream/project --head alice:feature --draft --body '$FORK_TEST_BODY Private chat: copied context.'" 'private context indicators'
check 'target options before title' "gh pr create -R upstream/project -Halice:feature --title 'fix: resolve forks' --body '$FORK_TEST_BODY'" 'reviewed:'
export FORK_TEST_REMOTE_BRANCH='feature/encoded#ref'
check 'remote branch alias is encoded and matches local HEAD' "$draft -Rupstream/project --head alice:$FORK_TEST_REMOTE_BRANCH" ''
export FORK_TEST_REMOTE_BRANCH=feature FORK_TEST_BASE_REF=release/next
check 'explicit base overrides default branch' "$draft -Rupstream/project -Halice:feature -B=release/next" ''
git config branch.feature.gh-merge-base release/next
check 'configured base overrides default branch' "$draft -Rupstream/project -Halice:feature" ''
git config --unset branch.feature.gh-merge-base
export FORK_TEST_BASE_REF=main
export FORK_TEST_REMOTE_BRANCH=remote-alias
git config branch.feature.gh-merge-base release/next
git config branch.remote-alias.gh-merge-base main
check 'explicit remote alias selects its own base configuration' "$draft -Rupstream/project -Halice:remote-alias" ''
git config --unset branch.feature.gh-merge-base
git config --unset branch.remote-alias.gh-merge-base
export FORK_TEST_REMOTE_BRANCH=feature
for verb in edit ready; do
  args=''; [[ "$verb" != edit ]] || args='--add-label ready'
  : > "$FORK_TEST_CALLS"
  check "$verb preserves omitted selector" "gh pr $verb -R upstream/project $args" 'reviewed:'
  calls="$(jq -s '[.[] | select(.[0]=="pr" and .[1]=="view")]|length' "$FORK_TEST_CALLS")"
  if [[ "$calls" == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL shared PR lookup: %s calls\n' "$calls"; fi
  export FORK_TEST_SELECTOR=alice:feature
  check "$verb preserves qualified selector" "gh pr $verb alice:feature $args --repo upstream/project" 'reviewed:'
  export FORK_TEST_SELECTOR=''
done
if [[ "${1:-}" == --reproducer ]]; then
  printf '%d passed, %d failed\n' "$pass" "$fail"; [[ "$fail" == 0 ]]; exit
fi

check 'renamed fork first resolves' "$draft -Rupstream/project -Halice:feature" ''
touch "$FORK_TEST_MOVED"
check 'moved head denies' "$draft -Rupstream/project -Halice:feature" 'Cannot determine'
rm "$FORK_TEST_MOVED"
export FORK_TEST_MISSING=1
check 'missing fork denies' "$draft -Rupstream/project -Halice:feature" 'Cannot determine'
unset FORK_TEST_MISSING
# These strings are jq programs consumed by the fake API, not shell arguments.
# shellcheck disable=SC2089,SC2090
for FORK_TEST_IDENTITY_FILTER in 'del(.status)' '.ahead_by=1' '.behind_by=1' '.base_commit.sha="invalid"' '.merge_base_commit.sha="invalid"'; do
  export FORK_TEST_IDENTITY_FILTER
  check "incomplete identity proof $FORK_TEST_IDENTITY_FILTER denies" "$draft -Rupstream/project -Halice:feature" 'Cannot determine'
done
unset FORK_TEST_IDENTITY_FILTER
export FORK_TEST_MOVE_ON_RENDER=1
check 'movement during description validation denies' "$draft -Rupstream/project -Halice:feature" 'changed'
unset FORK_TEST_MOVE_ON_RENDER
rm -f "$FORK_TEST_MOVED"

export FORK_TEST_LINES=401
state="$scratch/repo/.agents/state/pr-size-request.json"
reset_target() {
  export FORK_TEST_OWNER=alice FORK_TEST_REPO=upstream/project FORK_TEST_HOST=github.com
  export FORK_TEST_BASE_REF=main FORK_TEST_BASE="$original_base" FORK_TEST_NUMBER=42
}
change_target() {
  case "$1" in
    owner) export FORK_TEST_OWNER=bob ;;
    repository) export FORK_TEST_REPO=other/project ;;
    host) export FORK_TEST_HOST=github.example.com ;;
    base_ref) export FORK_TEST_BASE_REF=release/next ;;
    base_commit) export FORK_TEST_BASE="$FORK_TEST_HEAD" ;;
    pr_number) export FORK_TEST_NUMBER=43 ;;
  esac
}
for dimension in owner repository host base_ref base_commit; do
  reset_target
  rm -f "$state"
  check "fork above cap asks before $dimension change" "$draft -Rupstream/project -Halice:feature" 'Bypass limit'
  [[ -f "$state" ]] || continue
  old="$(jq -r .id "$state")"
  bash "$plugin/scripts/timed-user-prompt.sh" respond "$state" "$old" 'Bypass limit' >/dev/null
  check 'exact fork bypass passes' "$draft -Rupstream/project -Halice:feature" ''
  change_target "$dimension"
  check "different $dimension needs new bypass" "$draft -R$FORK_TEST_HOST/$FORK_TEST_REPO -H$FORK_TEST_OWNER:feature -B$FORK_TEST_BASE_REF" 'Bypass limit'
  [[ "$(jq -r .id "$state")" != "$old" ]] || fail=$((fail+1))
done
reset_target
export FORK_TEST_LINES=400

review_state="$scratch/repo/.agents/state/pr-review-request.json"
for dimension in owner repository host base_ref base_commit pr_number; do
  reset_target
  check "ready creates review request before $dimension change" 'gh pr ready -Rupstream/project' 'reviewed:'
  [[ -f "$review_state" ]] || continue
  old="$(jq -r .id "$review_state")"
  jq -nc --arg branch feature --arg head "$FORK_TEST_HEAD" --arg request "$old" \
    '{branch:$branch,head:$head,request:$request,message:"reviewed: exact fork target"}' > .agents/state/pr-reviewed.json
  change_target "$dimension"
  check "different $dimension invalidates review" "gh pr ready -R$FORK_TEST_HOST/$FORK_TEST_REPO" 'old request'
  [[ "$(jq -r .id "$review_state")" != "$old" && -f .agents/state/pr-reviewed.json ]] || fail=$((fail+1))
  rm .agents/state/pr-reviewed.json
done
reset_target
check 'ready primes final revalidation' 'gh pr ready -Rupstream/project' 'reviewed:'
if [[ -f "$review_state" ]]; then
  jq -nc --arg branch feature --arg head "$FORK_TEST_HEAD" --arg request "$(jq -r .id "$review_state")" \
    '{branch:$branch,head:$head,request:$request,message:"reviewed: exact fork target"}' > .agents/state/pr-reviewed.json
  export FORK_TEST_MOVE_ON_RENDER=1
  check 'head movement after review preserves marker and denies' 'gh pr ready -Rupstream/project' 'changed after review'
  [[ -f .agents/state/pr-reviewed.json ]] || fail=$((fail+1))
  unset FORK_TEST_MOVE_ON_RENDER
  rm -f "$FORK_TEST_MOVED" .agents/state/pr-reviewed.json
fi

# The public hook must see the literal expansion spelling.
# shellcheck disable=SC2016
for unsafe in '--repo upstream/project --repo upstream/project' '--repo "$REPO"' '--repo upstream/*' '--repo=-bad/project' '--head alice:feature --head alice:other'; do
  check "unsafe target $unsafe" "$draft --head alice:feature $unsafe" 'deny'
done
check 'metadata value cannot supply a target option' "$draft -Rupstream/project -Halice:feature --label --repo=other/project" ''
check 'dynamic global repo denies' "gh --repo \"\$REPO\" pr create --draft --body '$FORK_TEST_BODY' --head alice:feature" 'deny'
check 'missing repo operand denies' "$draft -Halice:feature --repo" 'deny'
check 'target options cannot hide redirection' "$draft -Rupstream/project -Halice:feature >output --base main" 'deny'
check 'base-changing edit remains denied' 'gh pr edit -Rupstream/project --base release --add-label ready' 'deny'
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
