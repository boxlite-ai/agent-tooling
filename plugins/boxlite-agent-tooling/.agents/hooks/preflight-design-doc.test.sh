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
  check_input "$1" "$(jq -nc --arg command "$2" '{command:$command}')" "$3"
}
check_input() { # tool, tool_input JSON, wanted allow|deny
  local tool="$1" input="$2" want="$3" manifest hook output status denied payload
  payload="$(jq -nc --arg tool "$tool" --argjson input "$input" --arg cwd "$scratch/repo" \
    '{tool_name:$tool,cwd:$cwd,tool_input:$input}')"
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
      printf 'FAIL %s %s: expected %s, denied=%s: %s\n' "$manifest" "$tool" "$want" "$denied" "$input"; fail=$((fail+1))
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
# Scratch, memory and plan files live outside every repository and need no design doc.
outside="$scratch/outside"
mkdir "$outside"
ln -s "$scratch/repo" "$outside/repo-link"
ln -s "$scratch/repo/linked.py" "$outside/linked.py"
git init -q --bare "$scratch/bare.git"
path_input() { jq -nc --arg key "$1" --arg path "$2" '{($key):$path}'; }
patch_input() { jq -nc --arg patch "$1" '{command:$patch}'; }
check_input Write "$(path_input file_path "$outside/notes.md")" allow
check_input MultiEdit "$(path_input file_path "$outside/new/dir/notes.md")" allow
check_input NotebookEdit "$(path_input notebook_path "$outside/notes.ipynb")" allow
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Add File: '"$outside"$'/a.txt\n+a\n*** End Patch')" allow
# A target inside any repository, or one that cannot be resolved, keeps the gate.
check_input Write "$(path_input file_path "$scratch/repo/source.py")" deny
check_input Write "$(path_input file_path source.py)" deny
check_input Edit "$(path_input file_path "$outside/repo-link/source.py")" deny
check_input Write "$(path_input file_path "$outside/linked.py")" deny
check_input Write "$(path_input file_path "$outside/../repo/source.py")" deny
check_input Write "$(path_input file_path "$scratch/bare.git/hooks/pre-receive")" deny
check_input Write "$(path_input file_path "$outside/fresh/.git/config")" deny
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Add File: '"$outside"$'/a.txt\n+a\n*** Update File: source.py\n@@\n-a\n+b\n*** End Patch')" deny
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Add File: '"$outside"$'/b.txt\n+b\n*** Delete File: source.py\n*** End Patch')" deny
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Update File: '"$outside"$'/a.txt\n*** Move to: source.py\n@@\n-a\n+b\n*** End Patch')" deny
# Without --, perl would take -w as a switch and the target as the working directory.
mkdir "$scratch/repo/-w"
check_input Write "$(jq -nc --arg path "$scratch/repo/source.py" '{workdir:"-w",file_path:$path}')" deny
# A newline or NUL in a path would be dropped or split before the check sees it.
ln -s "$scratch/repo/newline.py" "$outside/x"$'\n'
check_input Write "$(path_input file_path "$outside/x"$'\n')" deny
check_input Write "$(jq -nc --arg path "$outside/x" '{file_path:($path + "\u0000y")}')" deny
# Hosts resolve .. by text, so repo/out-link/../notes.md lands inside the repository even
# though the kernel resolves it outside. Relative working directories keep the gate too.
ln -s "$outside" "$scratch/repo/out-link"
check_input Write "$(path_input file_path "$scratch/repo/out-link/../notes.md")" deny
check_input Write '{"workdir":"out-link","file_path":"notes.md"}' deny
# A dangling last link is judged by its target; a dangling directory link or a loop keeps the gate.
ln -s "$outside/missing.txt" "$outside/dangling.txt"
ln -s "$outside/missing-dir" "$outside/dangling-dir"
ln -s "$outside/loop-b" "$outside/loop-a"
ln -s "$outside/loop-a" "$outside/loop-b"
check_input Write "$(path_input file_path "$outside/dangling.txt")" allow
check_input Write "$(path_input file_path "$outside/dangling-dir/a.txt")" deny
check_input Write "$(path_input file_path "$outside/loop-a")" deny
# Deleting or moving a repository link changes the link itself, wherever it points.
ln -s "$outside/notes.md" "$scratch/repo/out-file"
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Delete File: '"$scratch"$'/repo/out-file\n*** End Patch')" deny
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Update File: '"$scratch"$'/repo/out-file\n*** Move to: '"$outside"$'/moved.md\n@@\n-a\n+b\n*** End Patch')" deny
check_input Write "$(path_input file_path "$scratch/repo/out-file")" deny
# A link into a repository subdirectory is judged by where it lands.
mkdir "$scratch/repo/src"
ln -s "$scratch/repo/src" "$outside/sub-link"
check_input Write "$(path_input file_path "$outside/sub-link/new.py")" deny
# Relative targets join their working directory; relative links resolve beside the link.
ln -s notes-target.md "$outside/rel-link"
check_input Write "$(jq -nc --arg dir "$outside" '{workdir:$dir,file_path:"notes.md"}')" allow
check_input Write "$(path_input file_path "$outside/rel-link")" allow
# A host may expand ~ itself, so a ~ path keeps the gate.
check_input Write "$(jq -nc --arg dir "$outside" '{workdir:$dir,file_path:"~/code/repo/a.py"}')" deny
# Codex trims patch lines, so an indented header still names a target.
check_input apply_patch "$(patch_input $'*** Begin Patch\n*** Add File: '"$outside"$'/c.txt\n+c\n  *** Update File: source.py\n@@\n-a\n+b\n*** End Patch')" deny
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
