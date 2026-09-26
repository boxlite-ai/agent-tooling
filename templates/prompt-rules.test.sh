#!/usr/bin/env bash
# Tests for the scoped prompt-rule wiring a consumer copies in to get the reply-shape
# and workflow reminders WITHOUT the audit, PR-review, or verdict gates:
#
#   templates/codex-hooks.json     -> $consumer/.codex/hooks.json        (whole file)
#   templates/claude-settings.json -> $consumer/.claude/settings.json    (merge "hooks")
#
# Neither reads the pinned checkout. The consumer commits its own copy of
# rule-recency.sh, which names a skill the host must discover separately. The hook
# must still emit that reference once it is no longer inside the
# plugin tree. If it ever grows a sibling dependency, a ${PLUGIN_ROOT}, or a relative
# source, every consumer copy breaks at once and nothing upstream notices — the copies
# are invisible from here.
#
# The rest guards the two JSON files. Both hosts validate strictly and reject an
# unknown key by loading no hooks at all. Codex does it WITHOUT LOGGING ANYTHING — that
# was confirmed the expensive way, when an early draft carried a `_comment` key
# explaining the file and the end-to-end runs came back with the injection missing and
# no indication why.
#
# The nested `hooks` array inside each event entry is REQUIRED, not decorative. It was
# double-checked against Anthropic's own installed security-guidance plugin and a
# working .claude/settings.json, because a plausible-looking flattened form
# (command objects directly in the event array) is the obvious wrong guess.
#
# Run with:  bash templates/prompt-rules.test.sh
# Exits non-zero on any failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_JSON="$REPO_ROOT/templates/codex-hooks.json"
CLAUDE_JSON="$REPO_ROOT/templates/claude-settings.json"
CANONICAL="$REPO_ROOT/plugins/boxlite-agent-tooling/.agents/hooks/rule-recency.sh"
README="$REPO_ROOT/README.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

echo "## The hook survives being copied out of the plugin tree"
# Copy it ALONE into an empty directory — no plugin tree, no sibling hooks, no repo.
# This is exactly the consumer's situation, and the only thing that makes this wiring
# viable. Run it from a directory unrelated to both, so a hidden cwd assumption shows up.
mkdir -p "$TMP/lonely" "$TMP/elsewhere"
cp "$CANONICAL" "$TMP/lonely/rule-recency.sh"
out="$( cd "$TMP/elsewhere" && printf '{"session_id":"iso","prompt":"explain the pull path"}' \
          | TMPDIR="$TMP" bash "$TMP/lonely/rule-recency.sh" 2>"$TMP/err" )"
case "$out" in
  *"boxlite-writing"*) ok "emits the skill name without reading its files" ;;
  *)                bad "emits the skill name without reading its files (got: ${out:0:60})" ;;
esac
[ -s "$TMP/err" ] && bad "runs silently on stderr (got: $(head -c 80 "$TMP/err"))" \
                  || ok "runs silently on stderr"

# Static counterpart to the behavioural check above. The run passes today; these are
# the specific ways a future edit would break every consumer copy while still passing
# the plugin's own suite, where the surrounding tree happens to exist.
code_only="$(sed 's/#.*//' "$CANONICAL")"
if printf '%s' "$code_only" | grep -qE 'PLUGIN_ROOT|\bsource\b|^\s*\.\s|/\.\./'; then
  bad "no dependency on the plugin tree"
  printf '%s' "$code_only" | grep -nE 'PLUGIN_ROOT|\bsource\b|^\s*\.\s|/\.\./' | sed 's/^/        offending: /'
else
  ok "no dependency on the plugin tree"
fi

# Shared shape checks. Both hosts use the same hooks schema; only the path expression
# differs, because only one of them defines $CLAUDE_PROJECT_DIR.
check_hooks_file() {  # check_hooks_file <label> <file> <expected-path-expression>
  local label="$1" file="$2" path_expr="$3"

  jq -e . "$file" >/dev/null 2>&1 && ok "$label: valid JSON" || bad "$label: valid JSON"

  # Every level, not just the top: an unknown key anywhere is the same silent rejection,
  # and a stray comment is as likely to land beside a command as above it. `env` is
  # allowed at the root because .claude/settings.json legitimately carries it.
  local unknown
  unknown="$(jq -r '
    [ (keys_unsorted[] | select(IN("hooks","env") | not)),
      (.hooks | keys_unsorted[] | select(test("^[A-Z]") | not)),
      (.hooks[][] | keys_unsorted[] | select(. != "hooks" and . != "matcher")),
      (.hooks[][].hooks[] | keys_unsorted[]
         | select(IN("type","command","statusMessage","timeout") | not))
    ] | join(",")' "$file" 2>/dev/null)"
  [ -z "$unknown" ] && ok "$label: no unknown keys at any depth" \
                    || bad "$label: no unknown keys at any depth (found: $unknown)"

  # The nested array is the part most likely to be "simplified" by someone who has read
  # a flattened example. Assert the command object is reachable at the real depth.
  local nested
  nested="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].type // "MISSING"' "$file")"
  [ "$nested" = "command" ] && ok "$label: command nested at .UserPromptSubmit[].hooks[]" \
                            || bad "$label: command nested at .UserPromptSubmit[].hooks[] (got: $nested)"

  # PascalCase is not cosmetic. Codex records hook trust under snake_case keys
  # (`user_prompt_submit`), which makes the wrong casing look plausible in config — but
  # the JSON event name must be PascalCase or the hook is silently never registered.
  local events
  events="$(jq -r '.hooks | keys_unsorted | join(",")' "$file")"
  [ "$events" = "UserPromptSubmit" ] && ok "$label: only UserPromptSubmit is wired" \
                                     || bad "$label: only UserPromptSubmit is wired (got: $events)"

  local cmd
  cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$file")"
  case "$cmd" in
    *".agent-tooling/$(basename "$CANONICAL")"*)
      ok "$label: targets .agent-tooling/$(basename "$CANONICAL")" ;;
    *)
      bad "$label: targets .agent-tooling/$(basename "$CANONICAL") (got: $cmd)" ;;
  esac
  case "$cmd" in
    *"$path_expr"*) ok "$label: resolves the repo root via $path_expr" ;;
    *)              bad "$label: resolves the repo root via $path_expr (got: $cmd)" ;;
  esac

  # The reason a consumer picks this file over installing the plugin. Quietly gaining a
  # commit/push audit or verdict gate here would surprise someone who opted into
  # reply-shape rules alone.
  local gates
  gates="$(jq -r '[.hooks[][].hooks[].command
                   | select(test("preflight-|commit-push|verdict|pr-watch"))] | length' "$file")"
  [ "$gates" = "0" ] && ok "$label: wires no audit/PR/verdict gate" \
                     || bad "$label: wires no audit/PR/verdict gate ($gates found)"
}

echo
echo "## Codex — templates/codex-hooks.json -> .codex/hooks.json"
# Codex defines no project-root variable, so the command substitutes git at run time.
# This matches the idiom already in use in the boxlite2 consumer.
check_hooks_file "codex" "$CODEX_JSON" '$(git rev-parse --show-toplevel)'

echo
echo "## Claude Code — templates/claude-settings.json -> .claude/settings.json"
# Claude Code exports $CLAUDE_PROJECT_DIR, so it needs no subprocess to find the root.
check_hooks_file "claude" "$CLAUDE_JSON" '$CLAUDE_PROJECT_DIR'

echo
echo "## The documented Claude merge preserves existing prompt hooks"
# Execute the README's copy/merge recipe itself. A structure-only assertion on the
# template cannot catch `jq` replacing an existing UserPromptSubmit array.
documented_merge="$(awk '
  /Claude Code needs a \*\*merge\*\*/ { found = 1 }
  found && /^```sh$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$README")"
MERGE_CONSUMER="$TMP/merge-consumer"
mkdir -p "$MERGE_CONSUMER/.claude"
jq -n '{
  env: {KEEP_ME: "yes"},
  hooks: {
    UserPromptSubmit: [{hooks:[{type:"command",command:"existing-prompt-hook"}]}],
    PreToolUse: [{matcher:"Bash",hooks:[{type:"command",command:"existing-pretool-hook"}]}]
  }
}' > "$MERGE_CONSUMER/.claude/settings.json"
(
  cd "$REPO_ROOT" || exit 1
  # shellcheck disable=SC2034 # consumed by the README snippet through eval
  consumer="$MERGE_CONSUMER"
  eval "$documented_merge"
) >/dev/null 2>"$TMP/documented-merge.err"
merge_status=$?
if [[ "$merge_status" -eq 0 ]]; then
  ok "documented merge executes"
else
  bad "documented merge executes (rc=$merge_status err=$(head -c 120 "$TMP/documented-merge.err"))"
fi
if jq -e '
    .env.KEEP_ME == "yes" and
    (.hooks.PreToolUse | length) == 1 and
    ([.hooks.UserPromptSubmit[]?.hooks[]?.command] | index("existing-prompt-hook")) != null and
    ([.hooks.UserPromptSubmit[]?.hooks[]?.command] | index("/usr/bin/env bash \"$CLAUDE_PROJECT_DIR/.agent-tooling/rule-recency.sh\"")) != null
  ' "$MERGE_CONSUMER/.claude/settings.json" >/dev/null 2>&1; then
  ok "documented merge retains existing events and appends the prompt rule"
else
  bad "documented merge retains existing events and appends the prompt rule"
fi

# Installation recipes are routinely rerun during refreshes. Replaying the exact
# documented merge must not register another model-visible prompt hook.
(
  cd "$REPO_ROOT" || exit 1
  # shellcheck disable=SC2034 # consumed by the README snippet through eval
  consumer="$MERGE_CONSUMER"
  eval "$documented_merge"
) >/dev/null 2>"$TMP/documented-merge-second.err"
second_merge_status=$?
if [[ "$second_merge_status" -eq 0 \
   && "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command
        | select(. == "/usr/bin/env bash \"$CLAUDE_PROJECT_DIR/.agent-tooling/rule-recency.sh\"")] | length' \
        "$MERGE_CONSUMER/.claude/settings.json")" == 1 \
   && "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command
        | select(. == "existing-prompt-hook")] | length' \
        "$MERGE_CONSUMER/.claude/settings.json")" == 1 \
   && "$(jq -r '.hooks.PreToolUse | length' \
        "$MERGE_CONSUMER/.claude/settings.json")" == 1 ]]; then
  ok "documented merge is idempotent across refreshes"
else
  bad "documented merge is idempotent across refreshes"
fi

echo
echo "## The two hosts stay aligned"
# They should differ in exactly one respect — how the repo root is named. Any other
# divergence means one host quietly got a rule the other did not, which is the whole
# failure mode this pair exists to prevent.
codex_norm="$(jq -S 'del(.hooks.UserPromptSubmit[].hooks[].command)' "$CODEX_JSON")"
claude_norm="$(jq -S 'del(.hooks.UserPromptSubmit[].hooks[].command)' "$CLAUDE_JSON")"
[ "$codex_norm" = "$claude_norm" ] && ok "identical apart from the command string" \
                                   || bad "identical apart from the command string"

# And the commands themselves must differ only in that prefix — same interpreter, same
# target file. Comparing with the two root expressions normalised away catches a drift
# such as one host pointing at a renamed or relocated script.
codex_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CODEX_JSON" \
              | sed 's/\$(git rev-parse --show-toplevel)/__ROOT__/')"
claude_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_JSON" \
              | sed 's/\$CLAUDE_PROJECT_DIR/__ROOT__/')"
[ "$codex_cmd" = "$claude_cmd" ] && ok "commands match once the root expression is normalised" \
                                 || bad "commands differ beyond the root expression
        codex:  $codex_cmd
        claude: $claude_cmd"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
