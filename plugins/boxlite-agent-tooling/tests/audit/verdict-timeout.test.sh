#!/usr/bin/env bash
# Capture the real runner's lease without waiting for the model deadline.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/.agents/state" "$scratch/bin"
git -C "$repo" init -q
git -C "$repo" -c user.name=tester -c user.email=t@t.test commit --allow-empty -qm base
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"tests pass"}]}}\n' >"$repo/transcript.jsonl"
session='timeout-session'
scope="git-$(printf '%s' "$session" | git hash-object --stdin)"
cat >"$scratch/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -eu
# Claude receives one stream-json frame; the override receives the prompt on stdin.
IFS= read -r frame
if prompt="$(jq -er '.message.content' <<<"$frame" 2>/dev/null)"; then :; else prompt="$frame"$'\n'"$(cat)"; fi
cp "$CLAUDE_PROJECT_DIR/.agents/state/verdict-audit.lock.$AUDIT_SCOPE" "$LOCK_CAPTURE"
printf '{"branch":"main","head":"h","tree_hash":"t","generation":"%s","verdict":"PASS","proof":[],"findings":[]}' \
  "$VERDICT_AUDITOR_GENERATION" >"$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$HISTORY_HELPER" "$(printf '%s\n' "$prompt" | sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }')" \
  "$VERDICT_AUDITOR_OUTPUT_FILE" bind
printf '%s\n' '{"type":"result","subtype":"success","result":"PASS"}'
cat >/dev/null
STUB
chmod +x "$scratch/bin/claude"
# Source the lease slack instead of duplicating an unrelated lock constant.
# shellcheck source=../../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
run_number=0
request() { # -> a fresh generation the session's current request names
  run_number=$((run_number + 1))
  rm -f "$repo/.agents/state/last-verdict.json.$scope"  # the gate consumed the last PASS
  printf '%s-1-1 %s cksum-1-1\n' "$((100 + run_number))" "$(( $(date +%s) + 600 ))" \
    >"$repo/.agents/state/verdict-request.$scope"
  printf '%s-1-1' "$((100 + run_number))"
}
for scenario in claude:default:240 claude:10:20 claude:3480:3540 override:default:240 override:10:20; do
  route="${scenario%%:*}"; rest="${scenario#*:}"
  timeout="${rest%:*}"; expected_stop="${rest#*:}"
  runner_env=(env -u VERDICT_AUDITOR_TIMEOUT -u VERDICT_AUDITOR_CMD)
  [[ "$timeout" == default ]] || runner_env+=("VERDICT_AUDITOR_TIMEOUT=$timeout")
  [[ "$route" != override ]] || runner_env+=('VERDICT_AUDITOR_CMD=bash "$CAPTURE_HELPER"')
  generation="$(request)"
  started="$(date +%s)"
  (cd "$repo" && "${runner_env[@]}" CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST=claude \
    LOCK_CAPTURE="$scratch/lock" CAPTURE_HELPER="$scratch/bin/claude" AUDIT_SCOPE="$scope" \
    HISTORY_HELPER="$plugin/tests/audit/fixtures/audit-history-result.sh" \
    CODEX_BIN="$scratch/unavailable" PATH="$scratch/bin:$PATH" \
    bash "$plugin/.agents/hooks/audit/run-verdict-audit.sh" "$repo/transcript.jsonl" \
      "$session" "$generation" >"$scratch/out" 2>"$scratch/err") || {
        cat "$scratch/err" >&2; exit 1;
      }
  finished="$(date +%s)"
  deadline="$(awk '{print $2}' "$scratch/lock")"
  if ! [[ "$deadline" =~ ^[0-9]+$ ]] \
    || (( deadline < started + expected_stop + verdict_audit_deadline_slack_seconds \
      || deadline > finished + expected_stop + verdict_audit_deadline_slack_seconds )); then
    printf 'FAIL: %s timeout %s: lease must cover %ss stop plus %ss slack; got %ss\n' \
      "$route" "$timeout" "$expected_stop" "$verdict_audit_deadline_slack_seconds" "$((deadline-started))" >&2
    exit 1
  fi
  printf 'PASS: %s timeout %s stops at %ss with bounded lease\n' "$route" "$timeout" "$expected_stop"
done
generation="$(request)"
if (cd "$repo" && env VERDICT_AUDITOR_TIMEOUT=3500 CLAUDE_PROJECT_DIR="$repo" \
    bash "$plugin/.agents/hooks/audit/run-verdict-audit.sh" "$repo/transcript.jsonl" \
      "$session" "$generation" >"$scratch/out" 2>"$scratch/err"); then
  printf 'FAIL: timeout accepted without room for its record window\n' >&2; exit 1
fi
[[ "$(cat "$scratch/err")" == *'no room for the bounded record window'* ]]
printf 'PASS: oversized total runtime is rejected before launch\n'
