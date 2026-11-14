#!/usr/bin/env bash
# Replay host PreToolUse dispatch so missing manifest wiring is a real failure.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# shellcheck source=../design/fixtures/worker-fixture.sh
source "$plugin/tests/design/fixtures/worker-fixture.sh"
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
check Bash "bash \"$plugin/scripts/design-doc.sh\" register https://github.com/example/project/issues/1" allow
check Bash "bash \"$plugin/scripts/design-doc.sh\" check" allow
url=https://github.com/example/project/issues/1
design=$'## TL;DR\n\nVerify designs before edits.\n\nProblem: undocumented edits. Approach: verify a design doc. Validation: gate tests.'
publish() { jq -nc --arg url "$url" --arg body "$1" '{html_url:$url,body:$body}' > "$DOC_RESPONSE"; }
publish "$design"
design_denial() { # host -> what the design gate tells the agent about an edit
  local root=PLUGIN_ROOT
  [[ "$1" == codex ]] || root=CLAUDE_PLUGIN_ROOT
  jq -nc --arg cwd "$scratch/repo" '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:"source.py"}}' |
    (cd "$scratch/repo" && { env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT "$root=$plugin" \
      bash "$plugin/.agents/hooks/preflight-design-doc.sh" >/dev/null; } 2>&1)
}
expect_denial() { # description, host, expected text
  local denial
  denial="$(design_denial "$2")"
  if [[ "$denial" == *"$3"* ]]; then
    printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else
    printf 'FAIL %s: %s\n' "$1" "$denial"; fail=$((fail+1))
  fi
}
for host in claude codex; do
  expect_denial "$host prints the register command" "$host" \
    "bash \"$plugin/scripts/design-doc.sh\" register <GitHub-issue/Notion/Linear-URL>"
done
(cd "$scratch/repo" && bash "$plugin/scripts/design-doc.sh" register "$url") >/dev/null || exit 1
# A bound design still needs a research verdict for its exact content before any edit.
record_research() { # PASS|FAIL, findings JSON
  jq -nc --arg sha "$(printf '%s' "$design" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" \
    --arg verdict "$1" --argjson findings "$2" '{content_sha256:$sha,verdict:$verdict,findings:$findings}' |
    (cd "$scratch/repo" && bash "$fixture_cli" verdict) >/dev/null ||
    { printf 'FAIL recording a research %s\n' "$1"; fail=$((fail+1)); }
}
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' deny
done
for host in claude codex; do
  expect_denial "$host requests only the fixed owned worker action" "$host" "scripts/design-doc.sh\" run"
done
record_research FAIL '["research: no source supports the retry limit; cite one"]'
check Write 'edit source' deny
# A recorded verdict waits for one fresh advisor run, before findings are shown (design #335).
expect_denial 'Claude Code requests its assigned advisor' claude 'assigned advisor'
expect_denial 'Codex requests its assigned advisor' codex 'assigned advisor'
said_task="$(cat "$fixture_bin/task.txt")"
[[ "$said_task" == *'request no account or key'* && "$said_task" == *'testable acceptance'* ]] || {
  printf 'FAIL owned auditor task retains privacy and whole-design rules\n'; fail=$((fail+1));
}
git_dir="$(git -C "$scratch/repo" rev-parse --absolute-git-dir)"
digest_of() { printf '%s' "$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'; }
advise() { # advice items JSON -> design-doc.sh advice for the live design
  jq -nc --arg sha "$(digest_of "$design")" --argjson advice "$1" '{content_sha256:$sha, advice:$advice}' |
    (cd "$scratch/repo" && bash "$fixture_cli" advice) >/dev/null 2>&1
}
equals() { # description, observed, wanted
  if [[ "$2" == "$3" ]]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s: got %s, wanted %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
rejects() { # description, raw advice input
  if (cd "$scratch/repo" && bash "$fixture_cli" advice <<<"$2") >/dev/null 2>&1; then
    printf 'FAIL advice rejects %s\n' "$1"; fail=$((fail+1))
  else
    printf 'PASS advice rejects %s\n' "$1"; pass=$((pass+1))
  fi
}
live="$(digest_of "$design")"
state_before="$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$git_dir/agent-tooling-design-audit.json")"
rejects 'a severity label' \
  "$(jq -nc --arg s "$live" '{content_sha256:$s, advice:["high: Scope: x. Why: finding 1. Try: y."]}')"
rejects 'more than five items' "$(jq -nc --arg s "$live" '{content_sha256:$s, advice:["a","b","c","d","e","f"]}')"
rejects 'extra keys' "$(jq -nc --arg s "$live" '{content_sha256:$s, advice:[], verdict:"PASS"}')"
rejects 'another design version' "$(jq -nc '{content_sha256:("0" * 64), advice:[]}')"
# The rejection names the item cap the advice task states (#335 A/B: items of 583-789 characters).
too_long="$(jq -nc --arg s "$live" --arg a "$(printf 'Scope: %0500d' 0)" '{content_sha256:$s, advice:[$a]}')"
rejects 'an item over 500 characters' "$too_long"
said="$(cd "$scratch/repo" && bash "$fixture_cli" advice <<<"$too_long" 2>&1 >/dev/null)"
equals 'the advice rejection names the 500-character cap' "$([[ "$said" == *'500 characters'* ]] && echo yes)" yes
# A Why quote that closes its own sentence still ends at Try:, so the replacement is not a design quote.
natural='TL;DR: keep it. Why: "Verify designs before edits." Try: "Audit every design first."'
advise "$(jq -nc --arg a "$natural" '[$a]')" || { printf 'FAIL recording a closed quote\n'; fail=$((fail+1)); }
equals 'a Why quote ending in ." keeps its Try out of the anchors' \
  "$(jq -c '.advice' "$git_dir/agent-tooling-design-advice.json")" "$(jq -nc --arg a "$natural" '[$a]')"
# Anchors (after CAPRA): an item whose quote, finding or file:line does not resolve is dropped.
kept_quote='TL;DR: keep it. Why: "Verify designs before edits.". Try: none.'
kept_finding='Problem: cite the retry source. Why: finding 1. Try: link the benchmark.'
advise "$(jq -nc --arg a "$kept_quote" --arg b "$kept_finding" '[$a,
  "Problem: x. Why: \"words the design never says\". Try: y.",
  "Scope: x. Why: finding 9. Try: y.", "Validation: x. Why: missing.sh:3. Try: y.", $b]')" \
  || { printf 'FAIL recording anchored advice\n'; fail=$((fail+1)); }
equals 'resolvable advice is kept and the rest dropped' \
  "$(jq -c '.advice' "$git_dir/agent-tooling-design-advice.json")" "$(jq -nc --arg a "$kept_quote" --arg b "$kept_finding" '[$a, $b]')"
equals 'advice never writes the verdict state' \
  "$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$git_dir/agent-tooling-design-audit.json")" "$state_before"
expect_denial 'a failed review lists its findings' codex 'no source supports the retry limit'
expect_denial 'a failed review lists its advice' codex 'cite the retry source'
publish "$design"
record_research PASS '[]'
check Write 'edit source' deny
expect_denial 'a PASS waits for advice too' claude 'assigned advisor'
advise '[]' || { printf 'FAIL recording empty advice\n'; fail=$((fail+1)); }
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' allow
done
publish "$design"$'\n\nA later decision.'
check Write 'edit source' deny
expect_denial 'an edited design needs a new review' codex 'scripts/design-doc.sh" run'
publish "$design"
check Write 'edit source' allow
# Stored advisories reach the parent with the advice route (design #335).
advised="$design"$'\n\nWith an advisory.'
publish "$advised"
jq -nc --arg sha "$(digest_of "$advised")" '{content_sha256:$sha, verdict:"PASS", findings:[],
  advisories:["low: search: log one more index. Evidence: probe. Pass if: logged"]}' |
  (cd "$scratch/repo" && bash "$fixture_cli" verdict) >/dev/null ||
  { printf 'FAIL recording a PASS with an advisory\n'; fail=$((fail+1)); }
expect_denial 'the advice route lists stored advisories' claude 'log one more index'
# The research loop through the hook (design #309).
cat > "$scratch/bin/date" <<'SH'
#!/usr/bin/env bash
if [[ -n "${DESIGN_TEST_CLOCK:-}" ]]; then cat "$DESIGN_TEST_CLOCK"; else exec /bin/date "$@"; fi
SH
chmod +x "$scratch/bin/date"
record_on() { # design text, findings JSON -> FAIL (PASS when empty) for that text
  jq -nc --arg sha "$(printf '%s' "$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" \
    --argjson findings "$2" '{content_sha256:$sha, verdict:(if $findings == [] then "PASS" else "FAIL" end),
      findings:$findings}' | (cd "$scratch/repo" && bash "$fixture_cli" verdict) >/dev/null ||
    { printf 'FAIL recording research for a revision\n'; fail=$((fail+1)); }
}
revision() { printf '%s\n\nRevision %s.' "$design" "$1"; }
said() { # description, output, expected text
  if [[ "$2" == *"$3"* ]]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s: %s\n' "$1" "$2"; fail=$((fail+1)); fi
}
typed() { # prompt text, session -> what the prompt hook's research helper reports
  jq -nc --arg prompt "$1" --arg session "${2:-}" '{prompt:$prompt} + if $session == "" then {} else {session_id:$session} end' |
    (cd "$scratch/repo" && CLAUDE_PROJECT_DIR="$scratch/repo" bash "$plugin/.agents/hooks/design-decision-prompt.sh")
}
two='["high: research: A","high: research: B"]'
publish "$(revision 1)"; record_on "$(revision 1)" "$two"
publish "$(revision 2)"
record_on "$(revision 2)" '["high: research: C"]'
if jq -e --argjson previous "$two" '.prior_findings==$previous and (has("advice")|not)' "$fixture_bin/task-input.json" >/dev/null; then
  printf 'PASS owned auditor receives prior findings without advice\n'; pass=$((pass+1))
else
  printf 'FAIL owned auditor receives prior findings without advice\n'; fail=$((fail+1))
fi
expect_denial 'a converging FAIL 2 asks for a reflection' codex "scripts/design-doc.sh\" reflect"
rm -f "$(git -C "$scratch/repo" rev-parse --absolute-git-dir)/agent-tooling-design-audit.json"
record_on "$(revision 2)" "$two"
publish "$(revision 3)"; record_on "$(revision 3)" "$two"
expect_denial 'repeated findings with no drop at FAIL 2 stop the loop' codex 'INCOMPLETE: the design-audit loop stopped after FAIL 2'
decision_state="$scratch/repo/.agents/state/design-decision-request.json"
decision_id="$(jq -er .id "$decision_state")"
expect_denial 'the stop names the typed decision line' codex "design-decision: $decision_id <Redesign|Reflect again|Overrule> <reason>"
said 'a bare choice records nothing' "$(typed "design-decision: $decision_id Overrule")" 'nothing recorded'
said 'another session cannot decide' "$(typed "design-decision: $decision_id Overrule fine" other-session)" 'session, branch, or HEAD'
check Write 'edit source' deny
said 'a typed first line records the choice' \
  "$(typed "$(printf 'design-decision: %s Overrule the gaps are acceptable\nthanks' "$decision_id")")" 'recorded "'
for tool in Write Edit MultiEdit NotebookEdit apply_patch; do
  check "$tool" 'edit source' allow
done
said 'the overrule is never PASS' "$(jq -r .verdict "$(git -C "$scratch/repo" rev-parse --absolute-git-dir)/agent-tooling-design-audit.json")" OVERRIDDEN
publish "$(revision 4)"; record_on "$(revision 4)" "$two"
publish "$(revision 5)"; record_on "$(revision 5)" "$two"
# Earlier requests used the real clock, so the test clock starts after it.
export DESIGN_TEST_CLOCK="$scratch/clock"
started=$(( $(/bin/date -u +%s) + 10 ))
printf '%s\n' "$started" > "$DESIGN_TEST_CLOCK"
expect_denial 'no drop in findings stops the loop' codex 'INCOMPLETE'
printf '%s\n' "$(( started + 301 ))" > "$DESIGN_TEST_CLOCK"
expect_denial 'an unanswered stop keeps edits blocked' codex 'edits stay blocked'
check Write 'edit source' deny
decision_id="$(jq -er .id "$decision_state")"
said 'a late typed line still counts' "$(typed "design-decision: $decision_id Redesign start from the findings")" 'recorded "'
expect_denial 'Redesign asks for a fresh draft' codex 'The human chose Redesign'
unset DESIGN_TEST_CLOCK
said 'the prompt hook routes typed decisions' "$(cat "$plugin/.agents/hooks/cancel-verdict-audit.sh")" 'design-decision-prompt.sh'
publish "$design"; record_on "$design" '[]'
advise '[]' || { printf 'FAIL recording fresh advice\n'; fail=$((fail+1)); }
check Write 'edit source' allow
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
