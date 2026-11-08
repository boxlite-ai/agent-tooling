#!/usr/bin/env bash
# Public gate/lifecycle regressions; every attempt and worker is created by its owner.
# shellcheck disable=SC2031 # Fixture scope/context stay in the parent; sourced libraries run in subshells.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.test
git -C "$repo" config user.name tester
git -C "$repo" config core.hooksPath /dev/null
printf '.agents/state/\n' > "$repo/.gitignore"
printf 'base\n' > "$repo/source"
git -C "$repo" add -A
git -C "$repo" commit -qm base
mkdir -p "$repo/.agents/state"
export CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$plugin"
unset PLUGIN_ROOT CODEX_SANDBOX CLAUDECODE AGENT_GATED GITHOOK_DELEGATED GITHOOK_KEEP_AUDIT
hook="$plugin/.agents/hooks/preflight-commit-push.sh"
control="$plugin/.agents/hooks/auditor-control.sh"
command='git commit -m "test: recover audit"'
cat > "$scratch/codex" <<'CODEX'
#!/usr/bin/env bash
printf 'invoked\n' >> "$RECOVERY_MODEL_RUNS"
exit 1
CODEX
chmod +x "$scratch/codex"
export RECOVERY_MODEL_RUNS="$scratch/model-runs"
pass=0 fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf 'PASS: %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL: %s (got=%s expected=%s)\n' "$1" "$2" "$3"
  fi
}
session() {
  session_id="$1"
  scope="git-$(printf '%s' "$session_id" | git -C "$repo" hash-object --stdin)"
  printf '901-902-1\n' > "$repo/.agents/state/verdict-prompt-epoch.$scope"
  context="$(jq -nc --arg root "$(cd "$repo" && pwd -P)" --arg scope "$scope" \
    --arg branch "$(git -C "$repo" branch --show-current)" \
    '{repo_root:$root,session:$scope,epoch:"901-902-1",branch:$branch,gate:"commit"}')"
  link="$repo/.agents/state/auditor-control/audit-task.$scope.commit-push-auditor.json"
  rm -f "$repo/.agents/state/last-audit.json"
  printf 'change\n' >> "$repo/source"
  git -C "$repo" add source
}
gate() {
  jq -nc --arg session "$session_id" --arg command "$command" \
    '{session_id:$session,tool_input:{command:$command}}' \
    | (cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
      GIT_CONFIG_VALUE_0='' bash "$hook")
}
history() {
  (
    # shellcheck source=../../.agents/lib/verdict-audit-state.sh
    source "$plugin/.agents/lib/verdict-audit-state.sh"
    # shellcheck source=../../.agents/lib/audit-reflection.sh
    source "$plugin/.agents/lib/audit-reflection.sh"
    # shellcheck source=../../.agents/lib/audit-reflection-gate.sh
    source "$plugin/.agents/lib/audit-reflection-gate.sh"
    audit_reflection_gate "$context" inspect
  )
}
lifecycle() { # event generation resumed
  local status=0
  jq -nc --arg event "$1" --arg generation "$2" --arg session "$session_id" \
    --argjson resumed "${3:-false}" \
    '{hook_event_name:$event,session_id:$session,agent_id:$generation,
      agent_type:"boxlite-agent-tooling:commit-push-auditor",stop_hook_active:$resumed,
      last_assistant_message:"FAIL"}' \
    | (cd "$repo" && AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$control") || status=$?
  # Claude's immediate escalation is a successful start with a status-message exit.
  if [[ "$1" == SubagentStart && "$status" == 2 ]]; then
    jq -e --arg generation "$2" '.generation==$generation and .state=="running"' \
      "$repo/.agents/state/auditor-control/active.$scope.commit-push-auditor.json" >/dev/null
  else
    return "$status"
  fi
}
dossier() {
  local input="" candidate id
  id="$(jq -r .attempt_id "$link")"
  for candidate in "$repo"/.agents/state/audit-input-*.json; do
    if jq -e --arg id "$id" '.attempts[-1].id==$id' "$candidate" >/dev/null; then
      input="$candidate"; break
    fi
  done
  [[ -n "$input" ]]
  printf '%s\n' '{"verdict":"FAIL","findings":["test: missing evidence"],"advisories":[],"commit_subject_hash":""}' \
    > "$repo/.agents/state/last-audit.json"
  bash "$plugin/tests/audit/fixtures/audit-history-result.sh" \
    "$(jq -nc --arg path "$input" '{history_path:$path}')" "$repo/.agents/state/last-audit.json" bind
}
action() { jq -r '.hookSpecificOutput.permissionDecisionReason | split("\n")[0]' <<<"$1"; }
headless_block() { # required next action; verify the producer itself, before model lookup
  local status=0
  : > "$RECOVERY_MODEL_RUNS"
  (cd "$repo" && AUDITOR_SESSION_SCOPE="$scope" AUDITOR_PROMPT_EPOCH=901-902-1 \
    CODEX_COMMIT_PUSH_AUDIT_MODE=agentic CODEX_BIN="$scratch/codex" \
    bash "$plugin/.agents/hooks/audit/run-commit-push-audit.sh" commit "$command") \
    > "$scratch/headless-out" 2> "$scratch/headless-err" || status=$?
  check "$host: headless $1 remains blocked" "$([[ "$status" != 0 ]] && echo blocked || echo allowed)" blocked
  check "$host: headless gives $1 action" "$(sed -n '/^Next action:/p' "$scratch/headless-err" | head -1)" "Next action: $1"
  check "$host: headless $1 launches no model" "$(wc -l < "$RECOVERY_MODEL_RUNS" | tr -d ' ')" 0
}
choose() { # fixture user reply, delivered through the real prompt hook
  local decision="$repo/.agents/state/commit-audit-decision-request-$scope.json" id
  id="$(jq -r .id "$decision")"
  jq -nc --arg session "$session_id" --arg prompt "commit-audit-decision: $id $1" \
    '{hook_event_name:"UserPromptSubmit",session_id:$session,prompt:$prompt}' \
    | (cd "$repo" && bash "$plugin/.agents/hooks/cancel-verdict-audit.sh") >/dev/null
  jq -e '.status=="accepted"' "$decision" >/dev/null
}
failed_rounds() { # close real attempts through the existing history facade
  local round state id
  gate >/dev/null
  for (( round=1; round<=$1; round++ )); do
    state="$(history)"; id="$(jq -r '.state.attempts[-1].id' <<<"$state")"
    printf '%s' '"fixture: auditor unavailable"' \
      | bash "$plugin/scripts/audit-reflection-gate.sh" "$context" error "$id" >/dev/null
    if (( round < $1 )); then
      audit_test_submit_due "$plugin/scripts/audit-reflection.sh" "$(jq -r .state_path <<<"$state")"
      if (( round >= 3 )); then
        gate >/dev/null
        choose 'Reflect again'
      fi
      gate >/dev/null
    fi
  done
}

for host in claude codex; do
  export BOXLITE_HOOK_HOST="$host"
  session "recovery-fail-$host"
  gate >/dev/null
  lifecycle SubagentStart worker-a >/dev/null
  dossier
  lifecycle SubagentStop worker-a >/dev/null
  before="$(history)"
  out="$(gate)"
  check "$host: unchanged FAIL requests an audit without receipts" "$(action "$out")" 'Next action: audit'
  check "$host: retry creates a second attempt" "$(history | jq '.state.attempts | length')" 2
  check "$host: retry retains old findings" "$(history | jq -c '.state.registry | map(.id)')" \
    "$(jq -c '.state.registry | map(.id)' <<<"$before")"

  session "recovery-active-$host"
  gate >/dev/null
  lifecycle SubagentStart worker-a >/dev/null
  before="$(history | jq -c .state)"; before_link="$(cat "$link")"
  printf 'new candidate\n' >> "$repo/source"
  git -C "$repo" add source
  out="$(gate)"
  check "$host: active worker returns wait" "$(action "$out")" 'Next action: wait'
  check "$host: active worker preserves history" "$(history | jq -c .state)" "$before"
  check "$host: active worker preserves task link" "$(cat "$link")" "$before_link"
  check "$host: waiting emits no launch task" \
    "$(jq -r '.hookSpecificOutput.permissionDecisionReason | contains("UNTRUSTED_TASK_INPUT_JSON:")' <<<"$out")" false
  headless_block wait
  check "$host: headless wait preserves history" "$(history | jq -c .state)" "$before"
  check "$host: headless wait preserves link" "$(cat "$link")" "$before_link"
  lifecycle SubagentStop worker-a true >/dev/null

  session "recovery-replayed-stop-$host"
  gate >/dev/null
  lifecycle SubagentStart worker-a >/dev/null
  dossier
  lifecycle SubagentStop worker-a >/dev/null
  rm "$repo/.agents/state/last-audit.json"
  gate >/dev/null
  before="$(history | jq -c .state)"; before_link="$(cat "$link")"
  lifecycle SubagentStop worker-a true >/dev/null
  check "$host: old Stop cannot close replacement history" "$(history | jq -c .state)" "$before"
  check "$host: old Stop cannot remove replacement link" "$(cat "$link" 2>/dev/null || printf missing)" "$before_link"

  session "recovery-pending-stop-$host"
  gate >/dev/null
  lifecycle SubagentStart worker-a >/dev/null
  jq -nc --arg session "$session_id" \
    '{hook_event_name:"UserPromptSubmit",session_id:$session,prompt:"continue the current task"}' \
    | (cd "$repo" && bash "$control" handle-prompt 901-902-1 901-903-1) >/dev/null
  before="$(history | jq -c .state)"; before_link="$(cat "$link")"
  mkfifo "$scratch/stop-$host"
  (read -r release < "$scratch/stop-$host"; [[ "$release" == finish ]]; lifecycle SubagentStop worker-a true >/dev/null) &
  stop_pid=$!
  out="$(gate)"
  check "$host: pending terminal delivery returns wait" "$(action "$out")" 'Next action: wait'
  check "$host: pending Stop preserves history" "$(history | jq -c .state)" "$before"
  check "$host: pending Stop preserves link" "$(cat "$link")" "$before_link"
  printf 'finish\n' > "$scratch/stop-$host"
  wait "$stop_pid"
  out="$(gate)"
  check "$host: terminal delivery permits recovery" "$(action "$out")" 'Next action: audit'

  session "recovery-unsafe-owner-$host"
  gate >/dev/null
  lifecycle SubagentStart worker-a >/dev/null
  active="$repo/.agents/state/auditor-control/active.$scope.commit-push-auditor.json"
  before="$(history | jq -c .state)"; before_link="$(cat "$link")"
  for unsafe in malformed symlink fifo directory; do
    mv "$active" "$scratch/active-backup"
    case "$unsafe" in
      malformed) printf '{}\n' > "$active" ;;
      symlink) ln -s "$scratch/active-backup" "$active" ;;
      fifo) mkfifo "$active" ;;
      directory) mkdir "$active" ;;
    esac
    out="$(gate)"
    check "$host: $unsafe owner requires intervention" "$(action "$out")" 'Next action: wait'
    check "$host: $unsafe owner preserves history" "$(history | jq -c .state)" "$before"
    check "$host: $unsafe owner preserves link" "$(cat "$link")" "$before_link"
    if [[ "$unsafe" == directory ]]; then rmdir "$active"; else rm "$active"; fi
    mv "$scratch/active-backup" "$active"
  done
  lifecycle SubagentStop worker-a true >/dev/null

  session "recovery-unreadable-history-$host"
  gate >/dev/null
  state="$(history | jq -r .state_path)"
  cp "$state" "$scratch/history-backup"
  printf '{}\n' > "$state"
  out="$(gate)"
  check "$host: invalid history waits after bounded reread" "$(action "$out")" 'Next action: wait'
  check "$host: invalid history is not reset" "$(cat "$state")" '{}'
  mv "$scratch/history-backup" "$state"

  for terminal in stop budget; do
    session "recovery-$terminal-$host"
    if [[ "$terminal" == stop ]]; then
      failed_rounds 3
      out="$(gate)"
      check "$host: unresolved choice waits" "$(action "$out")" 'Next action: wait'
      choose Stop
    else
      failed_rounds 8
    fi
    before="$(history | jq -c .state)"
    out="$(gate)"
    check "$host: $terminal is explicit" "$(action "$out")" 'Next action: stop'
    check "$host: $terminal creates no attempt" "$(history | jq -c .state)" "$before"
    headless_block stop
    check "$host: headless $terminal preserves history" "$(history | jq -c .state)" "$before"
    saved_command="$command"
    command="git commit -m '$(printf '%16000s' '' | tr ' ' x)'"
    out="$(gate)"
    check "$host: $terminal survives oversized invocation" "$(action "$out")" 'Next action: stop'
    command="$saved_command"
  done
done

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
