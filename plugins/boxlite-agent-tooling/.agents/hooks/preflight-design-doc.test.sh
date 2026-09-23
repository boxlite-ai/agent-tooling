#!/usr/bin/env bash
# Replay host PreToolUse dispatch so missing manifest wiring is a real failure.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/repo" "$scratch/bin"
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=test \
  -c user.email=test@example.invalid commit -qm initial --allow-empty
export DOC_RESPONSE="$scratch/doc.json"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${DOC_ERROR:-0}" == 0 ]] || exit 1
cat "$DOC_RESPONSE"
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" PLUGIN_ROOT="$plugin" CLAUDE_PROJECT_DIR="$scratch/repo"
unset GIT_DIR GIT_WORK_TREE GH_HOST GH_REPO
pass=0 fail=0
check() { # tool, command, wanted allow|deny
  local tool="$1" command="$2" want="$3" manifest hook output status denied payload
  payload="$(jq -nc --arg tool "$tool" --arg command "$command" --arg cwd "$scratch/repo" \
    '{tool_name:$tool,cwd:$cwd,tool_input:{command:$command}}')"
  for manifest in hooks.json codex-hooks.json; do
    denied=false
    while IFS= read -r hook; do
      status=0
      output="$(cd "$scratch/repo" && printf '%s' "$payload" | bash -c "$hook" 2>"$scratch/err")" || status=$?
      if [[ "$status" == 2 ]] || jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null 2>&1; then
        denied=true
      elif [[ "$status" != 0 ]]; then
        printf 'FAIL hook infrastructure: %s\n' "$hook"; fail=$((fail+1))
      fi
    done < <(jq -r --arg tool "$tool" '.hooks.PreToolUse[] |
      select(.matcher as $matcher | $tool | test($matcher)) | .hooks[].command' "$plugin/hooks/$manifest")
    if [[ "$want:$denied" == deny:true || "$want:$denied" == allow:false ]]; then
      printf 'PASS %s %s %s\n' "$manifest" "$tool" "$want"; pass=$((pass+1))
    else
      printf 'FAIL %s %s: expected %s, denied=%s\n' "$manifest" "$tool" "$want" "$denied"; fail=$((fail+1))
    fi
  done
}
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' deny
done
check Bash 'python3 -c "open(\"code.py\",\"w\").write(\"code\")"' deny
check Bash 'printf code > source.py' deny
if [[ "${1:-}" == --reproducer ]]; then
  printf '%d passed, %d failed\n' "$pass" "$fail"
  [[ "$fail" == 0 ]]; exit $?
fi
check Bash 'git status --short' allow
check Bash 'rg --files' allow
check Bash 'rg -n design README.md' allow
check Bash "rg -n 'des.*gn' README.md" allow
for glob in '*' '*/*' '?' '[ab]' '^safe' 'safe#' 'safe~ignored'; do
  check Bash "rg -n example $glob ." deny
done
check Bash 'ls' allow
check Bash 'git --no-pager log --oneline -n 10' allow
check Bash 'cat README.md' allow
check Bash "gh issue create --title 'design: gate edits' --body 'Problem: missing design. Approach: verify before edits. Validation: hook tests.'" allow
check Bash "gh issue create --title 'design: gate edits' --body 'Design' --editor" deny
check Bash "gh issue create --title 'design: gate edits' --body 'Design'; touch source.py" deny
check Bash 'gh issue view 84 --repo boxlite-ai/agent-tooling' allow
check Bash 'cat README.md; touch source.py' deny
check Bash 'rg --pre=./writer.py pattern' deny
check Bash 'git diff --ext-diff' deny
# shellcheck disable=SC2016 # The tool receives literal shell substitution to reject.
check Bash 'cat $(touch source.py)' deny
check Bash $'cat README.md\ntouch source.py' deny
check Bash 'bash /tmp/design-doc.sh bind https://github.com/example/project/issues/1' deny
check Bash "bash \"$plugin/scripts/design-doc.sh\" bind https://github.com/example/project/issues/1" allow
check Bash "bash \"$plugin/scripts/design-doc.sh\" check" allow
url=https://github.com/example/project/issues/1
jq -nc --arg url "$url" '{html_url:$url,body:"Problem: undocumented edits. Approach: verify a design doc. Validation: gate tests."}' > "$DOC_RESPONSE"
(cd "$scratch/repo" && bash "$plugin/scripts/design-doc.sh" bind "$url") >/dev/null || exit 1
check Write 'edit source' allow
check apply_patch 'edit source' allow
check Bash 'python3 -c "print(1)"' allow
export DOC_ERROR=1
check Edit 'edit source' deny
check Bash 'git status --short' allow
export DOC_ERROR=0
git -C "$scratch/repo" checkout -qb different
check apply_patch 'edit source' deny
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
