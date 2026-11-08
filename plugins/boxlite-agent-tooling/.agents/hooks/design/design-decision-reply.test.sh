#!/usr/bin/env bash
# Exercise question generation, real UserPromptSubmit dispatch, and edit re-entry.
# shellcheck disable=SC2016 # jq variables are expanded by jq, not Bash.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
export DESIGN_REPLY_CLOCK="$scratch/clock" DOC_RESPONSE="$scratch/doc.json"
printf '1000\n' > "$DESIGN_REPLY_CLOCK"
cat > "$scratch/bin/date" <<'SH'
#!/usr/bin/env bash
cat "$DESIGN_REPLY_CLOCK"
SH
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ -n "${DESIGN_REPLY_SWAP:-}" ]]; then
  count="$(cat "$DESIGN_REPLY_SWAP")"
  printf '%s\n' "$((count+1))" > "$DESIGN_REPLY_SWAP"
  if (( count > 0 )); then
    if (( count == 1 )) && [[ -n "${DESIGN_REPLY_HISTORY:-}" ]]; then
      cp "$DESIGN_REPLY_HISTORY" "$DESIGN_REPLY_AUDIT"
    fi
    cat "$DOC_CHANGED"; exit
  fi
fi
cat "$DOC_RESPONSE"
SH
chmod +x "$scratch/bin/date" "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" BOXLITE_HOOK_HOST=codex PLUGIN_ROOT="$plugin"
unset GIT_DIR GIT_WORK_TREE GH_HOST GH_REPO CLAUDE_PLUGIN_ROOT
cli="$plugin/scripts/design-doc.sh"
timed="$plugin/scripts/timed-user-prompt.sh"
url=https://github.com/example/project/issues/1
design=$'## TL;DR\n\nBind design decisions to their requests.\n\n## Approach\n\nValidate the question before applying a human choice.'
session='design-reply-session'
pass=0 fail=0 generation=0
check() {
  local label="$1"; shift
  if "$@"; then printf 'PASS %s\n' "$label"; pass=$((pass+1))
  else printf 'FAIL %s\n' "$label"; fail=$((fail+1)); fi
}
json() { jq -e "$@" >/dev/null; }
publish() { jq -nc --arg url "$url" --arg body "$1" '{html_url:$url,body:$body}' > "$DOC_RESPONSE"; }
record_fail() {
  jq -nc --arg digest "$(printf '%s' "$design" | shasum -a 256 | awk '{print $1}')" \
    '{content_sha256:$digest,verdict:"FAIL",findings:["high: scope: fixture finding"]}' \
    | (cd "$repo" && bash "$cli" verdict) >/dev/null
}
gate() {
  gate_status=0
  jq -nc --arg cwd "$repo" --arg session "$session" \
    '{tool_name:"Edit",cwd:$cwd,session_id:$session,tool_input:{file_path:"source.sh"}}' \
    | (cd "$repo" && bash "$plugin/.agents/hooks/preflight-design-doc.sh") \
      >"$scratch/gate-out" 2>"$scratch/gate-err" || gate_status=$?
  [[ "$gate_status" == 0 || "$gate_status" == 2 ]] || { cat "$scratch/gate-err"; exit 1; }
}
fresh() {
  generation=$((generation+1))
  repo="$scratch/repo-$generation"
  git init -q -b feature "$repo"
  git -C "$repo" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid \
    commit -qm fixture --allow-empty
  export CLAUDE_PROJECT_DIR="$repo"
  publish "$design"
  (cd "$repo" && bash "$cli" register "$url") >/dev/null
  record_fail; record_fail
  gate
  [[ "$gate_status" == 2 ]] && grep -q 'INCOMPLETE' "$scratch/gate-err" || exit 1
  state="$repo/.agents/state/design-decision-request.json"
  audit="$repo/.git/agent-tooling-design-audit.json"
  id="$(jq -r .id "$state")"
  answer="design-decision: $id Reflect again Recheck the remaining finding after reflection"
}
envelope() {
  printf '<send_user_message_question_reply>\n%s\n</send_user_message_question_reply>\n' \
    "$(jq -nc --arg question "$1" --arg answer "$2" \
      '[{questionItemId:"[\"request_user_input_async\",\"call_fixture\",0]",question:$question,answer:$answer}]')"
}
prompt() {
  jq -nc --arg prompt "$1" --arg session "${2:-$session}" --arg cwd "$repo" \
    '{hook_event_name:"UserPromptSubmit",session_id:$session,cwd:$cwd,prompt:$prompt}' \
    | (cd "$repo" && bash "$plugin/.agents/hooks/cancel-verdict-audit.sh") > "$scratch/reply"
}
unchanged() {
  local before
  before="$(cat "$state")"
  prompt "$2" "${3:-$session}"
  check "$1" test "$(cat "$state")" = "$before"
}
for timing in pending expired; do
  fresh
  if [[ "$timing" == expired ]]; then
    printf '%s\n' "$(( $(jq -r .deadline "$state") + 1 ))" > "$DESIGN_REPLY_CLOCK"
    bash "$timed" status "$state" "$id" >/dev/null
    bash "$timed" fallback "$state" "$id" >/dev/null
  fi
  prompt "$answer"
  check "$timing typed reply records the exact human directive" json --arg answer "$answer" \
    '.status=="accepted" and .response==$answer and (.fallback_delivered|not)' "$state"
  gate
  check "$timing Reflect again still denies edits" test "$gate_status" = 2
  check "$timing Reflect again reaches reflection" grep -q 'scripts/design-doc.sh" reflect' "$scratch/gate-err"
  check "$timing Reflect again grants one extra audit without PASS" json '.extra and .verdict=="FAIL"' "$audit"
  check "$timing decision is consumed once" json '.status=="consumed"' "$state"
done
if [[ "${1:-}" == --reproducer ]]; then
  printf '%d passed, %d failed\n' "$pass" "$fail"; [[ "$fail" == 0 ]]; exit
fi

fresh
for choice in Redesign 'Reflect again' Overrule; do
  check "text includes the bound $choice reply" grep -Fq "design-decision: $id $choice <reason>" "$scratch/gate-err"
done
check 'generated design question uses text' grep -Fq 'Ask once in plain text' "$scratch/gate-err"
valid="$answer"
unchanged 'wrong session cannot answer' "$valid" other-session
unchanged 'old asynchronous envelope cannot answer' "$(envelope 'Old question' "$valid")"
unchanged 'unbound typed choice cannot answer' 'design-decision: Overrule Accept this exact design'
unchanged 'another request ID cannot answer' "design-decision: 00000000000000000000000000000000 Overrule wrong request"
unchanged 'tool acceptance is not a human decision' '{"accepted":true}'
git -C "$repo" checkout -qb another
unchanged 'another branch cannot answer' "$valid"
git -C "$repo" checkout -q feature
old_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.invalid \
  commit -qm newer --allow-empty
unchanged 'another HEAD cannot answer' "$valid"
git -C "$repo" checkout -q --detach "$old_head"
unchanged 'detached HEAD cannot answer a branch request' "$valid"
git -C "$repo" checkout -q feature

foreign_state="$state"
fresh
cp "$state" "$scratch/own-request"
cp "$foreign_state" "$state"
unchanged 'request belonging to another repository is rejected' "$valid"
cp "$scratch/own-request" "$state"

old_id="$id"; old_reply="$answer"
publish "$design"$'\n\nChanged scope.'
gate
check 'changed design content creates a new request' test "$(jq -r .id "$state")" != "$old_id"
unchanged 'old typed reply cannot answer replacement request' "$old_reply"

fresh
old_reply="$answer"
prompt "$old_reply"
gate
unchanged 'consumed reply cannot be recorded twice' "$old_reply"

for choice in Redesign Overrule; do
  fresh
  prompt "design-decision: $id $choice Use the selected recovery"
  gate
  if [[ "$choice" == Redesign ]]; then
    check 'Redesign requires fresh content' grep -q 'The human chose Redesign' "$scratch/gate-err"
  else
    check 'Overrule permits the edit' test "$gate_status" = 0
    check 'Overrule is OVERRIDDEN, never PASS' json '.verdict=="OVERRIDDEN"' "$audit"
  fi
  check "$choice consumes its request" json '.status=="consumed"' "$state"
done

# The second provider read inside decide must not authorize different content.
fresh
prompt "design-decision: $id Overrule Accept this exact design"
export DOC_CHANGED="$scratch/changed.json" DESIGN_REPLY_SWAP="$scratch/provider-count"
jq --arg body "$design"$'\n\nUnapproved change.' '.body=$body' "$DOC_RESPONSE" > "$DOC_CHANGED"
printf '0\n' > "$DESIGN_REPLY_SWAP"
gate
unset DESIGN_REPLY_SWAP
check 'second-read substitution denies the edit' test "$gate_status" = 2
check 'second-read substitution cannot receive prior Overrule' json '.verdict=="FAIL"' "$audit"
check 'rejected substitution does not consume the reply' json '.status=="accepted"' "$state"

# Both history snapshots come from production transitions in the same checkout.
fresh
cp "$audit" "$scratch/prior-audit"
cp "$state" "$scratch/prior-request"
prompt "design-decision: $id Overrule Close the first cycle"
gate
record_fail; record_fail
cp "$audit" "$scratch/later-audit"
cp "$scratch/prior-audit" "$audit"
cp "$scratch/prior-request" "$state"
prompt "design-decision: $id Overrule Accept the first cycle only"
export DESIGN_REPLY_HISTORY="$scratch/later-audit" DESIGN_REPLY_AUDIT="$audit"
export DESIGN_REPLY_SWAP="$scratch/provider-count"
cp "$DOC_RESPONSE" "$DOC_CHANGED"
printf '0\n' > "$DESIGN_REPLY_SWAP"
gate
unset DESIGN_REPLY_SWAP DESIGN_REPLY_HISTORY DESIGN_REPLY_AUDIT
check 'changed audit history denies the decision' test "$gate_status" = 2
check 'changed audit history retains its FAIL' json '.verdict=="FAIL"' "$audit"
check 'history rejection does not consume the reply' json '.status=="accepted"' "$state"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
