#!/usr/bin/env bash
# Capture the real runner's lease without waiting for the model deadline.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/.agents/state" "$scratch/bin"
git -C "$repo" init -q
git -C "$repo" -c user.name=tester -c user.email=t@t.test commit --allow-empty -qm base
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"tests pass"}]}}\n' >"$repo/transcript.jsonl"
cat >"$scratch/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -eu
IFS= read -r frame
cp "$CLAUDE_PROJECT_DIR/.agents/state/verdict-audit.lock" "$LOCK_CAPTURE"
printf '{"branch":"main","head":"h","tree_hash":"t","verdict":"PASS","proof":[],"findings":[]}' \
  >"$CLAUDE_PROJECT_DIR/.agents/state/last-verdict.json"
printf '%s\n' '{"type":"result","subtype":"success","result":"PASS"}'
cat >/dev/null
STUB
chmod +x "$scratch/bin/claude"
# Source the lease slack instead of duplicating an unrelated lock constant.
# shellcheck source=../../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
for scenario in claude:default:240 claude:10:20 claude:3480:3540 override:default:240 override:10:20; do
  route="${scenario%%:*}"; rest="${scenario#*:}"
  timeout="${rest%:*}"; expected_stop="${rest#*:}"
  runner_env=(env -u VERDICT_AUDITOR_TIMEOUT -u VERDICT_AUDITOR_CMD)
  [[ "$timeout" == default ]] || runner_env+=("VERDICT_AUDITOR_TIMEOUT=$timeout")
  [[ "$route" != override ]] || runner_env+=('VERDICT_AUDITOR_CMD=bash "$CAPTURE_HELPER"')
  started="$(date +%s)"
  (cd "$repo" && "${runner_env[@]}" CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST=claude \
    LOCK_CAPTURE="$scratch/lock" CAPTURE_HELPER="$scratch/bin/claude" \
    CODEX_BIN="$scratch/unavailable" PATH="$scratch/bin:$PATH" \
    bash "$plugin/.agents/hooks/audit/run-verdict-audit.sh" "$repo/transcript.jsonl" \
      >"$scratch/out" 2>"$scratch/err") || {
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
if (cd "$repo" && env VERDICT_AUDITOR_TIMEOUT=3500 CLAUDE_PROJECT_DIR="$repo" \
    bash "$plugin/.agents/hooks/audit/run-verdict-audit.sh" "$repo/transcript.jsonl" \
      >"$scratch/out" 2>"$scratch/err"); then
  printf 'FAIL: timeout accepted without room for its record window\n' >&2; exit 1
fi
[[ "$(cat "$scratch/err")" == *'no room for the bounded record window'* ]]
printf 'PASS: oversized total runtime is rejected before launch\n'
