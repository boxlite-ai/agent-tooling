#!/usr/bin/env bash
# Tests for .agents/lib/subagent.sh
#
# The library's whole contract is the text it prints, because a hook cannot invoke a
# built-in — only name it. So the tests are mostly about what the emitted block does
# and does not say:
#
#   1. The route printed matches the host, and an unknown host still gets every route.
#      Narrowing is the point, but a host this library has not been taught about must
#      degrade to the menu rather than to a guess — a wrong single route is worse than
#      a menu. The Codex-only shape gets its own check because dropping the Claude
#      block also drops the text its message used to point at.
#   2. The choice comes ONLY from hook_host_kind. A grep guards that directly, because
#      the regression would be silent — a branch on CLAUDECODE or CODEX_SANDBOX still
#      emits a perfectly plausible-looking instruction, just the wrong one, and those
#      markers are exported to every child so a nested agent inherits them.
#   3. Every agent name the gates reference resolves to a real spec file. The Codex
#      route cites that path for the subagent to read, so a rename upstream turns into
#      an instruction pointing at nothing, and only a test can see it from here.
#
# This file uses PLUGIN_ROOT as an ordinary local (below), which is exactly the
# collision hook_host_kind's exported-only rule exists to survive. Leaving it is
# deliberate: it keeps a real instance of that hazard in the suite.
#
# Run with:  bash .agents/lib/subagent.test.sh
# Exits non-zero on any failure.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/subagent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
check()    { has "$2" "$3" && ok "$1" || bad "$1 (missing: $2)"; }
check_no() { has "$2" "$3" && bad "$1 (present: $2)" || ok "$1"; }

# Every case below that does not name a host runs with neither root exported, so it
# renders the unknown-host menu — the shape the whole suite was written against.
as_host() {  # claude | codex | unknown, then the subagent_instruction arguments
  local host="$1"; shift
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    case "$host" in
      claude) export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_FIXTURE" ;;
      codex)  export PLUGIN_ROOT="$PLUGIN_ROOT_FIXTURE" ;;
    esac
    subagent_instruction "$@"
  )
}
PLUGIN_ROOT_FIXTURE="$PLUGIN_ROOT"

echo "## An unknown host is still offered every route"
out="$(as_host unknown --agent verdict-auditor --root "$PLUGIN_ROOT" --task 'audit my turn')"
check    "names the Claude Code route"  "Claude Code"                 "$out"
check    "names the Codex route"        "Codex"                       "$out"
check    "uses the plugin-scoped Task() agent for Claude" \
  'Task(subagent_type="boxlite-agent-tooling:verdict-auditor"' "$out"
check_no "never emits the unavailable bare Claude agent" \
  'Task(subagent_type="verdict-auditor"' "$out"
check    "uses spawn_agent for Codex"   "collaboration.spawn_agent("  "$out"
check    "Codex starts without inherited parent history" \
  'fork_turns="none"' "$out"
check    "normalizes the Codex task name for its schema" \
  'task_name="verdict_auditor"' "$out"
check_no "never emits a hyphenated Codex task name" \
  'task_name="verdict-auditor"' "$out"
check    "carries the task text"        "audit my turn"               "$out"
task_occurrences="$(printf '%s' "$out" | grep -oF 'audit my turn' | wc -l | tr -d ' ')"
[[ "$task_occurrences" == 1 ]] \
  && ok "shared task text is rendered once across native routes" \
  || bad "shared task text is rendered once across native routes (count=$task_occurrences)"
# A backgrounded audit lets the turn end before the artifact lands, and the gate fires
# again on the way out — the re-block loop this wording exists to prevent.
check    "demands a synchronous run"    "SYNCHRONOUSLY"               "$out"
check    "spells out run_in_background" "run_in_background: false"    "$out"

# Interrupted Codex agents remain available under their task name. A verdict audit that
# is superseded by user input therefore needs a fresh generation-qualified name on the
# next round; otherwise spawn_agent collides with the canceled agent instead of auditing.
scoped="$(subagent_instruction --agent verdict-auditor --root "$PLUGIN_ROOT" \
          --task 'audit this generation' --codex-task-name verdict_auditor_301_302_4 \
          --codex-retry-existing)"
check "accepts a generation-qualified Codex task handle" \
  'task_name="verdict_auditor_301_302_4"' "$scoped"
check_no "the explicit handle replaces the fixed Codex task name" \
  'task_name="verdict_auditor"' "$scoped"
check "same-generation retry reuses the exact Codex handle" \
  "collaboration.followup_task(" "$scoped"
check "same-generation retry targets the retained handle" \
  'target="verdict_auditor_301_302_4"' "$scoped"
check "a running retained auditor is waited on" \
  "already running" "$scoped"
retry_prompt_count="$(printf '%s' "$scoped" | grep -oF 'audit this generation' \
  | wc -l | tr -d ' ')"
[[ "$retry_prompt_count" == 1 ]] \
  && ok "the full task is rendered once for the shared native routes" \
  || bad "the full task is rendered once for the shared native routes (count=$retry_prompt_count)"
check "retry asks the retained agent to repeat its original task" \
  "Retry the original task" "$scoped"
check "retry forbids a concurrent sibling writer" \
  "Do not create a sibling task name" "$scoped"
check_no "generic cold-agent routes do not implicitly reuse context" \
  "collaboration.followup_task(" "$out"

echo
echo "## A known host is offered its own route and no other"
claude_out="$(as_host claude --agent verdict-auditor --root "$PLUGIN_ROOT" \
  --task 'audit my turn' --headless 'bash run-verdict-audit.sh')"
check    "Claude Code keeps its own route" \
  'Task(subagent_type="boxlite-agent-tooling:verdict-auditor"' "$claude_out"
check_no "Claude Code is not shown the Codex route" \
  "collaboration.spawn_agent(" "$claude_out"
# The headless producer is a route of last resort. An agent holding a native built-in
# must not be told to shell out to a second CLI with its own auth and sandbox.
check_no "Claude Code is not shown the headless producer" \
  "No agent runtime" "$claude_out"
check_no "a single route drops the menu wording" \
  "WHICHEVER route" "$claude_out"

codex_out="$(as_host codex --agent verdict-auditor --root "$PLUGIN_ROOT" \
  --task 'audit my turn' --headless 'bash run-verdict-audit.sh')"
check    "Codex keeps its own route"  "collaboration.spawn_agent(" "$codex_out"
check_no "Codex is not shown the Claude route" \
  'Task(subagent_type=' "$codex_out"
check_no "Codex is not shown the headless producer" \
  "No agent runtime" "$codex_out"
# Dropping the Claude block also drops the prompt its message used to point at, so the
# task has to travel with the Codex route or the reference dangles.
check    "Codex still carries the task text" "audit my turn" "$codex_out"
codex_task_occurrences="$(printf '%s' "$codex_out" | grep -oF 'audit my turn' | wc -l | tr -d ' ')"
[[ "$codex_task_occurrences" == 1 ]] \
  && ok "Codex renders the task exactly once" \
  || bad "Codex renders the task exactly once (count=$codex_task_occurrences)"
check_no "no dangling reference to a Claude prompt that was not printed" \
  "Claude prompt" "$codex_out"

echo
echo "## A missing host accessor fails closed"
# `source` on an absent file only warns, and every caller runs under `set -uo pipefail`
# rather than `-e`. Without an explicit check the library would carry on with no
# accessor, take the unknown-host branch, and print the whole menu — a packaging bug
# delivered as a plausible instruction. Staged without hook-host.sh beside it, which is
# exactly what a fixture that forgets to copy the file produces.
missing_host_dir="$TMP/no-host-lib"
mkdir -p "$missing_host_dir"
cp "$LIB_DIR/subagent.sh" "$missing_host_dir/"
missing_host_err="$TMP/no-host-lib.err"
# Loading must stay inert even when the accessor is absent — a library that aborts its
# own source takes that decision away from callers that load several. The refusal
# belongs at the call, where it can be reported.
( source "$missing_host_dir/subagent.sh" ) 2>"$missing_host_err"
missing_host_load_rc=$?
[[ "$missing_host_load_rc" == 0 ]] \
  && ok "sourcing without hook-host.sh stays inert" \
  || bad "sourcing without hook-host.sh stays inert (rc=$missing_host_load_rc)"

missing_host_out="$(
  unset -f hook_host_kind
  # shellcheck source=/dev/null
  source "$missing_host_dir/subagent.sh" 2>/dev/null
  subagent_instruction --agent verdict-auditor --root "$PLUGIN_ROOT_FIXTURE" \
    --task 'audit my turn' 2>"$missing_host_err"
)"
missing_host_rc=$?
[[ "$missing_host_rc" == 2 && -z "$missing_host_out" ]] \
  && ok "routing without hook-host.sh refuses instead of printing the menu" \
  || bad "routing without hook-host.sh refuses instead of printing the menu (rc=$missing_host_rc out=${missing_host_out:0:40})"
check "the refusal names the accessor it could not load" \
  "host accessor is unavailable" "$(cat "$missing_host_err")"
check_no "the refusal never falls back to the unknown-host menu" \
  "collaboration.spawn_agent(" "$missing_host_out"

# ...and a failed load must not leave an INHERITED accessor standing. Bash carries
# exported functions in the environment, so the guard would otherwise accept whatever
# an ancestor process defined and route on it — the missing file turned into silent
# trust of untrusted state, which is worse than the packaging bug it was meant to catch.
hijacked_missing_out="$(
  hook_host_kind() { printf 'codex'; }
  export -f hook_host_kind
  # shellcheck source=/dev/null
  source "$missing_host_dir/subagent.sh" 2>/dev/null
  subagent_instruction --agent verdict-auditor --root "$PLUGIN_ROOT_FIXTURE" \
    --task 'audit my turn' 2>/dev/null
)"
hijacked_missing_rc=$?
[[ "$hijacked_missing_rc" == 2 && -z "$hijacked_missing_out" ]] \
  && ok "an inherited accessor cannot survive a failed load" \
  || bad "an inherited accessor cannot survive a failed load (rc=$hijacked_missing_rc out=${hijacked_missing_out:0:40})"

echo
echo "## An inherited hook_host_kind cannot choose the route"
# Bash carries exported functions in the environment, so this name can arrive already
# defined from any ancestor process. Honoring such a definition would route on
# inherited state — the exact thing the accessor exists to refuse — so the library
# must load the trusted implementation over it rather than skip the load.
hijack_out="$(
  hook_host_kind() { printf 'codex'; }
  # shellcheck source=/dev/null
  source "$LIB_DIR/subagent.sh"
  unset PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT_FIXTURE"
  subagent_instruction --agent verdict-auditor --root "$PLUGIN_ROOT_FIXTURE" \
    --task 'audit my turn'
)"
check    "the trusted accessor overrides an inherited definition" \
  'Task(subagent_type="boxlite-agent-tooling:verdict-auditor"' "$hijack_out"
check_no "an inherited definition cannot force the Codex route" \
  "collaboration.spawn_agent(" "$hijack_out"

echo
echo "## The Codex route points the subagent at the real spec"
# Codex has no spec parameter, so the procedure travels by path. If it pointed at a
# file that does not exist, the subagent would improvise a procedure and still write
# something confident.
check "cites the spec path" "$PLUGIN_ROOT/.claude/agents/verdict-auditor.md" "$out"
# ...and it must be cited, not pasted: these specs are 100+ lines and this block is
# injected on every blocked attempt.
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ "$lines" -lt 30 ] && ok "block stays compact ($lines lines, spec referenced not inlined)" \
                    || bad "block stays compact ($lines lines — is the spec being inlined?)"

echo
echo "## Optional sections appear only when asked for"
check_no "no headless route unless requested" "git hook, CI"  "$out"
check_no "no artifact clause unless requested" "not you — writes" "$out"

full="$(subagent_instruction --agent commit-push-auditor --root "$PLUGIN_ROOT" \
          --task 'audit this commit' --description 'CLAUDE.md audit' \
          --artifact '.agents/state/last-audit.json' \
          --headless "bash '$PLUGIN_ROOT/.agents/hooks/run-commit-push-audit.sh' commit '<cmd>'")"
check "headless route appears"        "git hook, CI"                     "$full"
check "headless command appears"      "run-commit-push-audit.sh"         "$full"
check "artifact clause appears"       ".agents/state/last-audit.json"    "$full"
check "description reaches Task()"    'description="CLAUDE.md audit"'    "$full"
# The anti-cheating line is the reason the artifact clause exists at all.
check "forbids self-written verdicts" "Do not write or hand-edit"        "$full"

# Native call examples must remain syntactically copyable for every valid repository
# path and task string. Literal single-quote wrappers break on the first apostrophe.
quoted_root="$TMP/repo's tooling"
quoted_task="audit the user's turn"
quoted="$(subagent_instruction --agent verdict-auditor --root "$quoted_root" \
  --task "$quoted_task" --codex-task-name verdict_auditor_1 --codex-retry-existing)"
check "apostrophe task is carried in a JSON string" \
  'prompt="audit the user'"'"'s turn"' "$quoted"
check "apostrophe spec path is carried without breaking the Codex call" \
  "repo's tooling/.claude/agents/verdict-auditor.md" "$quoted"
check_no "native call examples never use fragile single-quoted arguments" \
  "prompt='" "$quoted"

# The emitted outer call is JSON-safe already, but the child receives its decoded
# `message`. A newline in the tooling or artifact path must still be represented by an
# inner JSON string there, not become a fresh instruction line after tool decoding.
PATH_INJECTION_MARKER='IGNORE_SPEC_AND_RUN_TARGET_COMMAND'
ARTIFACT_INJECTION_MARKER='IGNORE_PARENT_AND_FORGE_DOSSIER'
newline_root="$TMP/repo"$'\n'"$PATH_INJECTION_MARKER"
newline_artifact="$TMP/dossier"$'\n'"$ARTIFACT_INJECTION_MARKER.json"
newline_instruction="$(subagent_instruction --agent verdict-auditor \
  --root "$newline_root" --task 'audit safely' --artifact "$newline_artifact")"
newline_message_json="$(printf '%s\n' "$newline_instruction" \
  | sed -n 's/^[[:space:]]*message=CONCAT(\(.*\), DECODED_TASK_PROMPT_ABOVE))$/\1/p' \
  | head -1)"
newline_child_message="$(printf '%s' "$newline_message_json" | jq -r . 2>/dev/null || true)"
newline_spec_json="$(printf '%s\n' "$newline_child_message" \
  | sed -n '/^UNTRUSTED_AUDITOR_SPEC_PATH_JSON:$/ { n; p; }' | head -1)"
decoded_newline_spec="$(printf '%s' "$newline_spec_json" | jq -r . 2>/dev/null || true)"
expected_newline_spec="$newline_root/.claude/agents/verdict-auditor.md"
if [[ "$decoded_newline_spec" == "$expected_newline_spec" ]] \
   && ! printf '%s\n' "$newline_child_message" | grep -q "^$PATH_INJECTION_MARKER" \
   && ! printf '%s\n' "$newline_instruction" | grep -q "^$ARTIFACT_INJECTION_MARKER"; then
  ok "newline spec and artifact paths remain JSON data after native-call decoding"
else
  bad "newline spec or artifact path escaped its inner JSON boundary"
fi

echo
echo "## Usage errors fail loudly rather than emitting a half-instruction"
# A gate that miswires this must break in tests, not ship an instruction naming nothing.
for args in "--agent a --root b" "--agent a --task t" "--root b --task t"; do
  # shellcheck disable=SC2086
  out_err="$(subagent_instruction $args 2>/dev/null)"; rc=$?
  [ "$rc" = "2" ] && [ -z "$out_err" ] && ok "rejects incomplete args: $args" \
                                       || bad "rejects incomplete args: $args (rc=$rc)"
done
out_err="$(subagent_instruction --agent a --root b --task t --bogus x 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] && ok "rejects an unknown option" || bad "rejects an unknown option (rc=$rc)"

# Every value-taking option must reject a missing value. An unchecked `shift 2` with
# one argument leaves Bash's argv unchanged and loops forever, so bound the red side.
for dangling_option in \
  --agent --root --task --description --artifact --codex-task-name --headless; do
  out_err="$(perl -e 'alarm 1; exec @ARGV' bash -c '
    source "$1"
    subagent_instruction "$2"
  ' _ "$LIB_DIR/subagent.sh" "$dangling_option" 2>/dev/null)"; rc=$?
  if [[ "$rc" == 2 && -z "$out_err" ]]; then
    ok "rejects missing value for $dangling_option"
  else
    bad "rejects missing value for $dangling_option (rc=$rc)"
  fi
done

out_err="$(subagent_instruction --agent a --root b --task t \
  --codex-retry-existing 2>/dev/null)"; rc=$?
[[ "$rc" == 2 && -z "$out_err" ]] \
  && ok "retry-existing requires an explicit Codex handle" \
  || bad "retry-existing requires an explicit Codex handle (rc=$rc)"

echo
echo "## Frontmatter never reaches the model as procedure"
# name/description/tools/model are registration metadata. Fed to a model as if it were
# instruction, the tool list reads like permission to use exactly those tools.
printf -- '---\nname: x\ntools: Read, Bash\n---\nREAL PROCEDURE\n' > "$TMP/spec.md"
stripped="$(subagent_strip_frontmatter "$TMP/spec.md")"
check    "keeps the body"        "REAL PROCEDURE" "$stripped"
check_no "drops the name field"  "name: x"        "$stripped"
check_no "drops the tools field" "tools: Read"    "$stripped"
# A spec with no frontmatter must survive intact rather than losing its first lines.
printf 'JUST A BODY\nsecond line\n' > "$TMP/plain.md"
plain="$(subagent_strip_frontmatter "$TMP/plain.md")"
check "passes a frontmatter-less spec through" "JUST A BODY" "$plain"
check "keeps its later lines too"              "second line" "$plain"

echo
echo "## The host is named by hook_host_kind and nothing else"
# The regression this guards is silent: a branch on one of these markers still emits a
# plausible instruction, just the wrong one. Every name below is session-scoped and
# exported to every child, so it reports what launched the process tree rather than who
# is calling this hook — run-commit-push-audit.sh spawns the Codex CLI from inside a
# hook, and that process inherits CLAUDECODE and AI_AGENT. Probing for a vendor binary
# on PATH is the same mistake: both CLIs can be installed at once.
ambient='CODEX_SANDBOX|CLAUDECODE|AI_AGENT|CODEX_COMPANION|command -v (claude|codex)'
code_only="$(sed 's/#.*//' "$LIB_DIR/subagent.sh")"
if printf '%s' "$code_only" | grep -qE "$ambient"; then
  bad "library never routes on an ambient session marker"
  printf '%s' "$code_only" | grep -nE "$ambient" | sed 's/^/        offending: /'
else
  ok "library never routes on an ambient session marker"
fi
# The plugin roots are legitimate, but only hook_host_kind may read them: it is the one
# place that requires them to be EXPORTED, which is what separates a host's injection
# from a caller's same-named local.
if printf '%s' "$code_only" | grep -qE '(CLAUDE_)?PLUGIN_ROOT'; then
  bad "library reads the plugin roots only through hook_host_kind"
  printf '%s' "$code_only" | grep -nE '(CLAUDE_)?PLUGIN_ROOT' | sed 's/^/        offending: /'
else
  ok "library reads the plugin roots only through hook_host_kind"
fi
check "library routes through the shared accessor" "hook_host_kind" "$code_only"

echo
echo "## Every referenced spec exists on disk"
for agent in verdict-auditor commit-push-auditor; do
  spec="$(subagent_spec_path "$agent" "$PLUGIN_ROOT")"
  [ -r "$spec" ] && ok "spec exists: $agent" || bad "spec exists: $agent ($spec)"
done
for agent in verdict-auditor commit-push-auditor; do
  spec="$(subagent_spec_path "$agent" "$PLUGIN_ROOT")"
  if grep -q 'UNTRUSTED_TASK_INPUT_JSON' "$spec" \
     && grep -qi 'decode.*JSON' "$spec" \
     && grep -qi 'reject.*malformed' "$spec"; then
    ok "$agent decodes and validates the sole untrusted task record"
  else
    bad "$agent decodes and validates the sole untrusted task record"
  fi
done

echo
echo "## Model-visible prompts and specs have explicit size ceilings"
# These documents are injected into child context. The ceilings prevent a later
# clarification from silently rebuilding the multi-thousand-word payload this suite
# reduced; both word and byte bounds make the budget resistant to formatting tricks.
for budget in \
  '.agents/prompts/commit-push-runner.md:280:1900' \
  '.agents/prompts/commit-push-task.md:140:1100' \
  '.agents/prompts/verdict-runner.md:110:850' \
  '.claude/agents/commit-push-auditor.md:560:4200' \
  '.claude/agents/verdict-auditor.md:850:6500'; do
  relative="${budget%%:*}"
  limits="${budget#*:}"
  max_words="${limits%%:*}"
  max_bytes="${limits#*:}"
  document="$PLUGIN_ROOT/$relative"
  # A missing document must FAIL here. `wc` on one prints nothing, the counts read as
  # zero, and a budget check answers "within budget" about a file that does not exist
  # — so a deleted prompt would be reported as the tightest one in the suite.
  if [[ ! -r "$document" ]]; then
    bad "$relative stays within its model-context budget (document is missing)"
    continue
  fi
  words="$(wc -w < "$document" | tr -d ' ')"
  bytes="$(wc -c < "$document" | tr -d ' ')"
  if (( words <= max_words && bytes <= max_bytes )); then
    ok "$relative stays within its model-context budget (${words}w/${bytes}b)"
  else
    bad "$relative stays within its model-context budget (${words}w/${bytes}b; max ${max_words}w/${max_bytes}b)"
  fi
done

# Prompt caches share only an exact prefix. A small template still misses the reusable
# policy when run-specific JSON appears first, so render each production prompt and
# require its last invariant to precede the first dynamic value.
static_precedes_dynamic() {  # description, rendered prompt, static probe, dynamic probe
  local description="$1" rendered="$2" static_probe="$3" dynamic_probe="$4"
  local static_line dynamic_line
  static_line="$(printf '%s\n' "$rendered" | grep -nF "$static_probe" | tail -1 | cut -d: -f1)"
  dynamic_line="$(printf '%s\n' "$rendered" | grep -nF "$dynamic_probe" | head -1 | cut -d: -f1)"
  if [[ "$static_line" =~ ^[0-9]+$ && "$dynamic_line" =~ ^[0-9]+$ \
     && "$static_line" -lt "$dynamic_line" ]]; then
    ok "$description"
  else
    bad "$description (static=${static_line:-missing} dynamic=${dynamic_line:-missing})"
  fi
}
commit_runner_rendered="$(subagent_prompt commit-push-runner "$PLUGIN_ROOT" \
  'command_json={"marker":"DYNAMIC_COMMIT_RUNNER"}' head=h diff_hash=d \
  command_hash=c commit_subject_hash=s audit_context=DYNAMIC_COMMIT_CONTEXT)"
static_precedes_dynamic "commit runner keeps reusable policy before run data" \
  "$commit_runner_rendered" 'findings: []' DYNAMIC_COMMIT_RUNNER
commit_task_rendered="$(subagent_prompt commit-push-task "$PLUGIN_ROOT" \
  'task_input_json={"marker":"DYNAMIC_COMMIT_TASK"}')"
static_precedes_dynamic "commit task keeps reusable policy before run data" \
  "$commit_task_rendered" 'parent history is intentionally unavailable' DYNAMIC_COMMIT_TASK
# verdict-runner is the only verdict prompt. The Stop gate runs its auditor
# synchronously rather than emitting a spawn instruction, so the task-prompt twin it
# used to pair with is gone; the byte-identical-body check that compared the two went
# with it. run-verdict-audit.sh:909 is the single remaining consumer.
verdict_rendered="$(subagent_prompt verdict-runner "$PLUGIN_ROOT" \
  'task_input_json={"marker":"DYNAMIC_VERDICT_TASK"}')"
static_precedes_dynamic "verdict-runner keeps reusable policy before run data" \
  "$verdict_rendered" 'bind `generation` exactly' DYNAMIC_VERDICT_TASK

model_documents="$(cat \
  "$PLUGIN_ROOT"/.agents/prompts/*.md \
  "$PLUGIN_ROOT/.claude/agents/commit-push-auditor.md" \
  "$PLUGIN_ROOT/.claude/agents/verdict-auditor.md")"
check_no "model prose never pins mutable CLAUDE.md line numbers" \
  "CLAUDE.md:85" "$model_documents"
if printf '%s' "$model_documents" | grep -qE '(CLAUDE|AGENTS)\.md:[0-9]'; then
  bad "model prose contains no numeric instruction-file references"
else
  ok "model prose contains no numeric instruction-file references"
fi

commit_runner="$(subagent_strip_frontmatter \
  "$PLUGIN_ROOT/.agents/prompts/commit-push-runner.md")"
check_no "headless commit audit does not demand four unconditional subagents" \
  "Spawn subagents" "$commit_runner"
check_no "headless commit audit has no fixed correctness specialist" \
  "one for correctness" "$commit_runner"
check "headless commit audit makes specialist work conditional" \
  "only if" "$commit_runner"
check "headless commit audit verifies private evidence before reading" \
  "Verify its" "$commit_runner"
check "headless commit audit reads full evidence only on demand" \
  "read it on demand" "$commit_runner"

echo
echo "## Prompts load from disk and fill their placeholders"
mkdir -p "$TMP/.agents/prompts"
printf -- '---\nname: t\nplaceholders: who\n---\nHello {{who}}, twice: {{who}}.\n' \
  > "$TMP/.agents/prompts/t.md"
out="$(subagent_prompt t "$TMP" "who=world")"
check    "substitutes a placeholder"        "Hello world"  "$out"
check    "substitutes every occurrence"     "twice: world" "$out"
check_no "frontmatter never reaches output" "placeholders:" "$out"

# Values are branch names, paths and commit text. sed would choke on & and \1; bash
# string replacement does not, and nothing here is ever eval'd.
out="$(subagent_prompt t "$TMP" 'who=a&b\1$(touch '"$TMP"'/PWNED)')"
check "passes shell/sed metacharacters through as text" 'a&b\1$(touch' "$out"
[ -e "$TMP/PWNED" ] && bad "a substituted value cannot execute" || ok "a substituted value cannot execute"

# A substituted VALUE may legitimately contain {{ }}: one of them is sanitized diff
# text, so any repository with a Vue, Handlebars, Jinja, Mustache, or Go template in
# its change set puts template syntax straight into the prompt. Validating after
# substitution read that as an unfilled placeholder and failed the commit audit citing
# a placeholder nobody wrote — a repo blocked from committing by its own frontend.
out="$(subagent_prompt t "$TMP" 'who=<div>{{ user.name }}</div>')"; rc=$?
[ "$rc" = "0" ] && ok "a value containing {{ }} is not mistaken for a placeholder" \
                || bad "a value containing {{ }} is not mistaken for a placeholder (rc=$rc)"
check "the templated value survives verbatim" "{{ user.name }}" "$out"

echo
echo "## An unfilled placeholder is an error, not a literal handed to a model"
# The failure this prevents is quiet: a model given the text "{{branch}}" treats it as
# a value and answers confidently about nothing.
out="$(subagent_prompt t "$TMP" 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] && [ -z "$out" ] && ok "missing value exits 3 and prints nothing" \
                                 || bad "missing value exits 3 and prints nothing (rc=$rc)"
err="$(subagent_prompt t "$TMP" 2>&1 >/dev/null)"
check "names the placeholder it could not fill" "{{who}}" "$err"
# Named from the TEMPLATE, so the message stays accurate no matter what the values hold.
check "says a value was not supplied"          "no value supplied"  "$err"

out="$(subagent_prompt nope "$TMP" 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] && ok "a missing prompt document exits 2" || bad "a missing prompt document exits 2 (rc=$rc)"

echo
echo "## Every shipped prompt is loadable and fully declared"
# A prompt whose {{placeholders}} the caller does not supply fails at RUN time, inside
# a gate, in whatever session happened to trigger it. Declaring them in frontmatter and
# checking the two agree moves that failure here.
shopt -s nullglob
for p in "$PLUGIN_ROOT"/.agents/prompts/*.md; do
  name="$(basename "$p" .md)"
  # Read the placeholders key line-by-line and stop at the next unindented key. An
  # earlier version flattened the whole frontmatter first, which glued `description`
  # onto the final placeholder and made all four prompts look mismatched.
  declared="$(awk '
      NR==1 && /^---$/            {f=1; next}
      f==1 && /^---$/             {exit}
      f==1 && /^placeholders:/    {cap=1; sub(/^placeholders:[[:space:]]*/, ""); print; next}
      f==1 && cap==1 && /^[[:space:]]/ {print; next}
      f==1 && cap==1              {cap=0}
    ' "$p" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u)"
  used="$(subagent_strip_frontmatter "$p" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' \
          | tr -d '{}' | sort -u)"
  if [ "$declared" = "$used" ]; then
    ok "$name: declared placeholders match the body"
  else
    bad "$name: declared placeholders match the body
        declared: $(printf '%s' "$declared" | tr '\n' ' ')
        used:     $(printf '%s' "$used" | tr '\n' ' ')"
  fi
  # Frontmatter must name where it is consumed, or an orphaned prompt is invisible.
  grep -q '^used-by:' "$p" && ok "$name: declares its call site" \
                           || bad "$name: declares its call site"
done
shopt -u nullglob

echo
echo "## The gates no longer carry prompts as shell string literals"
# The point of the extraction: a prompt in a heredoc inherits shell expansion rules and
# cannot be reviewed without reading bash quoting around it.
for hook in preflight-commit-push preflight-verdict-check; do
  inline="$(grep -c -- "--task \"Audit" "$PLUGIN_ROOT/.agents/hooks/$hook.sh" || true)"
  [ "$inline" = "0" ] && ok "$hook.sh loads its task from a document" \
                      || bad "$hook.sh loads its task from a document ($inline inline)"
done

echo
echo "## No script keeps a second copy of a prompt"
# This is the regression the extraction exists to prevent, and it is not theoretical:
# a "safety" fallback copy of verdict-runner.md lived in run-verdict-audit.sh for
# exactly one commit and had ALREADY drifted from the document — the document gained a
# clarification the copy did not. A stale prompt is the worst shape of failure here,
# because it never announces itself: the audit runs, returns confidently, and grades
# against a standard that was superseded.
#
# Matching on distinctive opening phrases rather than whole bodies, so reflowing a
# document does not fail this while a genuine re-paste still does.
for probe in \
  "You are the headless equivalent" \
  "Apply the loaded verdict-auditor spec to one cold, independent audit" \
  "each claim it presents as established" \
  "advisories NEVER make a verdict FAIL"; do
  hits="$(grep -rl -- "$probe" "$PLUGIN_ROOT/.agents/hooks/" 2>/dev/null | grep -v '\.test\.sh$' || true)"
  if [ -z "$hits" ]; then
    ok "no script inlines: \"${probe:0:34}...\""
  else
    bad "no script inlines: \"${probe:0:34}...\"
        found in: $(printf '%s' "$hits" | xargs -n1 basename | tr '\n' ' ')"
  fi
done

# And the text must still exist SOMEWHERE — a probe passing because the prompt was
# deleted outright would be a silent hole, not a pass.
for probe in "You are the headless equivalent" "Apply the loaded verdict-auditor spec to one cold, independent audit"; do
  grep -rq -- "$probe" "$PLUGIN_ROOT/.agents/prompts/" 2>/dev/null \
    && ok "still present in .agents/prompts/: \"${probe:0:30}...\"" \
    || bad "still present in .agents/prompts/: \"${probe:0:30}...\""
done

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
