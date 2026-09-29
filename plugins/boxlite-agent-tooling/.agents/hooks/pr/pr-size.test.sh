#!/usr/bin/env bash
# Exercise size enforcement through the existing public PR hook.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
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
      --argjson files "${SIZE_TEST_FILES:-null}" \
      '{base_commit:{sha:$base},files:($files // [{filename:"src/main.sh",additions:$lines,deletions:0}])}' ;;
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

# Shell commands can target a checkout other than the hook process directory.
git init -q -b elsewhere "$scratch/other"
git -C "$scratch/other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m other
target_root="$(pwd -P)"
context_command='gh pr create --draft --title "fix: retry calls" --body "## TL;DR

Retry a failed call once.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"'
context_hook() {
  jq -nc --arg command "$context_command" --argjson context "$1" \
    '$context | .tool_input.command=$command' \
    | (cd "$scratch/other" && CLAUDE_PROJECT_DIR="$scratch/other" \
       bash "$plugin/.agents/hooks/preflight-pr-review.sh")
}
export SIZE_TEST_LINES=400
plain_context_command="$context_command"
for directory_option in "-C '$target_root'" "--chdir '$target_root'" "--chdir='$target_root'"; do
  context_command="env $directory_option $plain_context_command"
  out="$(context_hook '{}')"
  [[ -z "$out" ]] || {
    printf 'FAIL: literal env directory did not bind the target checkout\n%s\n' "$out" >&2; exit 1;
  }
done
for directory_option in "-C relative" "-C '\$TARGET'" "-C $target_root/*" \
    "-C '$target_root' -C '$target_root'" "-C '$scratch'"; do
  context_command="env $directory_option $plain_context_command"
  out="$(context_hook '{}')"
  [[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")" == deny ]] || {
    printf 'FAIL: unsafe env directory was accepted\n%s\n' "$out" >&2; exit 1;
  }
done
context_command="env -C '$target_root' $plain_context_command"
export SIZE_TEST_LINES=401
out="$(context_hook '{}')"
[[ "$out" == *'pr-size-exception:'* ]]
[[ "$(jq -r .spec.binding.root .agents/state/pr-size-request.json)" == "$target_root" ]]
rm .agents/state/pr-size-request.json
context_command="env -C '$target_root' gh pr ready"
export SIZE_TEST_LINES=400
out="$(context_hook '{}')"
[[ "$out" == *'reviewed:'* ]]
[[ "$(jq -r .spec.binding.repo .agents/state/pr-review-request.json)" == "$target_root" ]]
rm .agents/state/pr-review-request.json
context_command="$plain_context_command"
for directory_field in workdir cwd event_cwd; do
  context="$(jq -nc --arg field "$directory_field" --arg root "$target_root" '
    if $field == "event_cwd" then {cwd:$root}
    else {tool_input:{($field):$root}} end')"
  out="$(context_hook "$context")"
  [[ -z "$out" ]] || {
    printf 'FAIL: %s did not select the command checkout\n%s\n' "$directory_field" "$out" >&2
    exit 1
  }
done
context="$(jq -nc --arg root "$target_root" --arg other "$scratch/other" \
  '{cwd:$other,tool_input:{workdir:$root,cwd:$other}}')"
export SIZE_TEST_LINES=401
out="$(context_hook "$context")"
[[ "$out" == *'pr-size-exception:'* ]] || {
  printf 'FAIL: the target checkout escaped size enforcement\n%s\n' "$out" >&2; exit 1;
}
[[ "$(jq -r .spec.binding.root .agents/state/pr-size-request.json)" == "$target_root" ]]
[[ ! -e "$scratch/other/.agents/state/pr-size-request.json" ]]
rm .agents/state/pr-size-request.json
export SIZE_TEST_LINES=400
context_command='gh pr ready'
out="$(context_hook "$context")"
[[ "$out" == *'reviewed:'* ]] || {
  printf 'FAIL: the target checkout escaped review enforcement\n%s\n' "$out" >&2; exit 1;
}
[[ "$(jq -r .spec.binding.repo .agents/state/pr-review-request.json)" == "$target_root" ]]
[[ ! -e "$scratch/other/.agents/state/pr-review-request.json" ]]
rm .agents/state/pr-review-request.json
for invalid in '""' 'false' '42' '[]' '"/nonexistent-pr-checkout"'; do
  context="$(jq -nc --argjson invalid "$invalid" --arg root "$target_root" \
    '{cwd:$root,tool_input:{workdir:$invalid}}')"
  out="$(context_hook "$context")"
  [[ "$out" == *'working directory'* ]] || {
    printf 'FAIL: invalid working directory did not fail closed\n%s\n' "$out" >&2; exit 1;
  }
done
context="$(jq -nc --arg root "$scratch" '{tool_input:{workdir:$root}}')"
out="$(context_hook "$context")"
[[ "$out" == *'working directory is not a Git checkout'* ]] || {
  printf 'FAIL: directory outside Git was accepted\n%s\n' "$out" >&2; exit 1;
}
printf 'pr-size: command checkout selection and enforcement passed\n'
export SIZE_TEST_LINES=401

code_failures=0
check_code_size() { # label, files JSON, expected code lines or unknown
  local label="$1" expected="$3" operation out command
  SIZE_TEST_FILES="$(jq -nc "$2")"
  export SIZE_TEST_FILES
  for operation in create edit ready; do
    case "$operation" in
      create) command='gh pr create --draft --title wip --body "## TL;DR

Fixture change.

## How it works

Retry failed calls once. https://github.com/example/repo/issues/123"' ;;
      edit) command='gh pr edit --add-label documentation' ;;
      ready) command='gh pr ready' ;;
    esac
    out="$(call_hook "$command")"
    if { [[ "$expected" == unknown && "$out" == *'Cannot determine the exact PR size'* ]]; } \
      || { [[ "$expected" != unknown && "$expected" -gt 400 && "$out" == *'pr-size-exception:'* ]] \
        && [[ "$(jq -r .spec.binding.lines "$scratch/repo/.agents/state/pr-size-request.json")" == "$expected" ]]; } \
      || { [[ "$expected" != unknown && "$expected" -le 400 ]] \
        && { [[ "$operation" == create && -z "$out" ]] \
          || [[ "$operation" != create && "$out" == *'reviewed:'* && "$out" != *'pr-size-exception:'* ]]; }; }; then
      printf 'PASS: %s / %s\n' "$label" "$operation"
    else
      printf 'FAIL: %s / %s: expected code size %s\n%s\n' "$label" "$operation" "$expected" "$out" >&2
      code_failures=$((code_failures + 1))
    fi
  done
}
check_code_size 'documentation-only comparison' \
  '[{"filename":"README.md","additions":1000,"deletions":500}]' 0
check_code_size 'deletions do not count' \
  '[{"filename":"src/main.sh","additions":400,"deletions":900}]' 400
check_code_size 'test files and tests directories do not count' \
  '["src/main.spec.ts","pkg/main_test.go","tests/main.ts","src/tests/nested/main.go"] | map({filename:.,additions:401,deletions:0})' 0
check_code_size 'similar names remain code' \
  '["src/main.spec.tsx","pkg/main_test.gox","src/mytests/main.go"] | map({filename:.,additions:401,deletions:0})' 1203
check_code_size 'renamed code into tests does not count' \
  '[{"filename":"tests/main.go","previous_filename":"src/main.go","status":"renamed","additions":401,"deletions":0}]' 0
check_code_size 'renamed test into code counts' \
  '[{"filename":"src/main.go","previous_filename":"tests/main.go","status":"renamed","additions":401,"deletions":0}]' 401
check_code_size 'renamed test into prose does not count' \
  '[{"filename":"README.md","previous_filename":"tests/main.go","status":"renamed","additions":401,"deletions":0}]' 0
check_code_size 'mixed comparison at code boundary' \
  '[{"filename":"src/main.sh","additions":180,"deletions":120},{"filename":"tests/main.test.sh","additions":40,"deletions":10},{"filename":"config.yml","additions":220,"deletions":0},{"filename":"docs/guide.rst","additions":2000,"deletions":0}]' 400
check_code_size 'mixed comparison above code boundary' \
  '[{"filename":"src/main.sh","additions":401,"deletions":900},{"filename":"README.md","additions":2000,"deletions":0}]' 401
check_code_size 'assets, data, and lockfiles' \
  '["LICENSE","notes.txt","image.svg","data.csv","package-lock.json","pnpm-lock.yaml","Cargo.lock"] | map({filename:.,additions:900,deletions:0})' 0
check_code_size 'text build and dependency configuration' \
  '["CMakeLists.txt","requirements.txt","requirements-dev.txt","constraints.txt"] | map({filename:.,additions:401,deletions:0}) + [{filename:"README.md",additions:900,deletions:0}]' 1604
check_code_size 'source in documentation directory' \
  '[{"filename":"docs/example.py","additions":401,"deletions":0}]' 401
check_code_size 'extensionless script' \
  '[{"filename":"bin/run","additions":401,"deletions":0}]' 401
check_code_size 'configuration, generated source, MDX, and unfamiliar files' \
  '["package.json","composer.json","config.yml","generated.pb.go","docs/component.mdx","new.lang"] | map({filename:.,additions:401,deletions:0})' 2406
check_code_size 'rename from code to prose' \
  '[{"filename":"guide.md","previous_filename":"main.sh","additions":401,"deletions":0}]' 401
check_code_size 'rename between prose files' \
  '[{"filename":"guide.md","previous_filename":"README.md","additions":900,"deletions":0}]' 0
check_code_size 'missing filename fails closed' \
  '[{"additions":1,"deletions":0}]' unknown
check_code_size 'rename without original filename fails closed' \
  '[{"filename":"README.md","status":"renamed","additions":1,"deletions":0}]' unknown
check_code_size 'malformed excluded entry fails closed' \
  '[{"filename":"README.md","additions":-1,"deletions":0}]' unknown
check_code_size 'possibly truncated files fail closed' \
  '[range(300) | {filename:("doc-"+tostring+".md"),additions:1,deletions:0}]' unknown
unset SIZE_TEST_FILES
[[ "$code_failures" == 0 ]] || exit 1
rm -f "$scratch/repo/.agents/state/pr-size-request.json" "$scratch/repo/.agents/state/pr-review-request.json"
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
reason='pr-size-exception: This protocol update regenerates 612 binding-code lines; splitting the schema from generated bindings leaves incompatible interfaces.'
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
jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
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
