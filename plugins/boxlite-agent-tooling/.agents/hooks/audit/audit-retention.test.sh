#!/usr/bin/env bash
# A real Stop/runner pair must distinguish retained work from current-turn authority.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export XDG_CONFIG_HOME="$scratch/config" BOXLITE_HOOK_HOST=unknown
export CODEX_BIN="$scratch/no-model" TEST_HISTORY_RESULT_HELPER="$plugin_root/scripts/fixtures/audit-history-result.sh"
export RETENTION_AUDITOR="$scratch/auditor.sh" VERDICT_AUDITOR_CMD='bash "$RETENTION_AUDITOR"'
export VERDICT_CLASSIFIER_CMD='while IFS= read -r line; do :; done; printf "YES\n"'
pass=0 fail=0 cases=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf 'PASS %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s: got <%s>, want <%s>\n' "$1" "$2" "$3"; fi
}
cat > "$RETENTION_AUDITOR" <<'AUDITOR'
set -euo pipefail
state="$CLAUDE_PROJECT_DIR/.agents/state"
task="$(cat | sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }')"
printf '%s\n' "$task" > "$state/task"
printf 'started\n' >> "$state/starts"
previous="$(jq -r .previous_dossier_path <<< "$task")"
cp "$previous" "$state/received-prior.json"
touch "$state/started"
for _ in {1..750}; do [[ -e "$state/release" ]] && break; sleep 0.02; done
[[ -e "$state/release" ]] || exit 9
idx="$(mktemp)"; GIT_INDEX_FILE="$idx" git read-tree HEAD; GIT_INDEX_FILE="$idx" git add -A
tree="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg tree "$tree" --arg gen "$VERDICT_AUDITOR_GENERATION" \
  '{branch:$branch,head:$head,tree_hash:$tree,generation:$gen,verdict:"PASS",proof:[],findings:[]}' \
  > "$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$TEST_HISTORY_RESULT_HELPER" "$task" "$VERDICT_AUDITOR_OUTPUT_FILE"
AUDITOR
prompt() {
  jq -nc --arg prompt "$1" '{hook_event_name:"UserPromptSubmit",session_id:"retention",prompt:$prompt}' \
    | (cd "$repo" && bash "$plugin_root/.agents/hooks/cancel-verdict-audit.sh")
}
stop() {
  jq -nc --arg text "$1" '{hook_event_name:"Stop",session_id:"retention",last_assistant_message:$text}' \
    | (cd "$repo" && bash "$plugin_root/.agents/hooks/stop-gate.sh")
}
setup() {
  cases=$((cases+1)); repo="$scratch/repo-$cases"; state="$repo/.agents/state"
  mkdir -p "$state"
  export CLAUDE_PROJECT_DIR="$repo"
  git -C "$repo" init -q; git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name tester
  printf '.agents/state/\n' > "$repo/.gitignore"; printf 'base\n' > "$repo/production"
  git -C "$repo" add -A; git -C "$repo" -c core.hooksPath=/dev/null commit -qm base
  scope="git-$(printf retention | git -C "$repo" hash-object --stdin)"
  request="$state/verdict-request.$scope"
  context="$state/verdict-request-context.json.$scope"
  epoch="$state/verdict-prompt-epoch.$scope"
  prompt 'check the work' > "$state/prompt-output"
  original_epoch="$(cat "$epoch")"
  stop 'The tests passed.' > "$state/stop-output" 2> "$state/stop-error" & stop_pid=$!
  for _ in {1..500}; do [[ -e "$state/started" ]] && break; sleep 0.02; done
  [[ -e "$state/started" ]] || { printf 'Fixture auditor never started\n' >&2; exit 2; }
  original_request="$(cat "$request")"
}

setup
prompt "what's happening?" > "$state/nudge-output"
check 'a status prompt retains the exact running request' "$(cat "$request" 2>/dev/null)" "$original_request"
check 'retention still rotates prompt-scoped authority' "$([[ "$(cat "$epoch")" != "$original_epoch" ]] && echo changed)" changed
prompt 'keep going' > "$state/nudge-output"
check 'a second status prompt does not restart the worker' "$(cat "$state/starts")" started
touch "$state/release"; wait "$stop_pid"; completion=$?
check 'retained original audit completes and leaves its dossier' \
  "status=$completion dossier=$([[ -f "$state/last-verdict.json.$scope" ]] && echo present || echo absent)" \
  'status=0 dossier=present'
VERDICT_CLASSIFIER_CMD='while IFS= read -r line; do :; done; printf "NO\n"' \
  stop 'The tests passed.' > "$state/new-turn-output" 2> "$state/new-turn-error"
check 'identical wording in a new turn cannot consume the old PASS' \
  "$(grep -c 'dossier PASS-allow' "$state/verdict-decisions.log.$scope" || true)" 0
stop 'The deployment is healthy.' > "$state/new-claim-output" 2> "$state/new-claim-error"
check 'new claims require a second independent invocation' "$(wc -l < "$state/starts" | tr -d ' ')" 2
check 'completed unchanged proof is supplied only as prior evidence' \
  "$(jq -r .verdict "$state/received-prior.json" 2>/dev/null)" PASS

for change in tracked untracked head branch symlink fifo expired; do
  setup
  case "$change" in
    tracked) printf 'changed\n' > "$repo/production" ;;
    untracked) printf 'new\n' > "$repo/new-file" ;;
    head) git -C "$repo" -c core.hooksPath=/dev/null commit --allow-empty -qm changed ;;
    branch) git -C "$repo" checkout -qb changed ;;
    symlink) rm -f "$context"; ln -s "$state/task" "$context" ;;
    fifo) rm -f "$context"; mkfifo "$context" ;;
    expired) read -r generation _ message <<< "$original_request"; printf '%s 1 %s\n' "$generation" "$message" > "$request" ;;
  esac
  prompt 'keep going' > "$state/nudge-output"
  check "changed or unsafe context ($change) revokes the request" \
    "$([[ -e "$request" ]] && echo present || echo absent)" absent
  touch "$state/release"; wait "$stop_pid" || true
  check "canceled result ($change) cannot publish a dossier" \
    "$([[ -e "$state/last-verdict.json.$scope" ]] && echo present || echo absent)" absent
done

setup
prompt 'status please' > "$state/nudge-output"
touch "$state/release"; wait "$stop_pid"
rm -f "$context"
VERDICT_CLASSIFIER_CMD='while IFS= read -r line; do :; done; printf "NO\n"' \
  stop 'The tests passed.' > "$state/new-turn-output" 2> "$state/new-turn-error"
check 'missing retained context cannot authorize a new turn' \
  "$(grep -c 'dossier PASS-allow' "$state/verdict-decisions.log.$scope" || true)" 0

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
