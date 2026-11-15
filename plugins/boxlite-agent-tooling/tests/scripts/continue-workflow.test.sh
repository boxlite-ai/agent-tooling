#!/usr/bin/env bash
# Tests for scripts/continue-workflow.sh, the Stop step that continues a turn once per
# work state when a branch with a passed, advised design has pending work.
#
# Each case builds a throwaway repository with local design records, feeds a Stop
# payload to the script (or to the whole Stop gate), and asserts on stdout.
#
# Run with:  bash tests/scripts/continue-workflow.test.sh
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin/tests/lib/assert.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unset CLAUDE_PLUGIN_ROOT PLUGIN_ROOT

new_repo() { # name -> repository on branch feature with one pushed commit
  local repo="$scratch/$1"
  git init -q -b feature "$repo"
  git -C "$repo" config user.email t@t.test
  git -C "$repo" config user.name tester
  printf '.agents/state/\n' > "$repo/.gitignore"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  git -C "$repo" remote add origin "$scratch/absent.git"
  git -C "$repo" update-ref refs/remotes/origin/feature HEAD
  git -C "$repo" config branch.feature.remote origin
  git -C "$repo" config branch.feature.merge refs/heads/feature
  (cd "$repo" && pwd -P)
}
pass_design() { # repo [verdict] -> local PASS and advice records for this branch
  local directory sha=aaaaaaaa
  directory="$(git -C "$1" rev-parse --absolute-git-dir)"
  jq -nc --arg root "$1" --arg sha "$sha" --arg verdict "${2:-PASS}" \
    '{root:$root,branch:"feature",url:"https://example.test/1",content_sha256:$sha,verdict:$verdict}' \
    > "$directory/agent-tooling-design-audit.json"
  jq -nc --arg root "$1" --arg sha "$sha" \
    '{root:$root,branch:"feature",url:"https://example.test/1",content_sha256:$sha,advice:[]}' \
    > "$directory/agent-tooling-design-advice.json"
}
stop() { # repo [session] -> the script's stdout
  jq -nc --arg s "${2:-session}" '{hook_event_name:"Stop",session_id:$s}' \
    | (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$plugin/scripts/continue-workflow.sh")
}
continues() { jq -e '.decision == "block"' <<<"$1" >/dev/null 2>&1; }
passes_through() { [[ "$1" == 0 && -z "$2" ]]; } # status, stdout
fails_closed() { [[ "$1" == 2 && "$2" == *"$3"* ]]; } # status, stderr, expected text

printf '## Pending work on a passed design continues once per state\n'
repo="$(new_repo once)"; pass_design "$repo"
printf 'edit\n' >> "$repo/file.txt"
out="$(stop "$repo")"
continues "$out" && [[ "$out" == *"uncommitted changes"* && "$out" == *"feature"* ]]
check_rc 'a modified file continues the turn and names the pending work' "$?" "out=$out"
check_eq 'the same state does not continue again' "$(stop "$repo")" ""
git -C "$repo" add file.txt
check_eq 'staging the unchanged edit does not continue again' "$(stop "$repo")" ""
git -C "$repo" restore --staged file.txt
check_eq 'unstaging it does not continue again' "$(stop "$repo")" ""
printf 'more\n' >> "$repo/file.txt"
continues "$(stop "$repo")"; check_rc 'a further edit to the same file continues once more' "$?"
check_eq 'and then ends' "$(stop "$repo")" ""
git -C "$repo" commit -qam work
out="$(stop "$repo")"
continues "$out" && [[ "$out" == *"1 unpushed commit"* ]]
check_rc 'a commit that is not pushed continues once more' "$?" "out=$out"
git -C "$repo" update-ref refs/remotes/origin/feature HEAD
check_eq 'a clean, pushed branch is never continued' "$(stop "$repo")" ""
check_eq 'another session on the clean branch is not continued either' "$(stop "$repo" other)" ""

printf '## New files count\n'
repo="$(new_repo untracked)"; pass_design "$repo"
printf 'new\n' > "$repo/new.txt"
continues "$(stop "$repo")"; check_rc 'an untracked file alone continues the turn' "$?"
git -C "$repo" add new.txt
check_eq 'staging the new file does not continue again' "$(stop "$repo")" ""

printf '## A branch without an upstream falls back to the default branch\n'
repo="$(new_repo noupstream)"; pass_design "$repo"
git -C "$repo" config --unset branch.feature.merge
git -C "$repo" commit -q --allow-empty -m work
check_eq 'no upstream and no default branch pointer gives no reminder' "$(stop "$repo")" ""
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feature
out="$(stop "$repo")"
continues "$out" && [[ "$out" == *"1 unpushed commit"* ]]
check_rc 'a commit ahead of the default branch continues the turn' "$?" "out=$out"

printf '## Missing dependencies fail closed\n'
tools="$scratch/tools"; mkdir -p "$tools"
for tool in bash git perl dirname cat cut; do ln -s "$(command -v "$tool")" "$tools/$tool"; done
said="$(printf '{}' | PATH="$tools" bash "$plugin/scripts/continue-workflow.sh" 2>&1 >/dev/null)"; rc=$?
fails_closed "$rc" "$said" 'required command missing: jq'
check_rc 'a missing jq exits 2 and names it' "$?" "rc=$rc said=$said"
partial="$scratch/partial-plugin"; mkdir -p "$partial"
cp -R "$plugin/.agents" "$plugin/scripts" "$partial/"
rm "$partial/scripts/continue-workflow.sh"
said="$(jq -nc '{hook_event_name:"Stop",session_id:"gate",stop_hook_active:false,last_assistant_message:"Noted."}' \
  | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$partial/.agents/hooks/stop-gate.sh" 2>&1 >/dev/null))"; rc=$?
fails_closed "$rc" "$said" 'workflow continuation missing'
check_rc 'the Stop gate exits 2 when the step is missing' "$?" "rc=$rc said=$said"
printf 'ignored\n' > "$repo/.agents-ignored"; printf '.agents-ignored\n' >> "$repo/.git/info/exclude"
check_eq 'an ignored file changes nothing' "$(stop "$repo")" ""

printf '## No reminder without a passed, advised design\n'
repo="$(new_repo nodesign)"; printf 'edit\n' >> "$repo/file.txt"
check_eq 'no design records' "$(stop "$repo")" ""
pass_design "$repo" FAIL
check_eq 'a failed design' "$(stop "$repo")" ""
pass_design "$repo"
rm -f "$(git -C "$repo" rev-parse --absolute-git-dir)/agent-tooling-design-advice.json"
check_eq 'a PASS without advice' "$(stop "$repo")" ""
pass_design "$repo"
git -C "$repo" switch -qc other
check_eq 'a design passed for another branch' "$(stop "$repo")" ""

printf '## Errors never continue or block\n'
repo="$(new_repo corrupt)"; pass_design "$repo"; printf 'edit\n' >> "$repo/file.txt"
printf '{not json' > "$(git -C "$repo" rev-parse --absolute-git-dir)/agent-tooling-design-audit.json"
out="$(stop "$repo")"; rc=$?
passes_through "$rc" "$out"; check_rc 'a corrupt design record passes through' "$?" "rc=$rc out=$out"
pass_design "$repo"
out="$(printf 'not json' | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$plugin/scripts/continue-workflow.sh"))"; rc=$?
passes_through "$rc" "$out"; check_rc 'a payload without a session passes through' "$?" "rc=$rc out=$out"
mkdir -p "$repo/.agents/state"; chmod a-w "$repo/.agents/state"
out="$(stop "$repo")"; rc=$?
chmod u+w "$repo/.agents/state"
passes_through "$rc" "$out"; check_rc 'an unwritable state directory gives no reminder' "$?" "rc=$rc out=$out"

printf '## The Stop gate runs the step before the verdict check\n'
repo="$(new_repo gate)"; pass_design "$repo"; printf 'edit\n' >> "$repo/file.txt"
: > "$repo/transcript.jsonl"
gate() { # repo, continued-turn flag -> the Stop gate's stdout for a short claim-free reply
  jq -nc --arg p "$1/transcript.jsonl" --argjson active "${2:-false}" \
    '{hook_event_name:"Stop",session_id:"gate",transcript_path:$p,stop_hook_active:$active,last_assistant_message:"Noted."}' \
    | (cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_CLASSIFIER_CMD=false \
        bash "$plugin/.agents/hooks/stop-gate.sh" 2>/dev/null)
}
out="$(gate "$repo")"
continues "$out" && [[ "$out" == *"uncommitted changes"* && "$out" != *"verdict-gate"* ]]
check_rc 'the first Stop continues with the reminder before the verdict check' "$?" "out=$out"
out="$(gate "$repo" true)"
reaches_verdict_check() { [[ "$1" != *"uncommitted changes"* && "$1" == *"verdict-gate"* ]]; }
reaches_verdict_check "$out"
check_rc 'the continued turn on the same state reaches the verdict check' "$?" "out=$out"

printf '## A pending timed confirmation wins\n'
repo="$(new_repo timed)"; pass_design "$repo"; printf 'edit\n' >> "$repo/file.txt"
: > "$repo/transcript.jsonl"; mkdir -p "$repo/.agents/state"
spec="$(jq -nc --arg repo "$repo" --arg head "$(git -C "$repo" rev-parse HEAD)" \
  '{binding:{root:$repo,head:$head,branch:"feature",session:"gate"},prefix:"pr-size-exception:",fallback:"split"}')"
bash "$plugin/scripts/timed-user-prompt.sh" request "$repo/.agents/state/pr-size-request.json" "$spec" >/dev/null
out="$(gate "$repo")"
continues "$out" && [[ "$out" == *"Deadline:"* && "$out" != *"uncommitted changes"* ]]
check_rc 'the confirmation text is delivered, not the reminder' "$?" "out=$out"

printf '## A design-gate block continues the turn once (design #597)\n'
blocked_edit() { # repo session -> the design gate's exit status for an edit
  jq -nc --arg cwd "$1" --arg s "$2" \
    '{tool_name:"Write",cwd:$cwd,session_id:$s,tool_input:{file_path:"source.py"}}' \
    | (cd "$1" && CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$plugin" \
        bash "$plugin/.agents/hooks/preflight-design-doc.sh" >/dev/null 2>&1)
}
repo="$(new_repo gateblock)"
blocked_edit "$repo" session; rc=$?
check_eq 'an edit without a registered design is blocked' "$rc" 2
out="$(stop "$repo")"
continues "$out" && [[ "$out" == *"design"* && "$out" == *"feature"* ]]
check_rc 'the next Stop continues the turn with the design step' "$?" "out=$out"
check_eq 'a second Stop without a new block ends the turn' "$(stop "$repo")" ""
blocked_edit "$repo" session
check_eq 'another session does not consume the block' "$(stop "$repo" other)" ""
continues "$(stop "$repo")"; check_rc 'the blocked session still gets its continuation' "$?"
blocked_edit "$repo" session
git -C "$repo" switch -qc elsewhere
check_eq 'a block recorded on another branch is ignored' "$(stop "$repo")" ""
git -C "$repo" switch -q feature
blocked_edit "$repo" session; pass_design "$repo"
out="$(stop "$repo")"
[[ "$out" != *"no passed"* ]]; check_rc 'a passed design takes no design continuation' "$?" "out=$out"
mkdir -p "$repo/.agents/state"
scope="$(source "$plugin/.agents/lib/verdict-audit-state.sh" \
  && verdict_audit_scope_from_hook_payload '{"session_id":"session"}' "$repo")"
printf '{not json' > "$repo/.agents/state/design-gate-block-$scope.json"
out="$(stop "$repo")"; rc=$?
passes_through "$rc" "$out"; check_rc 'a malformed block record fails open' "$?" "rc=$rc out=$out"

assert_result
