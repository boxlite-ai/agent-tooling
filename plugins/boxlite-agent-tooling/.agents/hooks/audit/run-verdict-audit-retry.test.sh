#!/usr/bin/env bash
# Real same-generation retries, including history and publication interference.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
runner="$plugin/.agents/hooks/audit/run-verdict-audit.sh"
# shellcheck source=../../lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    printf 'PASS: %s\n' "$1"
  else
    printf 'FAIL: %s (got=%s want=%s)\n' "$1" "$2" "$3" >&2
    fail=$((fail + 1))
  fi
}
export VERDICT_AUDITOR_CMD="bash $plugin/scripts/fixtures/audit-history-auditor.sh"
export AUDITOR_PROMPT_AFTER_SECONDS=0
generation=171-1-1
for scenario in pass fail replacement newer in_place fifo symlink directory revoked history; do
  mkdir "$scratch/$scenario"
  cd "$scratch/$scenario"
  git init -q
  git config user.email test@example.test
  git config user.name tester
  printf '.agents/state/\n' > .gitignore
  git add .gitignore
  git -c core.hooksPath=/dev/null commit -qm base
  export CLAUDE_PROJECT_DIR="$PWD"
  mkdir -p .agents/state
  scope="$(verdict_audit_scope_identity retry-session "$PWD")"
  stable="$PWD/.agents/state/last-verdict.json.$scope"
  request="$PWD/.agents/state/verdict-request.$scope"
  printf '%s %s cksum-1-1\n' "$generation" "$(( $(date +%s) + 600 ))" > "$request"
  printf '1\n' > ".agents/state/verdict-prompt-epoch.$scope"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass."}]}}\n' \
    > .agents/state/transcript.jsonl
  TEST_HISTORY_VERDICT=FAIL bash "$runner" "$PWD/.agents/state/transcript.jsonl" \
    retry-session "$generation" > .agents/state/first.out 2> .agents/state/first.err
  cp "$stable" .agents/state/original.json
  original_identity="$(verdict_audit_path_identity "$stable")"
  cat > .agents/state/interfere.sh <<'INTERFERE'
if [[ -z "${RETRY_TEST_OWNER:-}" ]]; then
  export RETRY_TEST_OWNER="$$"
  retry_interfere() {
    [[ "$$" == "$RETRY_TEST_OWNER" && "$BASH_COMMAND" == 'published_identity=""' \
      && ! -e "$CLAUDE_PROJECT_DIR/.agents/state/barrier" ]] || return 0
    touch "$CLAUDE_PROJECT_DIR/.agents/state/barrier"
    case "$RETRY_SCENARIO" in
      replacement|newer)
        jq --arg scenario "$RETRY_SCENARIO" \
          '.findings=["concurrent result"] | if $scenario == "newer" then .generation="171-2-2" else . end' \
          "$verdict_file" > "$verdict_file.new"
        mv "$verdict_file.new" "$verdict_file"
        ;;
      in_place)
        contents="$(jq '.findings=["concurrent result"]' "$verdict_file")"
        printf '%s\n' "$contents" > "$verdict_file"
        ;;
      fifo|symlink|directory)
        mv "$verdict_file" "$verdict_file.original"
        case "$RETRY_SCENARIO" in
          fifo) mkfifo "$verdict_file" ;;
          symlink) ln -s "$verdict_file.original" "$verdict_file" ;;
          directory) mkdir "$verdict_file" ;;
        esac
        ;;
      revoked) rm -f "$audit_request_file" ;;
    esac
  }
  set -T
  trap retry_interfere DEBUG
fi
INTERFERE
  retry_verdict=PASS
  [[ "$scenario" != fail ]] || retry_verdict=FAIL
  command="$VERDICT_AUDITOR_CMD"
  if [[ "$scenario" == history ]]; then
    # shellcheck disable=SC2016 # Expanded by the model seam's child shell.
    command+='; jq '\''.history_review.dispositions=[]'\'' "$VERDICT_AUDITOR_OUTPUT_FILE" > "$VERDICT_AUDITOR_OUTPUT_FILE.bad"; mv "$VERDICT_AUDITOR_OUTPUT_FILE.bad" "$VERDICT_AUDITOR_OUTPUT_FILE"'
  fi
  rc=0
  RETRY_SCENARIO="$scenario" BASH_ENV="$PWD/.agents/state/interfere.sh" \
    TEST_HISTORY_VERDICT="$retry_verdict" VERDICT_AUDITOR_CMD="$command" \
    bash "$runner" "$PWD/.agents/state/transcript.jsonl" retry-session "$generation" \
    > .agents/state/retry.out 2> .agents/state/retry.err || rc=$?
  case "$scenario" in
    pass|fail)
      check "$scenario retry publishes" "$rc" 0
      check "$scenario published verdict" "$(jq -r .verdict "$stable")" "$retry_verdict"
      check "$scenario retires the prior inode" \
        "$([[ "$(verdict_audit_path_identity "$stable")" != "$original_identity" ]] && echo yes || echo no)" yes
      history_path="$(printf '%s\n' "$PWD"/.agents/state/audit-history-*.json)"
      check "$scenario preserves binding and reconciles F1" \
        "$(jq -r --arg verdict "$retry_verdict" '
          (.attempts | length) == 2 and
          .attempts[0].input.binding == .attempts[1].input.binding and
          .attempts[1].outcome.verdict == $verdict and
          .registry[0].status == (if $verdict == "PASS" then "resolved" else "open" end)
        ' "$history_path")" true
      ;;
    revoked) check 'revocation cancels retry' "$rc" 130 ;;
    history)
      check 'unreconciled PASS rejected' "$rc" 1
      check 'history rejection retains prior FAIL' "$(cat "$stable")" "$(cat .agents/state/original.json)"
      ;;
    *)
      check "$scenario blocks handoff" "$rc" 1
      check "$scenario reaches handoff boundary" "$([[ -e .agents/state/barrier ]] && echo yes || echo no)" yes
      case "$scenario" in
        fifo) preserved="$([[ -p "$stable" ]] && echo yes || echo no)" ;;
        symlink) preserved="$([[ -L "$stable" ]] && echo yes || echo no)" ;;
        directory) preserved="$([[ -d "$stable" ]] && echo yes || echo no)" ;;
        *) preserved="$(jq -r '.findings == ["concurrent result"]' "$stable")" ;;
      esac
      case "$scenario" in fifo|symlink|directory) expected=yes ;; *) expected=true ;; esac
      check "$scenario preserves competing state" "$preserved" "$expected"
      ;;
  esac
done
exit "$(( fail > 0 ))"
