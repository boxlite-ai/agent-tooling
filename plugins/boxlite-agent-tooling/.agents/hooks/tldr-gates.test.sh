#!/usr/bin/env bash
# Exercise the three public gates with the same untrusted Markdown.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
pass=0 fail=0
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
check() { # label, text, expected allow|deny, optional reply/design expectation
  local label="$1" body="$2" expected="$3" reply_expected="${4:-$3}" output actual gate active wanted host
  for gate in github-claude github-codex github-codex-native design stop-claude stop-codex stop-transcript-claude stop-transcript-codex; do
    host=claude
    [[ "$gate" != *codex* ]] || host=codex
    for active in false true; do
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
      if [[ "$actual" == "$wanted" && ( "$wanted" == allow || "$output" == *"TL;DR"* ) ]]; then
        pass=$((pass+1))
      else
        printf 'FAIL %s %s active=%s: wanted %s, got %s: %s\n' "$label" "$gate" "$active" "$wanted" "$actual" "$output"
        fail=$((fail+1))
      fi
      [[ "$gate" == stop* ]] || break
    done
  done
}
check missing 'A concise answer.' deny
check empty $'## TL;DR\n\n## Details\nA concise answer.' deny
check fenced $'```markdown\n## TL;DR\nA concise answer.\n```' deny
check quoted $'> ## TL;DR\n> A concise answer.' deny
check commented $'<!--\n## TL;DR\nA concise answer.\n-->' deny
check indented $'    ## TL;DR\n    A concise answer.' deny
check mention 'Include a TL;DR section.' deny
check valid $'## TL;DR\n\nA concise answer.' allow
check details $'## TL;DR\n\nA concise answer.\n\n## Details\nSupporting evidence.' allow
check closing_hashes $'### TL;DR ###\n\nA concise answer.' allow
check trailing $'Details first.\n\n## TL;DR\n\nA concise answer.' allow deny
check words_39 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..39})" allow
check words_40 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..40})" allow deny
check paragraphs_40 $'## TL;DR\n\n'"$(printf 'word %.0s' {1..20})"$'\n\n'"$(printf 'word %.0s' {1..20})" allow deny
check chinese_40 $'## TL;DR\n\n'"$(printf '字%.0s' {1..40})" allow deny
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
