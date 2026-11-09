#!/usr/bin/env bash
# Tests for the auditor model table (.agents/auditor-models.tsv, design #474): the
# loader's fail-closed parsing, agreement with agent frontmatter, and the flags,
# environment and diagnostics the headless verdict runner derives from it.
#
# Run with:  bash tests/audit/auditor-model.test.sh
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$PLUGIN/.agents/hooks/audit/run-verdict-audit.sh"
# shellcheck source=../../.agents/lib/auditor-model.sh
source "$PLUGIN/.agents/lib/auditor-model.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
pass=0
fail=0
check_eq() {  # desc got want
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (got=%s want=%s)\n' "$1" "$2" "$3"
  fi
}
fake_root() {  # name, table text on stdin -> tooling root holding only that table
  mkdir -p "$scratch/$1/.agents"
  cat > "$scratch/$1/.agents/auditor-models.tsv"
  printf '%s' "$scratch/$1"
}
load() {  # root auditor host -> "model effort" or "error"
  if auditor_model_load "$@" 2>/dev/null; then
    printf '%s %s' "$auditor_model" "$auditor_effort"
  else
    printf 'error'
  fi
}

echo "## Loader"
check_eq "shipped verdict auditor row" "$(load "$PLUGIN" verdict-auditor claude)" "claude-sonnet-5 xhigh"
check_eq "shipped classifier row" "$(load "$PLUGIN" verdict-classifier claude)" "claude-haiku-4-5-20251001 low"
root="$(printf 'a\tclaude\tm-1\tlow\r\n' | fake_root crlf)"
check_eq "CRLF table parses like LF" "$(load "$root" a claude)" "m-1 low"
root="$(printf 'a\tclaude\tm-1\tlow\n' | fake_root missing)"
check_eq "missing row fails" "$(load "$root" a codex)" "error"
root="$(printf 'a\tclaude\tm-1\t\n' | fake_root empty)"
check_eq "empty cell fails" "$(load "$root" a claude)" "error"
root="$(printf 'a\tclaude\tm-1\tturbo\n' | fake_root effort)"
check_eq "unknown effort fails" "$(load "$root" a claude)" "error"
root="$(printf 'a\tclaude\tm"1\tlow\n' | fake_root quote)"
check_eq "model outside the cell grammar fails" "$(load "$root" a claude)" "error"
root="$(printf 'a\tclaude\tm-1\tlow\na\tclaude\tm-2\thigh\n' | fake_root dup)"
check_eq "duplicate row fails" "$(load "$root" a claude)" "error"
check_eq "missing table fails" "$(load "$scratch/none" a claude)" "error"
auditor_model=unset auditor_effort=unset auditor_model_claude_args
check_eq "unset sends no Claude flag" "${#auditor_model_args[@]}" 0
auditor_model=m-1 auditor_effort=low auditor_model_codex_args
check_eq "pinned Codex row sends both overrides" "${auditor_model_args[*]}" \
  '-c model="m-1" -c model_reasoning_effort="low"'

echo "## Frontmatter agrees with the Claude Code rows"
for auditor in verdict-auditor commit-push-auditor design-auditor design-advisor; do
  spec="$PLUGIN/.claude/agents/$auditor.md"
  front="$(sed -n '2,/^---$/p' "$spec")"
  want_model="$(sed -n 's/^model: //p' <<<"$front")"
  want_effort="$(sed -n 's/^effort: //p' <<<"$front")"
  check_eq "$auditor frontmatter matches its row" "$(load "$PLUGIN" "$auditor" claude)" \
    "${want_model:-unset} ${want_effort:-unset}"
done

echo "## Headless verdict runner"
repo="$scratch/repo"
mkdir -p "$repo/.agents/state" "$scratch/bin"
git -C "$repo" init -q
printf '.agents/state/\n' > "$repo/.gitignore"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t.test commit -qm base
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"tests pass"}]}}\n' \
  > "$repo/transcript.jsonl"
cat > "$scratch/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Records argv and the inherited effort variable, then behaves like a passing auditor.
printf '%s\n' "$*" > "$STUB_ARGV"
printf '%s\n' "${CLAUDE_CODE_EFFORT_LEVEL-absent}" > "$STUB_ENV"
IFS= read -r _frame
printf '{"branch":"main","head":"h","tree_hash":"t","verdict":"PASS","proof":[],"findings":[]}' \
  > "$CLAUDE_PROJECT_DIR/.agents/state/last-verdict.json"
printf '%s\n' '{"type":"result","subtype":"success","result":"PASS"}'
cat >/dev/null
STUB
chmod +x "$scratch/bin/claude"
diagnostics="$repo/.agents/state/audit-diagnostics.jsonl"
run_claude() {  # extra env assignments...
  rm -f "$diagnostics"
  ( cd "$repo" && env -u VERDICT_AUDITOR_CMD "$@" BOXLITE_HOOK_HOST=claude \
      CLAUDE_PROJECT_DIR="$repo" PATH="$scratch/bin:$PATH" \
      STUB_ARGV="$scratch/argv" STUB_ENV="$scratch/env" \
      bash "$RUNNER" "$repo/transcript.jsonl" >/dev/null 2>&1 )
}
run_claude CLAUDE_CODE_EFFORT_LEVEL=max
check_eq "pinned run exits 0" "$?" 0
argv="$(cat "$scratch/argv")"
check_eq "row model and effort reach the CLI" \
  "$([[ "$argv" == *"--model claude-sonnet-5 --effort xhigh"* ]] && echo yes || echo no)" yes
check_eq "user effort override is dropped from the child" "$(cat "$scratch/env")" absent
check_eq "diagnostics record the pair and the dropped value" \
  "$(jq -c '.auditor' "$diagnostics")" \
  '{"model":"claude-sonnet-5","effort":"xhigh","model_source":"table","observed":"unobserved","dropped_effort_env":"max"}'
run_claude VERDICT_AUDITOR_MODEL=claude-test-model
argv="$(cat "$scratch/argv")"
check_eq "model override reaches the CLI" \
  "$([[ "$argv" == *"--model claude-test-model --effort xhigh"* ]] && echo yes || echo no)" yes
check_eq "diagnostics mark the override" "$(jq -r '.auditor.model_source' "$diagnostics")" override

echo "## Custom command echo"
run_override() {  # echoed model, echoed effort ("" omits the fields)
  rm -f "$diagnostics" "$repo/.agents/state/last-verdict.json"
  local echo_fields=""
  [[ -z "$1" ]] || echo_fields=",\"auditor_model\":\"$1\",\"auditor_effort\":\"$2\""
  ( cd "$repo" && env BOXLITE_HOOK_HOST=claude CLAUDE_PROJECT_DIR="$repo" \
      VERDICT_AUDITOR_CMD="cat >/dev/null; printf '%s %s\n' \"\$AUDITOR_MODEL\" \"\$AUDITOR_EFFORT\" > '$scratch/exported'; printf '{\"branch\":\"main\",\"head\":\"h\",\"tree_hash\":\"t\",\"verdict\":\"PASS\",\"proof\":[],\"findings\":[]$echo_fields}' > \"\$CLAUDE_PROJECT_DIR/.agents/state/last-verdict.json\"" \
      bash "$RUNNER" "$repo/transcript.jsonl" >/dev/null 2>&1 )
}
run_override claude-sonnet-5 xhigh
check_eq "matching echo is accepted" "$?" 0
check_eq "row is exported to the command" "$(cat "$scratch/exported")" "claude-sonnet-5 xhigh"
check_eq "matching echo is recorded as observed" "$(jq -r '.auditor.observed' "$diagnostics")" matched
run_override claude-other low
check_eq "mismatched echo has no authority" "$?" 1
check_eq "mismatch is recorded" "$(jq -r '.auditor.observed' "$diagnostics")" mismatch
run_override "" ""
check_eq "absent echo still counts" "$?" 0
check_eq "absent echo is recorded as unobserved" "$(jq -r '.auditor.observed' "$diagnostics")" unobserved

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
