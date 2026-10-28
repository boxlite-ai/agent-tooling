#!/usr/bin/env bash
# Regression checks through the public runner and Stop boundaries; no live models.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export XDG_CONFIG_HOME="$scratch/config"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
export CODEX_BIN="$scratch/no-model" BOXLITE_HOOK_HOST=unknown
export TEST_HISTORY_RESULT_HELPER="$plugin_root/scripts/fixtures/audit-history-result.sh"
export AUDIT_TEST_PROGRAM="$scratch/auditor.sh"
export VERDICT_AUDITOR_CMD='bash "$AUDIT_TEST_PROGRAM"'
export VERDICT_CLASSIFIER_CMD='while IFS= read -r line; do :; done; printf "called\n" >> "$CLAUDE_PROJECT_DIR/.agents/state/classifier"; printf "NO\n"'
pass=0 fail=0 cases=0
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf 'PASS %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL %s: got <%s>, want <%s>\n' "$1" "$2" "$3"
  fi
}
setup() {
  cases=$((cases + 1)); repo="$scratch/repo-$cases"
  mkdir -p "$repo/.agents/state" "$XDG_CONFIG_HOME/boxlite-agent-tooling"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name tester
  printf '.agents/state/\n' > "$repo/.gitignore"
  printf 'original\n' > "$repo/production"
  git -C "$repo" add -A
  git -C "$repo" -c core.hooksPath=/dev/null commit -qm base
  export CLAUDE_PROJECT_DIR="$repo"
  config="$XDG_CONFIG_HOME/boxlite-agent-tooling/network.json"
  rm -f "$config"
  unset AUDIT_TEST_EXIT AUDIT_TEST_NOISE AUDIT_TEST_WAIT
}
run_runner() {
  runner_status=0
  (cd "$repo" && bash "$plugin_root/.agents/hooks/audit/run-verdict-audit.sh" -) \
    > "$repo/.agents/state/stdout" 2> "$repo/.agents/state/stderr" || runner_status=$?
}
cat > "$AUDIT_TEST_PROGRAM" <<'AUDITOR'
set -euo pipefail
state="$CLAUDE_PROJECT_DIR/.agents/state"
prompt="$(cat)"
task="$(sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }' <<< "$prompt")"
printf '%s' "$task" > "$state/task"
printf '%s\n' "${HTTPS_PROXY-unset}" > "$state/proxy"
printf '%s\n' started >> "$state/started"
if [[ "${AUDIT_TEST_NOISE:-false}" == true ]]; then
  perl -e 'print STDERR "x" x 20000, "\nAuthorization: ", join(" ","Bearer","fixture-secret-token"), "\nconnection refused\n"'
fi
if [[ "${AUDIT_TEST_WAIT:-false}" == true ]]; then
  for _ in {1..500}; do
    [[ -e "$state/release" ]] && break
    sleep 0.02
  done
  [[ -e "$state/release" ]] || exit 9
fi
index="$(mktemp)"
GIT_INDEX_FILE="$index" git read-tree HEAD
GIT_INDEX_FILE="$index" git add -A
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
rm -f "$index"
jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg tree "$tree" --arg generation "$VERDICT_AUDITOR_GENERATION" \
  '{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,
    verdict:"PASS",proof:[],findings:[]}' > "$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$TEST_HISTORY_RESULT_HELPER" "$task" "$VERDICT_AUDITOR_OUTPUT_FILE"
exit "${AUDIT_TEST_EXIT:-0}"
AUDITOR

setup
export AUDIT_TEST_EXIT=7 AUDIT_TEST_NOISE=true
run_runner
check 'nonzero auditor cannot publish a plausible PASS' \
  "status=$runner_status dossier=$([[ -e "$repo/.agents/state/last-verdict.json" ]] && echo present || echo absent)" \
  'status=1 dossier=absent'
diagnostic="$(tail -n 1 "$repo/.agents/state/audit-diagnostics.jsonl" 2>/dev/null || true)"
check 'failure diagnostic preserves route and child status' \
  "$(jq -r '[.route,.process_exit,.outcome] | @tsv' <<< "$diagnostic" 2>/dev/null)" \
  $'override\t7\tERROR'
check 'diagnostic stderr is bounded, useful, and masks authorization' \
  "$(jq -r '(.stderr_tail | length <= 4096 and contains("connection refused") and
    (contains("fixture-secret-token") | not)) and (.elapsed_seconds >= 0)' <<< "$diagnostic" 2>/dev/null)" true

setup
printf '{"HTTPS_PROXY":"http://proxy.example.invalid:8080"}\n' > "$config"
chmod 600 "$config"
run_runner
check 'user network configuration reaches the actual child' \
  "status=$runner_status proxy=$(cat "$repo/.agents/state/proxy" 2>/dev/null)" \
  'status=0 proxy=http://proxy.example.invalid:8080'
HTTPS_PROXY='' run_runner
check 'an explicit empty proxy overrides configured proxy' "$(cat "$repo/.agents/state/proxy")" ''
HTTPS_PROXY='http://inherited.example.invalid:8081' run_runner
check 'an inherited proxy takes precedence' "$(cat "$repo/.agents/state/proxy")" \
  'http://inherited.example.invalid:8081'

for invalid in malformed unknown-key bad-url writable symlink fifo oversized; do
  setup
  case "$invalid" in
    malformed) printf 'not-json\n' > "$config" ;;
    unknown-key) printf '{"COMMAND":"do-not-execute"}\n' > "$config" ;;
    bad-url) printf '{"HTTPS_PROXY":"proxy-without-scheme"}\n' > "$config" ;;
    writable) printf '{}\n' > "$config"; chmod 666 "$config" ;;
    symlink) printf '{}\n' > "$scratch/target"; ln -s "$scratch/target" "$config" ;;
    fifo) mkfifo "$config" ;;
    oversized) perl -e 'print " " x 8193' > "$config" ;;
  esac
  run_runner
  check "unsafe network configuration ($invalid) fails before model launch" \
    "status=$runner_status child=$([[ -e "$repo/.agents/state/started" ]] && echo started || echo absent)" \
    'status=2 child=absent'
done

for claim in '60/60 tests passed.' 'The test run passed: 60 passed, 0 failed, exit 0.'; do
  setup
  jq -nc --arg message "$claim" '{hook_event_name:"Stop",last_assistant_message:$message}' \
    | (cd "$repo" && bash "$plugin_root/.agents/hooks/stop-gate.sh") \
    > "$repo/.agents/state/stop-output" 2> "$repo/.agents/state/stop-error"
  check "count wording uses the shared classifier: $claim" \
    "$(cat "$repo/.agents/state/classifier" 2>/dev/null)" called
  check 'Stop decisions include elapsed time' \
    "$(awk '/elapsed_seconds=[0-9]+/ {found=1} END {print found+0}' "$repo/.agents/state/verdict-decisions.log")" 1
done

cat > "$scratch/codex" <<'CODEX'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" != --version ]] || { printf 'codex-cli fixture\n'; exit 0; }
output=""
while (( $# > 0 )); do
  case "$1" in
    --output-last-message) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
printf '%s\n' "${HTTPS_PROXY-unset}" > .agents/state/commit-proxy
if [[ "$COMMIT_CASE" == error ]]; then
  printf 'Authorization: %s %s\nconnection refused\n' 'Bearer' 'fixture-secret-token' >&2
  exit 7
fi
findings='[]'; [[ "$COMMIT_CASE" != FAIL ]] || findings='["Fixture defect"]'
jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg diff "$(git diff --cached --no-ext-diff | shasum -a 256 | awk '{print $1}')" \
  --arg command "$(printf '%s' "$COMMIT_COMMAND" | shasum -a 256 | awk '{print $1}')" \
  --arg subject "$(printf '%s' "$COMMIT_SUBJECT" | shasum -a 256 | awk '{print $1}')" \
  --arg verdict "$COMMIT_CASE" --argjson findings "$findings" \
  '{branch:$branch,head:$head,diff_hash:$diff,command_hash:$command,commit_subject_hash:$subject,
    command_kind:"commit",verdict:$verdict,findings:$findings,advisories:[]}' > "$output"
CODEX
chmod +x "$scratch/codex"
export COMMIT_SUBJECT='fix(audit): exercise execution diagnostics'
export COMMIT_COMMAND="git commit -m '$COMMIT_SUBJECT'"
for COMMIT_CASE in error PASS FAIL; do
  setup
  printf '{"HTTPS_PROXY":"http://proxy.example.invalid:8080"}\n' > "$config"
  chmod 600 "$config"
  printf 'changed\n' > "$repo/production"
  git -C "$repo" add production
  export COMMIT_CASE
  commit_status=0
  (cd "$repo" && CODEX_BIN="$scratch/codex" \
    bash "$plugin_root/.agents/hooks/audit/run-commit-push-audit.sh" commit "$COMMIT_COMMAND") \
    > "$repo/.agents/state/commit-output" 2> "$repo/.agents/state/commit-error" || commit_status=$?
  diagnostic="$(tail -n 1 "$repo/.agents/state/audit-diagnostics.jsonl" 2>/dev/null || true)"
  expected="status=1 route=codex process=0 outcome=FAIL"
  [[ "$COMMIT_CASE" != PASS ]] || expected="status=0 route=codex process=0 outcome=PASS"
  [[ "$COMMIT_CASE" != error ]] || expected="status=1 route=codex process=7 outcome=ERROR"
  check "commit runner distinguishes $COMMIT_CASE from execution failure" \
    "status=$commit_status $(jq -r '"route=\(.route) process=\(.process_exit) outcome=\(.outcome)"' <<< "$diagnostic")" "$expected"
  check 'user proxy configuration reaches the commit auditor' \
    "$(cat "$repo/.agents/state/commit-proxy" 2>/dev/null)" 'http://proxy.example.invalid:8080'
done

setup
printf 'changed\n' > "$repo/production"
git -C "$repo" add production
commit_status=0
(cd "$repo" && CODEX_COMMIT_PUSH_AUDIT_MODE=local \
  bash "$plugin_root/.agents/hooks/audit/run-commit-push-audit.sh" commit "$COMMIT_COMMAND") \
  > "$repo/.agents/state/commit-output" 2> "$repo/.agents/state/commit-error" || commit_status=$?
diagnostic="$(tail -n 1 "$repo/.agents/state/audit-diagnostics.jsonl" 2>/dev/null || true)"
check 'offline audit records its local verdict' \
  "status=$commit_status $(jq -r '[.route,.outcome] | join(" ")' <<< "$diagnostic")" 'status=0 local PASS'

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
