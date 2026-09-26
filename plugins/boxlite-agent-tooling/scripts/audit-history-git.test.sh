#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/scripts/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
git config user.email test@example.test
git config user.name tester
git config core.hooksPath /dev/null
mkdir -p .agents/state
printf '.agents/state/\n' > .gitignore
printf 'base\n' > source
git add .gitignore source
git commit -qm 'test: initial state'
printf 'change\n' >> source
git add source
export CLAUDE_PROJECT_DIR="$PWD" AUDITOR_PROMPT_EPOCH=100-101-1
AUDITOR_SESSION_SCOPE="git-$(printf history-session | git hash-object --stdin)"
export AUDITOR_SESSION_SCOPE
printf '%s\n' "$AUDITOR_PROMPT_EPOCH" > ".agents/state/verdict-prompt-epoch.$AUDITOR_SESSION_SCOPE"
cp "$plugin/scripts/fixtures/audit-history-codex.sh" .agents/state/codex
chmod +x .agents/state/codex
export CODEX_BIN="$PWD/.agents/state/codex" CODEX_COMMIT_PUSH_AUDIT_MODE=agentic
export TEST_HISTORY_RESULT_HELPER="$plugin/scripts/fixtures/audit-history-result.sh"
command="git commit -m 'test: verify history'"
kind=commit
run() { bash "$plugin/.agents/hooks/run-commit-push-audit.sh" "$kind" "$command" >.agents/state/out 2>.agents/state/err; }
for attempt in 1 2 3; do
  if run; then printf 'FAIL: failing auditor passed on attempt %s\n' "$attempt" >&2; exit 1; fi
done
if [[ "$(wc -l < .agents/state/model-runs | tr -d ' ')" != 2 ]]; then
  printf 'FAIL: third Git audit launched without reflection\n' >&2; exit 1
fi
state="$(printf '%s\n' "$PWD"/.agents/state/audit-history-*.json)"
jq -e '(.attempts | length) == 2 and .registry[0].id == "F1"' "$state" >/dev/null
gate() { jq -nc --arg command "$command" '{session_id:"history-session",tool_input:{command:$command}}' \
  | bash "$plugin/.agents/hooks/preflight-commit-push.sh"; }
gate | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("reflection")' >/dev/null
audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
TEST_HISTORY_VERDICT=PASS run
cp .agents/state/last-audit.json .agents/state/old-pass
gate > .agents/state/gate-out
[[ ! -s .agents/state/gate-out && ! -f .agents/state/last-audit.json ]]
context="$(jq -c .context "$state")"
binding="$(jq -c '.attempts[-1].input.binding' "$state")"
native="$(jq -nc --argjson binding "$binding" --arg tree "$(git write-tree)" --arg command "$command" \
  '{binding:$binding,snapshot:{tree:$tree,command:$command}}' \
  | bash "$plugin/scripts/audit-reflection-gate.sh" "$context" prepare)"
jq 'del(.history_review,.reflection_review)' .agents/state/old-pass > .agents/state/last-audit.json
bash "$TEST_HISTORY_RESULT_HELPER" "$native" .agents/state/last-audit.json
bash "$plugin/scripts/audit-reflection-gate.sh" "$context" record "$(jq -r .attempt_id <<<"$native")" \
  < .agents/state/last-audit.json >/dev/null
gate > .agents/state/gate-out
[[ ! -s .agents/state/gate-out && ! -f .agents/state/last-audit.json ]]
cp .agents/state/old-pass .agents/state/last-audit.json
gate | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
kind=push
push_dir="$(git rev-parse --git-path codex-audit)"
mkdir -p "$push_dir"
printf 'commit-subject %040d test: verify pushed change\n' 1 > "$push_dir/last-push-audit-context.diff"
git diff --cached --no-ext-diff >> "$push_dir/last-push-audit-context.diff"
pushed_hash="$(shasum -a 256 < "$push_dir/last-push-audit-context.diff" | awk '{print $1}')"
zeros="$(printf '%064d' 0)"
command="git push --pre-push-hook remote=origin remote_url_sha256=$zeros ref_updates_sha256=$zeros pushed_diff_sha256=$pushed_hash"
jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg command "$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')" \
  --arg hash "$pushed_hash" --arg zeros "$zeros" \
  '{branch:$branch,head:$head,command_hash:$command,pushed_diff_hash:$hash,
    ref_updates_hash:$zeros,remote_name:"origin",remote_url_hash:$zeros}' \
  > "$push_dir/last-push-audit-context.json"
TEST_HISTORY_VERDICT=PASS run
jq -e --arg hash "$pushed_hash" '.diff_hash == $hash and .history_review.attempt_id != null' \
  .agents/state/last-audit.json >/dev/null
gate > .agents/state/gate-out
[[ ! -s .agents/state/gate-out && ! -f .agents/state/last-audit.json ]]
printf 'PASS: headless and native Git audits share history, require reflection, and reject stale PASS\n'
