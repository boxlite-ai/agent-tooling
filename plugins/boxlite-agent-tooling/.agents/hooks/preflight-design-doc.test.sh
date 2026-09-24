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
      printf 'FAIL %s %s: expected %s, denied=%s: %s\n' "$manifest" "$tool" "$want" "$denied" "$command"; fail=$((fail+1))
    fi
  done
}
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' deny
done
check Read README.md allow
check Bash "gcloud logging read 'severity>=ERROR' --limit=20" allow
check Bash 'kubectl logs deployment/example --tail=20 | tail -n 10' allow
check Bash 'git status --short && rg -n "error|warn" src' allow
check Bash './scripts/investigate-state.sh' allow
# Shell writes are deliberately outside the pre-edit design gate, too.
check Bash 'python3 -c "open(\"code.py\",\"w\").write(\"code\")"' allow
check Bash 'printf code > source.py' allow
if [[ "${1:-}" == --reproducer ]]; then
  printf '%d passed, %d failed\n' "$pass" "$fail"
  [[ "$fail" == 0 ]]; exit $?
fi
for manifest in hooks.json codex-hooks.json; do
  for script in preflight-commit-push.sh preflight-pr-review.sh; do
    if jq -e --arg script "$script" '[.hooks.PreToolUse[] |
        select(.matcher as $matcher | "Bash" | test($matcher)) | .hooks[].command |
        select(contains($script))] | length == 1' "$plugin/hooks/$manifest" >/dev/null; then
      printf 'PASS %s retains Bash %s\n' "$manifest" "$script"; pass=$((pass+1))
    else
      printf 'FAIL %s missing Bash %s\n' "$manifest" "$script"; fail=$((fail+1))
    fi
  done
done
# A missing document must still block PR publication through its own Bash hook.
check Bash $'gh pr create --draft --title "fix: example" --body "## TL;DR\n\nA concise description."' deny
check Bash "bash \"$plugin/scripts/design-doc.sh\" bind https://github.com/example/project/issues/1" allow
check Bash "bash \"$plugin/scripts/design-doc.sh\" check" allow
url=https://github.com/example/project/issues/1
jq -nc --arg url "$url" '{html_url:$url,body:"## TL;DR\n\nVerify designs before edits.\n\nProblem: undocumented edits. Approach: verify a design doc. Validation: gate tests."}' > "$DOC_RESPONSE"
(cd "$scratch/repo" && bash "$plugin/scripts/design-doc.sh" bind "$url") >/dev/null || exit 1
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' allow
done
export DOC_ERROR=1
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' deny
done
check Bash './scripts/investigate-state.sh' allow
export DOC_ERROR=0
git -C "$scratch/repo" checkout -qb different
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' deny
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
