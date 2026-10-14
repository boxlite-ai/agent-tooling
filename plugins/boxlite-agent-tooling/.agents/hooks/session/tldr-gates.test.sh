#!/usr/bin/env bash
# Exercise the three public gates with the same untrusted Markdown.
# Usage: tldr-gates.test.sh [fast]. The full matrix takes minutes; `fast` keeps the
# library denial checks and the all-gates `missing` case, under a minute.
# shellcheck disable=SC2016 # Markdown backticks in expected feedback are literal.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/repo" "$scratch/bin"
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=test \
  -c user.email=test@example.invalid commit -qm fixture --allow-empty
export DOC_FIXTURE="$scratch/doc.json" CLAUDE_PROJECT_DIR="$scratch/repo"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$DOC_FIXTURE"
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" VERDICT_CLASSIFIER_CMD=false
cd "$scratch/repo"
pass=0 fail=0 mode="${1:-full}"
run_hook() { # host, event, script basename; stdin is the native hook payload
  local host="$1" manifest="$plugin/hooks/hooks.json" root=CLAUDE_PLUGIN_ROOT command
  if [[ "$host" == codex ]]; then
    manifest="$plugin/$(jq -r .hooks "$plugin/.codex-plugin/plugin.json")"
    root=PLUGIN_ROOT
  fi
  command="$(jq -er --arg event "$2" --arg script "/$3\"" '
    [.hooks[$event][] | . as $group | select(.matcher == null or ("Bash" | test($group.matcher))) |
      .hooks[] | select(.command | endswith($script)) | .command] |
    if length == 1 then .[0] else error("missing or duplicate hook") end' "$manifest")" || return 2
  env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
    "$root=$plugin" bash -c "$command"
}
check() { # label, text, expected allow|deny, optional reply/design expectation, denial text
  local label="$1" body="$2" expected="$3" reply_expected="${4:-$3}" reason="${5:-TL;DR}"
  local output actual gate active wanted host mentions
  [[ "$mode" != fast || "$label" == missing ]] || return 0
  for gate in github-claude github-codex github-codex-native design stop-claude stop-codex stop-transcript-claude stop-transcript-codex; do
    host=claude
    [[ "$gate" != *codex* ]] || host=codex
    # First Stop, repeated continuations, then the next turn's first Stop.
    for active in false true true false; do
      actual=allow
      wanted="$expected"
      case "$gate" in
        github-*)
          output="$(jq -nc --arg command "gh issue comment 1 --body '$body'" \
            --arg gate "$gate" '{hook_event_name:"PreToolUse",tool_name:"Bash",
              tool_input:{(if $gate == "github-codex-native" then "cmd" else "command" end):$command}}' \
            | run_hook "$host" PreToolUse preflight-pr-review.sh)"
          [[ "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$output")" != deny ]] || actual=deny ;;
        design)
          wanted="$reply_expected"
          jq -nc --arg body "$body" '{html_url:"https://github.com/example/repo/issues/1",body:$body}' > "$DOC_FIXTURE"
          output="$(bash "$plugin/scripts/design-doc.sh" bind https://github.com/example/repo/issues/1 2>&1)" || actual=deny ;;
        stop-*)
          wanted="$reply_expected"
          [[ "$active" != true ]] || wanted=allow
          jq -nc --arg body "$body" --arg host "$host" '
            if $host == "claude" then {type:"assistant",message:{content:[{type:"text",text:$body}]}}
            else {type:"response_item",payload:{type:"message",role:"assistant",phase:"final_answer",
              content:[{type:"output_text",text:$body}]}} end' > "$scratch/turn.jsonl"
          output="$(jq -nc --arg body "$body" --argjson active "$active" \
            --arg gate "$gate" --arg transcript "$scratch/turn.jsonl" \
            '{hook_event_name:"Stop",stop_hook_active:$active} +
             (if $gate | startswith("stop-transcript") then {transcript_path:$transcript} else {last_assistant_message:$body} end)' \
            | run_hook "$host" Stop stop-gate.sh)"
          [[ "$(jq -r '.decision // "allow"' <<<"$output")" != block ]] || actual=deny ;;
      esac
      # A rewrite fixes every denial here, so each names the skill exactly once:
      # in the denial itself, or in the reminder the GitHub gate appends.
      mentions="$(grep -o boxlite-writing <<<"$output" | wc -l | tr -d ' ')" || true
      if [[ "$actual" == "$wanted" && ( "$wanted" == allow ||
            ( "$output" == *"TL;DR"* && "$output" == *"$reason"* && "$mentions" == 1 ) ) ]]; then
        pass=$((pass+1))
      else
        printf 'FAIL %s %s active=%s: wanted %s, got %s: %s\n' "$label" "$gate" "$active" "$wanted" "$actual" "$output"
        fail=$((fail+1))
      fi
      [[ "$gate" == stop* ]] || break
    done
  done
}
check missing 'A concise answer.' deny deny 'TL;DR heading missing'
check visible_alert 'PR #141 needs review.' deny deny 'TL;DR heading missing'
check bold_label '**TL;DR:** A concise answer.' deny deny '`## TL;DR`, one short sentence'
check empty $'## TL;DR\n\n## Details\nA concise answer.' deny deny 'summary missing or invalid'
check symbol_start $'## TL;DR\n\n#120 is ready.' deny deny 'summary missing or invalid'
check fenced $'```markdown\n## TL;DR\nA concise answer.\n```' deny deny 'TL;DR heading missing'
check quoted $'> ## TL;DR\n> A concise answer.' deny deny 'TL;DR heading missing'
check commented $'<!--\n## TL;DR\nA concise answer.\n-->' deny deny 'TL;DR heading missing'
check indented $'    ## TL;DR\n    A concise answer.' deny deny 'TL;DR heading missing'
check mention 'Include a TL;DR section.' deny deny 'TL;DR heading missing'
check valid $'## TL;DR\n\nA concise answer.' allow
check details $'## TL;DR\n\nA concise answer.\n\n## Details\nSupporting evidence.' allow
check closing_hashes $'### TL;DR ###\n\nA concise answer.' allow
check trailing $'Details first.\n\n## TL;DR\n\nA concise answer.' allow deny 'TL;DR not first'
check words_39 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..39})" allow
check words_40 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..40})" deny deny 'has 40 words (limit 39)'
check paragraphs_40 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..20})"$'\n\n'"$(printf 'word %.0s' {1..20})" deny deny 'has 40 words (limit 39)'
check chinese_40 $'## TL;DR\n\n'"$(printf '字%.0s' {1..40})" deny deny 'has 40 words (limit 39)'
# Follow the denial literally: keep the summary, move supporting text under a peer heading.
details="$(printf 'word %.0s' {1..40})"
check explanation_counted $'## TL;DR\n\nRetry failed requests once.\n\n'"$details" deny deny 'has 44 words (limit 39)'
check corrected_explanation $'## TL;DR\n\nRetry failed requests once.\n\n## Details\n\n'"$details" allow
check nested_heading $'## TL;DR\n\nRetry failed requests once.\n\n### Details\n\n'"$details" \
  deny deny 'same-level heading like `## Details`'
check table_after $'## TL;DR\n\nA concise answer.\n\n| Gate | Result |\n|---|---|\n'"$(printf '| stop gate | denied the reply |\n%.0s' {1..10})" \
  deny deny 'keep one short sentence, then a same-level heading'

for host in claude codex; do
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"Earlier progress."}]}}' > "$scratch/turn.jsonl"
  output="$(jq -nc --arg transcript "$scratch/turn.jsonl" \
    '{hook_event_name:"Stop",last_assistant_message:"",transcript_path:$transcript}' \
    | run_hook "$host" Stop stop-gate.sh)"
  if [[ "$(jq -r '.decision // "allow"' <<<"$output")" != block ]]; then
    pass=$((pass+1))
  else
    printf 'FAIL %s: an explicitly empty reply replayed earlier text: %s\n' "$host" "$output"
    fail=$((fail+1))
  fi
done

facade_failure() { # label, expected diagnostic, Markdown, optional fault, skill hint yes|no
  local label="$1" reason="$2" body="$3" fault="${4:-}" hint_expected="${5:-no}" output status=0 hint=no
  output="$(
    # shellcheck source=../../lib/reply-summary.sh
    source "$plugin/.agents/lib/reply-summary.sh"
    # shellcheck source=../../lib/concise-writing.sh
    source "$plugin/.agents/lib/concise-writing.sh"
    # shellcheck disable=SC2329 # Inject counter and parser failures into the sourced validator.
    if [[ "$fault" == empty ]]; then reply_summary_word_counts() { return 0; }
    elif [[ "$fault" == failed ]]; then reply_summary_word_counts() { return 1; }
    elif [[ "$fault" == no_parser ]]; then PATH="$scratch/bin"; exec 2>/dev/null; fi
    concise_writing_check_summary "$body" first 39
  )" || status=$?
  [[ "$output" != *'; apply boxlite-writing' ]] || hint=yes
  # One short line per denial; only missing, misplaced, malformed, and overlong
  # TL;DR denials name the skill.
  if [[ "$status" == 1 && "$output" == *"$reason"* && "$output" != *$'\n'* \
        && "$hint" == "$hint_expected" ]] && (( ${#output} <= 130 )); then
    pass=$((pass+1))
  else
    printf 'FAIL %s: exit=%s hint=%s: %.300s\n' "$label" "$status" "$hint" "$output"; fail=$((fail+1))
  fi
}
facade_failure oversized 'text over 262144 characters; shorten it' "$(printf '%262145s' '')"
facade_failure empty_counter 'word counter failed' $'## TL;DR\n\nA concise answer.' empty
facade_failure failed_counter 'word counter failed' $'## TL;DR\n\nA concise answer.' failed
facade_failure missing_parser 'parser (perl) failed' $'## TL;DR\n\nA concise answer.' no_parser
facade_failure missing 'start with `## TL;DR`' 'A concise answer.' '' yes
facade_failure not_first 'TL;DR not first' $'Details first.\n\n## TL;DR\n\nA concise answer.' '' yes
facade_failure bad_summary 'summary missing or invalid' $'## TL;DR\n\n#120 is ready.' '' yes
facade_failure too_long 'has 44 words (limit 39)' $'## TL;DR\n\nRetry failed requests once.\n\n'"$details" '' yes
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
