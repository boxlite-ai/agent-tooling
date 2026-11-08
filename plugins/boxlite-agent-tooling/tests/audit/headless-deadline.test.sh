#!/usr/bin/env bash
# Stub only the model boundary; real runners own timing, binding, and persistence.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
mkdir "$scratch/bin"
cat >"$scratch/bin/auditor" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" != --version ]] || { printf 'codex-cli fixture\n'; exit 0; }
stream=false; output="${VERDICT_AUDITOR_OUTPUT_FILE:-}"
while (( $# )); do
  case "$1" in
    --input-format) stream=true; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$stream" == true ]]; then
  IFS= read -r frame
  prompt="$(jq -r '.message.content' <<<"$frame")"
else
  prompt="$(cat)"
fi
[[ "$prompt" == *'## Runtime deadline'* && "$prompt" == *'zero checks completed'* ]]
task="$(sed -n '/^{"repo_root":/p' <<<"$prompt")"
if [[ -z "$task" ]]; then
  task="$(sed -n 's/^History input JSON: //p' <<<"$prompt")"
fi
history="$(jq -er .history_path <<<"$task")"
# Deliberately finish after the 4-second investigation budget, inside its record window.
sleep 5
jq '.attempts[-1].input.binding + {verdict:"PASS",proof:[],findings:[],
  advisories:["low: unchecked at deadline: evidence remains unread; finish review"]}
  | if has("command_kind") then del(.proof) else . end' "$history" >"$output"
bash "$DEADLINE_FIXTURE" "$task" "$output" bind
jq '.history_review.coverage |= {reviewed:[],unread:.reviewed}' "$output" >"$output.tmp"
mv "$output.tmp" "$output"
if [[ "$stream" == true ]]; then
  printf '%s\n' '{"type":"result","subtype":"success","result":"PASS"}'
  cat >/dev/null
fi
STUB
chmod +x "$scratch/bin/auditor"
ln -s auditor "$scratch/bin/claude"
ln -s auditor "$scratch/bin/codex"
export PATH="$scratch/bin:$PATH" CODEX_BIN="$scratch/bin/codex"
export DEADLINE_FIXTURE="$plugin/tests/audit/fixtures/audit-history-result.sh"
unset VERDICT_AUDITOR_CMD BOXLITE_HOOK_HOST PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
for library in verdict-audit-state audit-request; do
  # shellcheck source=/dev/null
  source "$plugin/.agents/lib/$library.sh"
done
for route in claude codex override git; do
  repo="$scratch/$route"; mkdir "$repo"
  git -C "$repo" init -q
  printf '.agents/\n' >"$repo/.gitignore"
  printf 'initial\n' >"$repo/code"
  git -C "$repo" add .
  git -C "$repo" -c core.hooksPath=/dev/null -c user.name=test -c user.email=t@t.test commit -qm base
  mkdir -p "$repo/.agents/state"
  scope="$(verdict_audit_scope_identity "$route-session" "$repo")"
  epoch=101-201-1; generation=301-401-1
  printf '%s\n' "$epoch" >"$repo/.agents/state/verdict-prompt-epoch.$scope"
  if [[ "$route" == git ]]; then
    printf 'changed\n' >"$repo/code"; git -C "$repo" add code
    (cd "$repo" && env AUDITOR_SESSION_SCOPE="$scope" AUDITOR_PROMPT_EPOCH="$epoch" \
      COMMIT_PUSH_AUDITOR_TIMEOUT=4 CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
      bash "$plugin/.agents/hooks/audit/run-commit-push-audit.sh" commit 'git commit -m "test: deadline"' \
      >"$scratch/out" 2>"$scratch/err") || { cat "$scratch/err" >&2; exit 1; }
  else
    request="$generation $(( $(date +%s) + 3600 )) cksum-1-1"
    printf '%s\n' "$request" >"$repo/.agents/state/verdict-request.$scope"
    audit_request_context_write "$repo" "$scope" "$request" "$epoch"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"tests passed"}]}}\n' >"$scratch/transcript"
    runner_env=(env "BOXLITE_HOOK_HOST=$route")
    [[ "$route" != override ]] || runner_env=(env BOXLITE_HOOK_HOST=claude "VERDICT_AUDITOR_CMD=bash \"$scratch/bin/auditor\"")
    (cd "$repo" && "${runner_env[@]}" CLAUDE_PROJECT_DIR="$repo" VERDICT_AUDITOR_TIMEOUT=4 \
      bash "$plugin/.agents/hooks/audit/run-verdict-audit.sh" "$scratch/transcript" \
      "$route-session" "$generation" "$scope" >"$scratch/out" 2>"$scratch/err") \
      || { cat "$scratch/err" >&2; exit 1; }
  fi
  histories=("$repo"/.agents/state/audit-history-*.json)
  jq -e '.attempts[-1].outcome | .verdict == "PASS" and
    .deadline_review.recorded_at >= .deadline_review.deadline and
    (.history_review.coverage.unread | length) > 0 and
    (.evidence.advisories | length) > 0' "${histories[0]}" >/dev/null
  printf 'PASS: %s runner records truthful deadline PASS during its bounded record window\n' "$route"
done
