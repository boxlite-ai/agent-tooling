#!/usr/bin/env bash
# Design #563: after a successful push, the PostToolUse hook files one issue per unfiled
# ledger entry through scripts/gh-write.sh, and keeps unsafe or unanchored entries local.
# A stub gh records each call; nothing reaches the network.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
hook="$plugin/.agents/hooks/post-push-ledger-file.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unset AUDIT_LEDGER_FILING GH_HOST GH_REPO
mkdir -p "$scratch/bin"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  'issue list '*) [[ -n "${FAKE_EXISTING:-}" ]] && printf '%s\n' "$FAKE_EXISTING"; exit 0 ;;
  'issue create '*)
    [[ "${FAKE_CREATE_FAIL:-}" == 1 ]] && { printf 'HTTP 502\n' >&2; exit 1; }
    cat > "$GH_BODY"; printf 'https://github.com/example/repo/issues/%s\n' "$(grep -c 'issue create' "$GH_LOG")" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" GH_LOG="$scratch/gh.log" GH_BODY="$scratch/body.md"
pass=0 fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else
    printf 'FAIL: %s (got=%s expected=%s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}

new_repo() {  # name evidence [origin] -> repo whose ledger holds one forced commit entry
  local repo="$scratch/$1"
  git init -q -b feature "$repo"
  mkdir -p "$repo/src" "$repo/.agents/state"
  printf '.agents/state/\n' > "$repo/.gitignore"
  printf 'a\nb\nc\n' > "$repo/src/a.sh"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t.test -c core.hooksPath=/dev/null commit -qm base
  git -C "$repo" remote add origin "${3:-https://github.com/example/repo.git}"
  git -C "$repo" update-ref refs/remotes/origin/feature HEAD
  jq -nc --arg head "$(git -C "$repo" rev-parse HEAD)" --arg evidence "$2" '
    {gate:"commit",branch:"feature",head:$head,attempt_id:"a1b2c3d4e5f6",class:"stalled",
     findings:[{id:"F1",severity:"high",invariant:"i",behavior:"The retry loop in the gate keeps calling the auditor again and again after every failure without any bound on attempts, so the session never finishes its work today.",
                criterion:"Pass if retries stop.",evidence:$evidence}]}' \
    > "$repo/.agents/state/audit-ledger.jsonl"
  printf '%s' "$repo"
}
push() {  # host repo [exit-code] -> hook stdout
  : > "$GH_LOG"
  jq -nc --arg cwd "$2" --argjson code "${3:-0}" \
    '{hook_event_name:"PostToolUse",tool_input:{command:"git push"},cwd:$cwd,
      tool_response:{exit_code:$code,stdout:"",stderr:"To github.com:example/repo.git\n   1..2  feature -> feature"}}' \
    | ( cd "$2" && BOXLITE_HOOK_HOST="$1" bash "$hook" ) 2>/dev/null
}
context() { jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$1" 2>/dev/null; }
creates() { grep -c '^issue create' "$GH_LOG"; }
filed() { jq -sc '[.[] | select(.kind == "filed") | .url]' "$1/.agents/state/audit-ledger.jsonl"; }

for host in claude codex; do
  repo="$(new_repo "$host-ok" 'src/a.sh:2 loops')" tip="$(git -C "$scratch/$host-ok" rev-parse HEAD)"
  out="$(push "$host" "$repo")"
  check "$host: an eligible entry is filed once" "$(creates):$(filed "$repo")" \
    '1:["https://github.com/example/repo/issues/1"]'
  check "$host: the context names the issue" \
    "$(context "$out" | grep -c 'ledger: filed https://github.com/example/repo/issues/1 for commit@')" 1
  check "$host: the body links the anchor at the pushed commit and carries the marker" \
    "$(grep -c "blob/$tip/src/a.sh#L2" "$GH_BODY"):$(grep -c '<!-- boxlite-ledger:commit:a1b2c3d4e5f6 -->' "$GH_BODY")" '1:1'
  check "$host: the title names the gate, head, branch and attempt" \
    "$(grep -c "^issue create .*--title Unresolved audit findings: commit@${tip:0:7} on feature (a1b2c3d4)" "$GH_LOG")" 1
  out="$(push "$host" "$repo")"
  check "$host: a repeat push files nothing" "$(creates):$out" '0:'

  # Entries kept local must not use up the three-per-push budget for later entries.
  repo="$(new_repo "$host-queue" 'src/a.sh:2')"
  ledger="$repo/.agents/state/audit-ledger.jsonl"
  cp "$ledger" "$scratch/fileable"
  jq -c '.attempt_id = "local1" | .findings[0].evidence = "see missing/x.sh:1"' "$scratch/fileable" > "$ledger"
  for n in 2 3 4; do
    jq -c --arg id "local$n" '.attempt_id = $id | .findings[0].evidence = "see missing/x.sh:1"' "$scratch/fileable" >> "$ledger"
  done
  cat "$scratch/fileable" >> "$ledger"
  out="$(push "$host" "$repo")"
  check "$host: four unanchored entries ahead do not starve a fileable one" \
    "$(creates):$(context "$out" | grep -c 'no finding cites a path')" '1:4'

  # Five fileable entries: three issues on the first push, the remaining two on the next.
  repo="$(new_repo "$host-cap" 'src/a.sh:2')"
  ledger="$repo/.agents/state/audit-ledger.jsonl"
  cp "$ledger" "$scratch/one"
  for n in 2 3 4 5; do jq -c --arg id "cap$n" '.attempt_id = $id' "$scratch/one" >> "$ledger"; done
  out="$(push "$host" "$repo")"
  first="$(creates)"
  out="$(push "$host" "$repo")"
  check "$host: the cap files three per push and the rest on the next push" \
    "$first:$(creates):$(jq -s '[.[] | select(.kind == "filed")] | length' "$ledger")" '3:2:5'

  repo="$(new_repo "$host-found" 'src/a.sh:2')"
  out="$(FAKE_EXISTING=https://github.com/example/repo/issues/7 push "$host" "$repo")"
  check "$host: an existing titled issue is recorded, not recreated" \
    "$(creates):$(filed "$repo")" '0:["https://github.com/example/repo/issues/7"]'

  repo="$(new_repo "$host-email" 'src/a.sh:2 reported by dev@example.com')"
  out="$(push "$host" "$repo")"
  check "$host: an email keeps the entry local" \
    "$(creates):$(filed "$repo"):$(context "$out" | grep -c 'stays local: a finding names an email')" '0:[]:1'

  repo="$(new_repo "$host-tmp" 'src/a.sh:2 copy at /tmp/x/a.sh:2')"
  out="$(push "$host" "$repo")"
  check "$host: a temporary path keeps the entry local" "$(creates):$(filed "$repo")" '0:[]'

  repo="$(new_repo "$host-noanchor" 'see missing/file.sh:9')"
  out="$(push "$host" "$repo")"
  check "$host: no anchor in the pushed commit keeps the entry local" \
    "$(creates):$(context "$out" | grep -c 'no finding cites a path')" '0:1'

  repo="$(new_repo "$host-fail" 'src/a.sh:2')"
  out="$(FAKE_CREATE_FAIL=1 push "$host" "$repo")"
  check "$host: a failed create keeps the entry unfiled and says so" \
    "$(creates):$(filed "$repo"):$(context "$out" | grep -c 'filing failed')" '1:[]:1'

  repo="$(new_repo "$host-gitlab" 'src/a.sh:2' https://gitlab.com/example/repo.git)"
  out="$(push "$host" "$repo")"
  check "$host: a non-GitHub origin keeps findings local" \
    "$(wc -l < "$GH_LOG" | tr -d ' '):$(context "$out" | grep -c 'origin is not a github.com')" '0:1'

  repo="$(new_repo "$host-failedpush" 'src/a.sh:2')"
  out="$(push "$host" "$repo" 1)"
  check "$host: a failed push does nothing" "$(wc -l < "$GH_LOG" | tr -d ' '):$out" '0:'

  repo="$(new_repo "$host-dismissed" 'src/a.sh:2')"
  jq -nc --arg label "commit@$(git -C "$repo" rev-parse --short=7 HEAD):F1" \
    '{kind:"dismissal",branch:"feature",label:$label,reason:"accepted"}' >> "$repo/.agents/state/audit-ledger.jsonl"
  out="$(push "$host" "$repo")"
  check "$host: a dismissed finding is not filed" "$(wc -l < "$GH_LOG" | tr -d ' '):$out" '0:'

  repo="$(new_repo "$host-optout" 'src/a.sh:2')"
  out="$(AUDIT_LEDGER_FILING=0 push "$host" "$repo")"
  check "$host: the opt-out files nothing" "$(wc -l < "$GH_LOG" | tr -d ' '):$out" '0:'
done

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
