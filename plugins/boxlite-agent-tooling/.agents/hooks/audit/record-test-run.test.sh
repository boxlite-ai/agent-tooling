#!/usr/bin/env bash
# Tests for .agents/hooks/record-test-run.sh: which commands leave a receipt, and what
# the receipt says about the run.
#
# Run with:  bash plugins/boxlite-agent-tooling/.agents/hooks/audit/record-test-run.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/record-test-run.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {  # desc got want
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got=$2 want=$3)"; fi
}

R="$(mktemp -d)"
git -C "$R" init -q
git -C "$R" config user.email t@t.test
git -C "$R" config user.name tester
printf '.agents/state/\n' > "$R/.gitignore"
printf 'one\n' > "$R/f"
git -C "$R" add -A
git -C "$R" commit -qm base
RECEIPTS="$R/.agents/state/test-runs"

run_hook() {  # event command [extra JSON merged into the payload]
  jq -nc --arg e "$1" --arg c "$2" --arg cwd "$R" --argjson extra "${3:-{\}}" \
    '{hook_event_name:$e, tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}} + $extra' \
    | (cd "$R" && bash "$HOOK")
}
receipt_count() { find "$RECEIPTS" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
newest() { jq -r "$1" "$(ls -1 "$RECEIPTS"/*.json | sort -t- -k1,1n -k2,2n | tail -1)"; }
working_tree() {
  local dir; dir="$(mktemp -d)"
  GIT_INDEX_FILE="$dir/index" git -C "$R" read-tree HEAD
  GIT_INDEX_FILE="$dir/index" git -C "$R" add -A
  GIT_INDEX_FILE="$dir/index" git -C "$R" write-tree
  rm -f "$dir/index"; rmdir "$dir"
}

echo "## A plain test run leaves a receipt bound to the working files"
printf 'two\n' > "$R/f"
run_hook PostToolUse 'make test:unit:rust' '{"tool_response":{"stdout":"ok","stderr":""}}'
check_eq "a successful Claude run is a pass with no exit code" \
  "count=$(receipt_count) status=$(newest .status) exit=$(newest .exit_code) command=$(newest .command)" \
  "count=1 status=pass exit=null command=make test:unit:rust"
check_eq "the receipt names HEAD and the tree of the uncommitted working files" \
  "head=$(newest .head) tree=$(newest .tree)" \
  "head=$(git -C "$R" rev-parse HEAD) tree=$(working_tree)"
if git -C "$R" diff --quiet --cached; then ok "the real index is untouched"; else bad "the real index is untouched"; fi

echo "## Failures carry their status"
run_hook PostToolUseFailure 'GOFLAGS=-count=1 make test:unit:go FILTER=Copy' \
  '{"error":"Exit code 2\nFAIL github.com/x"}'
check_eq "a Claude failure records fail and the exit code from the error" \
  "count=$(receipt_count) status=$(newest .status) exit=$(newest .exit_code)" \
  "count=2 status=fail exit=2"
run_hook PostToolUse 'make test:unit:c' '{"tool_response":{"exit_code":1,"stdout":""}}'
check_eq "a Codex non-zero exit code is a fail" \
  "count=$(receipt_count) status=$(newest .status) exit=$(newest .exit_code)" \
  "count=3 status=fail exit=1"
run_hook PostToolUseFailure 'make test:integration:rust FILTER=copy' '{"is_interrupt":true}'
check_eq "an interrupted run is not a pass" \
  "count=$(receipt_count) status=$(newest .status)" "count=4 status=interrupted"

echo "## Env prefixes, assignments and output redirections are still one run"
run_hook PostToolUse "env -u http_proxy -u https_proxy make test:unit:rust NEXTEST_FILTER_EXPR='not test(~jailer::seccomp)' > /tmp/unit.log 2>&1" \
  '{"tool_response":{"stdout":""}}'
check_eq "a redirected, env-prefixed run is recorded verbatim" \
  "count=$(receipt_count) status=$(newest .status)" "count=5 status=pass"

echo "## Anything else is not one test run"
for command in 'make test:unit:rust; echo done' 'make test:unit:rust && echo done' \
    'make test:unit:rust | tail -3' 'make test:unit:rust || true' 'make test:unit:rust &' \
    'make build' 'cargo test' 'make test:unit:rust $(echo x)' \
    'BOXLITE_HOME=$(mktemp -d) make test:integration:cli' 'echo make test:unit:rust' \
    "make test:unit:rust FILTER=\"\$(id)\""; do
  run_hook PostToolUse "$command" '{"tool_response":{"stdout":""}}'
done
check_eq "chained, piped, substituted and non-test commands leave no receipt" "$(receipt_count)" 5
run_hook PostToolUse 'make test:unit:rust' \
  '{"tool_input":{"command":"make test:unit:rust","run_in_background":true}}'
check_eq "a background job leaves no receipt" "$(receipt_count)" 5
run_hook PostToolUse 'make test:unit:rust' \
  '{"tool_response":{"stdout":"Command did not complete within its 600s timeout and was moved to the background"}}'
check_eq "a run the host moved to the background leaves no receipt" "$(receipt_count)" 5
run_hook PreToolUse 'make test:unit:rust'
check_eq "other events leave no receipt" "$(receipt_count)" 5

rm -rf "$R"
echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
