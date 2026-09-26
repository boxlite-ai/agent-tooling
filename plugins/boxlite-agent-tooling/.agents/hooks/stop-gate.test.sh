#!/usr/bin/env bash
# Tests for .agents/hooks/stop-gate.sh, the Stop hook that runs the small-reply rule
# around preflight-verdict-check.sh.
#
#   - judged allow + paragraph over 80 words  -> continue once with the editable
#     or list item over 40 words                 reply-summary prompt
#   - that reply, at most 120 words counting   -> ends the turn; the verdict check is
#     code blocks, no tool since the ask          not run again
#   - anything else                            -> the verdict check's own output, exit
#                                                 status and stderr, unchanged
# Each case builds a throwaway git repo with a fake transcript, runs the gate there
# (cwd + CLAUDE_PROJECT_DIR pointed at it), and asserts on its output.
#
# Run with:  bash .agents/hooks/stop-gate.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Hermetic baseline, as in preflight-verdict-check.test.sh: hard mode, no live
# classifier, no custom extractor.
unset VERDICT_GATE_HARD_BLOCK VERDICT_EXTRACTOR_CMD HOOK_STDERR
export VERDICT_CLASSIFIER_CMD='false'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/stop-gate.sh"
VERDICT_CHECK="$REPO_ROOT/.agents/hooks/preflight-verdict-check.sh"
CANCEL_HOOK="$REPO_ROOT/.agents/hooks/cancel-verdict-audit.sh"

pass=0
fail=0
expect() {  # desc predicate-status detail
  if [[ "$2" == 0 ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (%s)\n' "$1" "$3"
  fi
}

# Fresh git repo with one committed file and the state directory ignored, as in the
# real repository.
setup() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  printf 'pub fn base() {}\n' > "$d/lib.rs"
  printf '.agents/state/\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}
append_user() {
  jq -nc --arg t "$2" '{type:"user", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
append_assistant() {
  jq -nc --arg t "$summary_prefix$2" '{type:"assistant", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
append_tool_call() {
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", id:"tu1", name:"Bash", input:{command:"ls"}}]}}' \
    >> "$1/transcript.jsonl"
  jq -nc '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:[{type:"text", text:"src"}]}]}}' \
    >> "$1/transcript.jsonl"
}

# A classifier stub that records its own invocation and answers $2.
cls_stub() { printf "while IFS= read -r _line; do :; done; : > '%s/CLASSIFIER_RAN'; printf '%s\\n'" "$1" "$2"; }
classifier_ran() { [[ -e "$1/CLASSIFIER_RAN" ]] && echo yes || echo no; }

# The independent auditor seam: writes a generation-bound dossier with the verdict in
# TEST_AUDIT_VERDICT and marks that it ran.
# shellcheck disable=SC2016 # a script body: its variables expand when the runner runs it
export VERDICT_AUDITOR_CMD='prompt="$(cat)"
mkdir -p "$CLAUDE_PROJECT_DIR/.agents/state"
touch "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_RAN"
idx="$(mktemp)"
GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" read-tree HEAD >/dev/null 2>&1
GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" add -A >/dev/null 2>&1
tree="$(GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" write-tree 2>/dev/null)"
rm -f "$idx"
verdict="${TEST_AUDIT_VERDICT:-FAIL}"
findings='\''["independent audit finding"]'\''
[[ "$verdict" == PASS ]] && findings='\''[]'\''
jq -nc --arg branch "$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current)" \
  --arg head "$(git -C "$CLAUDE_PROJECT_DIR" rev-parse HEAD)" --arg tree "$tree" \
  --arg generation "$VERDICT_AUDITOR_GENERATION" --arg verdict "$verdict" \
  --argjson findings "$findings" \
  '\''{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,
     verdict:$verdict,proof:[],findings:$findings}'\'' \
  > "$VERDICT_AUDITOR_OUTPUT_FILE"
task="$(printf "%s\n" "$prompt" | sed -n "/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }")"
bash "$TEST_HISTORY_RESULT_HELPER" "$task" "$VERDICT_AUDITOR_OUTPUT_FILE"'
export TEST_HISTORY_RESULT_HELPER="$REPO_ROOT/scripts/fixtures/audit-history-result.sh"
export TEST_AUDIT_VERDICT=FAIL

# Session state paths use an opaque Git object hash, reproduced here independently.
session_state_path() {  # repo basename session
  printf '%s/.agents/state/%s.git-%s' "$1" "$2" \
    "$(printf '%s' "$3" | git -C "$1" hash-object --stdin)"
}
prompt_hook() {  # repo session turn
  jq -nc --arg s "$2" --arg t "$3" '{hook_event_name:"UserPromptSubmit",session_id:$s,turn_id:$t,prompt:"new user input"}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$CANCEL_HOOK" ) >/dev/null 2>&1
}
new_repo() {  # session -> repo at prompt epoch 1 with a user turn
  local repo; repo="$(setup)"
  prompt_hook "$repo" "$1" turn-1
  : > "$repo/transcript.jsonl"
  append_user "$repo" "explain the gate"
  printf '%s' "$repo"
}

summary_prefix=$'## TL;DR\n\nFixture summary.\n\n## Details\n\n'
HARD_BLOCK=1
stop_payload() {  # repo session stop-hook-active last-message
  if [[ -n "$2" ]]; then
    jq -nc --arg p "$1/transcript.jsonl" --arg s "$2" --argjson a "$3" --arg m "$summary_prefix$4" \
      '{transcript_path:$p, hook_event_name:"Stop", session_id:$s,
        stop_hook_active:$a, last_assistant_message:$m}'
  else
    jq -nc --arg p "$1/transcript.jsonl" --argjson a "$3" --arg m "$summary_prefix$4" \
      '{transcript_path:$p, hook_event_name:"Stop", stop_hook_active:$a,
        last_assistant_message:$m}'
  fi
}
# INJECT_BASH_ENV, when set, names a file every bash in the run sources first; the race
# cases use it to move the prompt epoch at one exact command.
INJECT_BASH_ENV=""
run_in_repo() {  # repo script classifier-answer host payload
  printf '%s' "$5" | (
    cd "$1" || exit 1
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    [[ "$4" != claude ]] || export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    BASH_ENV="$INJECT_BASH_ENV" CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK="$HARD_BLOCK" \
      VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$3")" bash "$2"
  ) 2>"${HOOK_STDERR:-/dev/null}"
}
gate_stop() {  # repo session stop-hook-active last-message classifier-answer [claude]
  run_in_repo "$1" "$HOOK" "$5" "${6:-}" "$(stop_payload "$1" "$2" "$3" "$4")"
}

field() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null; }
decision_of() {
  if [[ -z "$1" ]]; then printf allow; return; fi
  [[ "$(field "$1" '.decision')" == block ]] && printf block || printf allow
}
# Compare delivery with the editable template, without pinning its wording here.
expected_request="$(
  # shellcheck source=../lib/subagent.sh
  source "$REPO_ROOT/.agents/lib/subagent.sh"
  subagent_prompt concise-writing "$REPO_ROOT" max_words=60
)"
asked_as_context() {
  [[ "$(field "$1" '.hookSpecificOutput.hookEventName')" == Stop \
     && -n "$expected_request" \
     && "$(field "$1" '.hookSpecificOutput.additionalContext')" == "$expected_request" \
     && -z "$(field "$1" '.decision')" ]]
}
asked_as_block() {
  [[ "$(field "$1" '.decision')" == block && -n "$expected_request" \
     && "$(field "$1" '.reason')" == "$expected_request" ]]
}
asked() { asked_as_context "$1" || asked_as_block "$1"; }
not_asked() { ! asked "$1"; }
keeps_triage_note() { [[ "$(field "$1" '.systemMessage')" == *"triage: NO"* ]]; }
ended_unjudged() { [[ -z "$1" && "$(classifier_ran "$2")" == no ]]; }
judged_without_ask() {
  [[ "$(classifier_ran "$2")" == yes && "$(decision_of "$1")" == allow ]] && not_asked "$1"
}
audit_ran() { [[ -e "$1/.agents/state/SYNC_AUDIT_RAN" ]]; }
logged_rung() {  # repo session "rung outcome"
  grep -q " $3\$" "$(session_state_path "$1" verdict-decisions.log "$2")" 2>/dev/null
}

long_reply="$(printf 'word%.0s ' {1..81})"
short_reply="Done: the gate asks for a small closing reply. Say go to commit."
long_claim="$(printf 'more%.0s ' {1..121})and the root cause is the stale index."

printf '## Summary requests follow text-block density\n'
check_summary_density() {  # name reply ask|skip
  local name="$1" reply="$2" expected="$3" repo output status
  repo="$(new_repo "density-$name")"
  append_assistant "$repo" "$reply"
  output="$(gate_stop "$repo" "density-$name" false "$reply" NO claude)"
  status=$?
  if [[ "$expected" == ask ]]; then
    [[ "$status" == 0 ]] && asked "$output"
  else
    [[ "$status" == 0 ]] && judged_without_ask "$output" "$repo"
  fi
  expect "$name: $expected summary" "$?" "status=$status out=$output"
  rm -rf "$repo"
}
check_summary_density "80-word paragraph" "$(printf 'word%.0s ' {1..80})" skip
check_summary_density "81-word paragraph" "$(printf 'word%.0s ' {1..81})" ask
check_summary_density "two 60-word paragraphs" \
  "$(printf 'word%.0s ' {1..60}; printf '\n\n'; printf 'word%.0s ' {1..60})" skip
check_summary_density "40-word bullet" "- $(printf 'word%.0s ' {1..40})" skip
check_summary_density "41-word bullet" "- $(printf 'word%.0s ' {1..41})" ask
check_summary_density "ten short bullets" \
  "$(for item in {1..10}; do printf -- '- '; printf 'word%.0s ' {1..20}; printf '\n'; done)" skip
check_summary_density "ten short numbered items" \
  "$(for item in {1..10}; do printf '%s. ' "$item"; printf 'word%.0s ' {1..20}; printf '\n'; done)" skip
check_summary_density "200-word table" \
  "$(printf '| Result | Details |\n| --- | --- |\n| Done | '; printf 'word%.0s ' {1..200}; printf '|\n')" skip
check_summary_density "200-word table without outer pipes" \
  "$(printf 'Result | Details\n--- | ---\nDone | '; printf 'word%.0s ' {1..200}; printf '\n')" skip
check_summary_density "soft-wrapped 81-word paragraph" \
  "$(printf 'word%.0s ' {1..40}; printf '\n'; printf 'word%.0s ' {1..41})" ask
check_summary_density "wrapped 41-word bullet" \
  "$(printf -- '- '; printf 'word%.0s ' {1..20}; printf '\n  '; printf 'word%.0s ' {1..21})" ask
check_summary_density "41-word numbered item" "1. $(printf 'word%.0s ' {1..41})" ask
check_summary_density "70-character Chinese paragraph" "$(printf '长%.0s' {1..70})" skip
check_summary_density "41-character Chinese bullet" "- $(printf '长%.0s' {1..41})" ask
check_summary_density "two paragraphs inside one 50-word bullet" \
  "$(printf -- '- '; printf 'word%.0s ' {1..25}; printf '\n\n  '; printf 'word%.0s ' {1..25})" ask
check_summary_density "40-word bullet followed by a 60-word paragraph" \
  "$(printf -- '- '; printf 'word%.0s ' {1..40}; printf '\n\n'; printf 'word%.0s ' {1..60})" skip
check_summary_density "headings separate short paragraphs" \
  "$(printf 'word%.0s ' {1..60}; printf '\n# Next\n'; printf 'word%.0s ' {1..60})" skip
check_summary_density "a pipe does not make prose a table" \
  "$(printf 'left | right '; printf 'word%.0s ' {1..79})" ask
check_summary_density "a table does not hide a following dense bullet" \
  "$(printf '| Result | Details |\n| --- | --- |\n| Done | Clear |\n\n- '; printf 'word%.0s ' {1..41})" ask
check_summary_density "a bullet interrupts a table without a blank line" \
  "$(printf '| Result | Details |\n| --- | --- |\n| Done | Clear |\n- left | right '; printf 'word%.0s ' {1..39})" ask
check_summary_density "table body rows can omit pipes" \
  "$(printf '| Result | Details |\n| --- | --- |\n'; printf 'word%.0s ' {1..200})" skip
check_summary_density "a single-column table is excluded" \
  "$(printf '| Details |\n| --- |\n| '; printf 'word%.0s ' {1..200}; printf '|\n')" skip
check_summary_density "mismatched table columns remain prose" \
  "$(printf '| Result | Details |\n| --- |\n| '; printf 'word%.0s ' {1..81}; printf '|\n')" ask
check_summary_density "a block quote interrupts a table" \
  "$(printf '| Result | Details |\n| --- | --- |\n| Done | Clear |\n> '; printf 'word%.0s ' {1..81})" ask
check_summary_density "nested fence markers stay inside their fence" \
  "$(printf '\140\140\140\140text\n\140\140\140\n'; printf 'word%.0s ' {1..200}; printf '\n\140\140\140\140\n')" skip
check_summary_density "a fenced block does not hide following dense prose" \
  "$(printf '\140\140\140text\nexample\n\140\140\140\n'; printf 'word%.0s ' {1..81})" ask

printf '## Claude Code: ask as context, then end on the small reply\n'
S="context"; R="$(new_repo "$S")"
append_tool_call "$R"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" false "$long_reply" NO claude)"
asked_as_context "$out"
expect "a long judged reply continues the turn with the request as context" "$?" "out=$out"
keeps_triage_note "$out"
expect "the ask keeps the human's triage note" "$?" "out=$out"
append_assistant "$R" "$short_reply"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$short_reply" YES claude)"
ended_unjudged "$out" "$R"
expect "the small reply ends the turn without running the verdict check" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
logged_rung "$R" "$S" "summary restatement-allow"
expect "the restatement joins the verdict check's decision log" "$?" \
  "log=$(cat "$(session_state_path "$R" verdict-decisions.log "$S")" 2>/dev/null)"
rm -rf "$R"

printf '\n## Any other caller: ask with a block, which starts a new transcript turn\n'
S="block"; R="$(new_repo "$S")"
append_tool_call "$R"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" false "$long_reply" NO)"
asked_as_block "$out"
expect "an unidentified host gets the request as a portable block" "$?" "out=$out"
append_user "$R" "Stop hook feedback: $(field "$out" '.reason')"
append_assistant "$R" "$short_reply"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$short_reply" YES)"
ended_unjudged "$out" "$R"
expect "the small reply after a block ends the turn without running the verdict check" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="block-tool"; R="$(new_repo "$S")"
append_tool_call "$R"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" false "$long_reply" NO)"
append_user "$R" "Stop hook feedback: $(field "$out" '.reason')"
append_tool_call "$R"
append_assistant "$R" "$short_reply"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$short_reply" NO)"
judged_without_ask "$out" "$R"
expect "a tool call after a block ask sends the reply to the verdict check" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

printf '\n## The answer to an ask is new work unless it only restates\n'
S="tool"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
append_tool_call "$R"
append_assistant "$R" "$short_reply"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$short_reply" NO claude)"
judged_without_ask "$out" "$R"
expect "a tool call since the ask sends the reply to the verdict check" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="overshoot"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
overshoot="$(printf 'word%.0s ' {1..67})"
append_assistant "$R" "$overshoot"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$overshoot" YES claude)"
ended_unjudged "$out" "$R"
expect "an answer within the independent 120-word bound still ends as a restatement" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

# The bound is words, not size: many wide drawings with few labels restate, while a
# fenced dump of many words is new text and goes to the verdict check.
fence="$(printf '\140\140\140')"
box="$(printf '%s\n' \
  "┌────────────────────┐    ask once    ┌────────────────────┐" \
  "│ Stop 1, long reply │ ─────────────▶ │  gate asks for it  │" \
  "└────────────────────┘                └────────────────────┘")"
drawings="$(for _ in 1 2 3 4 5 6; do printf '%stext\n%s\n%s\n' "$fence" "$box" "$fence"; done
  printf '| before | after |\n| --- | --- |\n| long last | result last |\n')"
S="drawings"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
append_assistant "$R" "$drawings"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$drawings" YES claude)"
ended_unjudged "$out" "$R"
expect "many drawings with few words end as a restatement" \
  "$?" "out=$out classifier=$(classifier_ran "$R") chars=${#drawings}"
rm -rf "$R"

S="dump"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
dump="$(printf '%stext\n' "$fence"; printf 'log line %s of the run\n' $(seq 1 40); printf '%s\n' "$fence")"
append_assistant "$R" "$dump"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$dump" NO claude)"
judged_without_ask "$out" "$R"
expect "a fenced dump of many words answering the ask is judged" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="long-again"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
long_again="$(printf 'more%.0s ' {1..121})"
append_assistant "$R" "$long_again"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$long_again" NO claude)"
judged_without_ask "$out" "$R"
expect "a long answer to the ask is judged and never asked twice in a row" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="audited-answer"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
append_assistant "$R" "$long_claim"
out="$(TEST_AUDIT_VERDICT=PASS gate_stop "$R" "$S" true "$long_claim" YES claude)"
audit_ran "$R" && [[ "$(decision_of "$out")" == allow ]] && not_asked "$out"
expect "an audited PASS answering the ask does not ask again" "$?" "out=$out"
rm -rf "$R"

S="epoch"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
prompt_hook "$R" "$S" turn-2
append_user "$R" "next question"
append_assistant "$R" "$short_reply"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$short_reply" NO claude)"
judged_without_ask "$out" "$R"
expect "an ask from an earlier prompt is stale and the reply is judged" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

# A prompt that arrives while this Stop decides supersedes it. The BASH_ENV file plants
# a DEBUG trap that moves the prompt epoch right before the named command of
# stop-gate.sh, the one point a real prompt could land between two checks.
epoch_moves_before() {  # command-prefix -> path of a BASH_ENV file
  local file; file="$(mktemp)"
  printf 'STOP_GATE_MOVE_EPOCH_BEFORE=%q\n' "$1" > "$file"
  cat >> "$file" <<'INJECT'
set -T
trap 'if [[ "$0" == *stop-gate.sh && -z "${_epoch_moved:-}" \
           && "$BASH_COMMAND" == "$STOP_GATE_MOVE_EPOCH_BEFORE"* ]]; then
        _epoch_moved=1; printf "9-9-9\n" > "$prompt_epoch_file"; fi' DEBUG
INJECT
  printf '%s' "$file"
}
S="superseded-decision"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
INJECT_BASH_ENV="$(epoch_moves_before reply_summary_is_dense)"
out="$(gate_stop "$R" "$S" false "$long_reply" NO claude)"
rm -f "$INJECT_BASH_ENV"; INJECT_BASH_ENV=""
not_asked "$out" && [[ ! -e "$(session_state_path "$R" reply-summary-ask "$S")" ]]
expect "a prompt arriving before the ask is decided stops it" "$?" "out=$out"
rm -rf "$R"

S="superseded-record"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
INJECT_BASH_ENV="$(epoch_moves_before reply_summary_record_ask)"
out="$(gate_stop "$R" "$S" false "$long_reply" NO claude)"
rm -f "$INJECT_BASH_ENV"; INJECT_BASH_ENV=""
not_asked "$out" && [[ ! -e "$(session_state_path "$R" reply-summary-ask "$S")" ]]
expect "a prompt arriving while the ask is recorded retracts it" "$?" "out=$out"
rm -rf "$R"

# Chinese and Japanese count one word per character.
S="unspaced-long"; R="$(new_repo "$S")"
unspaced_long="$(printf '长%.0s' {1..81})"
append_assistant "$R" "$unspaced_long"
out="$(gate_stop "$R" "$S" false "$unspaced_long" NO claude)"
asked "$out"
expect "a Chinese paragraph of 81 characters is dense enough to ask" "$?" "out=$out"
rm -rf "$R"

S="unspaced-answer"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
gate_stop "$R" "$S" false "$long_reply" NO claude >/dev/null
unspaced_answer="$(printf '答%.0s' {1..130})"
append_assistant "$R" "$unspaced_answer"
rm -f "$R/CLASSIFIER_RAN"
out="$(gate_stop "$R" "$S" true "$unspaced_answer" NO claude)"
judged_without_ask "$out" "$R"
expect "a Chinese answer of 130 characters is judged, not taken as a restatement" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

printf '\n## Which allows ask\n'
S="pass"; R="$(new_repo "$S")"
append_assistant "$R" "$long_claim"
out="$(TEST_AUDIT_VERDICT=PASS gate_stop "$R" "$S" false "$long_claim" YES claude)"
audit_ran "$R" && asked "$out"
expect "an audited PASS on a long reply asks for the small one" "$?" "out=$out"
rm -rf "$R"

S="in-progress"; R="$(new_repo "$S")"
append_assistant "$R" "$long_claim"
out="$(TEST_AUDIT_VERDICT=IN_PROGRESS gate_stop "$R" "$S" false "$long_claim" YES claude)"
audit_ran "$R" && asked "$out"
expect "an audited IN_PROGRESS on a long reply asks for the result" "$?" "out=$out"
rm -rf "$R"

# A user's override ends the turn without an audit; the result is still asked for.
grant_override() {  # repo session
  local repo="$1" scope epoch now repo_hash
  scope="git-$(printf '%s' "$2" | git -C "$repo" hash-object --stdin)"
  epoch="$(cat "$repo/.agents/state/verdict-prompt-epoch.$scope")"
  now="$(date +%s)"
  repo_hash="$(printf '%s' "$(cd "$repo" && pwd -P)" | git -C "$repo" hash-object --stdin)"
  mkdir -p "$repo/.agents/state/auditor-control"
  jq -nc --arg repo_hash "$repo_hash" --arg scope "$scope" --arg epoch "$epoch" \
    --arg nonce_hash "$(printf nonce | shasum -a 256 | awk '{print $1}')" \
    --arg reason_hash "$(printf reason | shasum -a 256 | awk '{print $1}')" \
    --argjson created "$now" --argjson expires "$((now + 3600))" \
    '{repo_hash:$repo_hash,session_scope:$scope,prompt_epoch:$epoch,created_at:$created,
      expires_at:$expires,nonce_hash:$nonce_hash,reason_hash:$reason_hash}' \
    > "$repo/.agents/state/auditor-control/grant.$scope.json"
}
S="override"; R="$(new_repo "$S")"
grant_override "$R" "$S"
append_assistant "$R" "$long_claim"
out="$(gate_stop "$R" "$S" false "$long_claim" YES claude)"
[[ "$(field "$out" '.systemMessage')" == *"OVERRIDDEN BY USER"* ]] && asked "$out"
expect "a user's override on a long reply asks for the result" "$?" "out=$out"
rm -rf "$R"

S="after-fail"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" true "$long_reply" NO claude)"
asked "$out"
expect "a continued turn that was never asked still gets the ask" "$?" "out=$out"
rm -rf "$R"

# Harness text is allowed without a judgment, so it is no turn to summarize.
S="harness"; R="$(new_repo "$S")"
api_error="API Error: 529 $long_reply"
saved_summary_prefix="$summary_prefix"; summary_prefix=""
append_assistant "$R" "$api_error"
out="$(gate_stop "$R" "$S" false "$api_error" YES claude)"
[[ "$(classifier_ran "$R")" == no && "$(decision_of "$out")" == block && "$out" == *"TL;DR"* ]]
summary_prefix="$saved_summary_prefix"
expect "nonempty harness text without TL;DR is blocked before judgment" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="fail"; R="$(new_repo "$S")"
append_assistant "$R" "$long_claim"
out="$(gate_stop "$R" "$S" false "$long_claim" YES claude)"
[[ "$(decision_of "$out")" == block && "$(field "$out" '.reason')" == *"Verdict proof check FAILED"* ]] \
  && not_asked "$out"
expect "a verdict FAIL blocks with its findings and no ask" "$?" "out=$out"
rm -rf "$R"

printf '\n## Everything else is the verdict check, unchanged\n'
# Twin repos in the same state: the verdict check records what it judged, so a second
# run in one repo would see an already-judged message.
S="short"; R="$(new_repo "$S")"; T="$(new_repo "$S")"
append_assistant "$R" "$short_reply"
append_assistant "$T" "$short_reply"
out="$(gate_stop "$R" "$S" false "$short_reply" NO claude)"
direct="$(run_in_repo "$T" "$VERDICT_CHECK" NO claude "$(stop_payload "$T" "$S" false "$short_reply")")"
[[ -n "$out" && "$out" == "$direct" ]] && keeps_triage_note "$out"
expect "a short reply gets exactly the verdict check's output" "$?" "gate=$out direct=$direct"
rm -rf "$R" "$T"

S="fenced"; R="$(new_repo "$S")"
fenced="$(printf 'Run this to reproduce it:\n%stext\n%s\n%s' "$fence" "$long_reply" "$fence")"
append_assistant "$R" "$fenced"
out="$(gate_stop "$R" "$S" false "$fenced" NO claude)"
not_asked "$out"
expect "fenced code is not counted" "$?" "out=$out"
rm -rf "$R"

S="marks"; R="$(new_repo "$S")"
marks="$(printf 'Both paths, side by side:\n| path | kept |\n| --- | --- |\n'; \
  printf '| p%s | y |\n' 1 2 3 4 5 6 7 8 9 10; printf -- '- **a**\n- **b**\n')"
append_assistant "$R" "$marks"
out="$(gate_stop "$R" "$S" false "$marks" NO claude)"
not_asked "$out"
expect "table pipes and list marks are not words" "$?" "out=$out"
rm -rf "$R"

S="soft"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
HARD_BLOCK=0
out="$(gate_stop "$R" "$S" false "$long_reply" NO claude)"
HARD_BLOCK=1
not_asked "$out"
expect "soft mode never continues a turn to ask" "$?" "out=$out"
rm -rf "$R"

R="$(setup)"
: > "$R/transcript.jsonl"
append_user "$R" "explain the gate"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "" false "$long_reply" NO claude)"
not_asked "$out"
expect "a caller without a session never asks, having nowhere to remember it" "$?" "out=$out"
rm -rf "$R"

R="$(setup)"
err="$(printf 'not json' | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) 2>&1 >/dev/null)"
status=$?
reported_by_verdict_check() {  # status stderr
  [[ "$1" == 1 && "$2" == *"preflight-verdict-check: expected exactly one JSON hook object."* ]]
}
reported_by_verdict_check "$status" "$err"
expect "a malformed payload gets the verdict check's own error and exit status" "$?" \
  "status=$status err=$err"
rm -rf "$R"

S="none-allow"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" false "$long_reply" UNKNOWN claude)"
asked "$out"
expect "an allow from the fallback patterns asks like a triage allow" "$?" "out=$out"
rm -rf "$R"

printf '\n## A signal to the gate or its process group stops the verdict check\n'
# A signal reaches the gate two ways: to its whole process group, as a terminal's
# interrupt does, or to the gate alone. The gate leads its own group with SIGINT
# restored, because this suite's background jobs start with it ignored. A group signal
# must stop the stalled stage at once. A signal to the gate alone waits, as it did
# when the check was the hook, for the check's current step, and must still stop the
# check before any audit. Only the stalled stage is checked afterwards: the auditor's
# 30-second escalation watcher outlives an interrupted audit on main as well.
stalled_alive() {  # pgid -> 0 while a stalled stage still runs in that group
  ps -axo pgid=,command= 2>/dev/null \
    | awk -v g="$1" '$1 == g && $2 == "sleep" && ($3 == "20" || $3 == "3") { found = 1 } END { exit(found ? 0 : 1) }'
}
signal_gate() {  # signal triage|audit group|gate -> "status seconds-after gone scratch-gone reached audited"
  local signal="$1" stage="$2" target="$3" repo pid status sent elapsed classifier auditor stall=20
  local gone=no clean=no
  repo="$(new_repo "signal-$signal-$stage-$target")"
  append_assistant "$repo" "$long_claim"
  stop_payload "$repo" "signal-$signal-$stage-$target" false "$long_claim" > "$repo/payload.json"
  mkdir -p "$repo/tmp"
  [[ "$target" == group ]] || stall=3
  if [[ "$stage" == triage ]]; then
    classifier="while IFS= read -r _line; do :; done; : > '$repo/STAGE_REACHED'; sleep $stall; printf 'YES\\n'"
    auditor="$VERDICT_AUDITOR_CMD"
  else
    classifier="while IFS= read -r _line; do :; done; printf 'YES\\n'"
    auditor="cat >/dev/null; : > '$repo/STAGE_REACHED'; sleep $stall"
  fi
  TMPDIR="$repo/tmp" CLAUDE_PROJECT_DIR="$repo" VERDICT_GATE_HARD_BLOCK=1 \
    VERDICT_CLASSIFIER_CMD="$classifier" VERDICT_AUDITOR_CMD="$auditor" \
    perl -e 'chdir shift or exit 1; setpgrp(0, 0); $SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV' \
      "$repo" bash "$HOOK" < "$repo/payload.json" > /dev/null 2>&1 &
  pid=$!
  for _ in $(seq 300); do [[ -e "$repo/STAGE_REACHED" ]] && break; sleep 0.1; done
  sent=$SECONDS
  if [[ "$target" == group ]]; then
    kill "-$signal" -- "-$pid" 2>/dev/null
  else
    kill "-$signal" "$pid" 2>/dev/null
  fi
  wait "$pid"
  status=$?
  elapsed=$(( SECONDS - sent ))
  for _ in $(seq 50); do stalled_alive "$pid" || { gone=yes; break; }; sleep 0.1; done
  kill -TERM -- "-$pid" 2>/dev/null
  compgen -G "$repo/tmp/stop-gate.*" >/dev/null || clean=yes
  printf '%s %s %s %s %s %s' "$status" "$elapsed" "$gone" "$clean" \
    "$( [[ -e "$repo/STAGE_REACHED" ]] && echo yes || echo no)" \
    "$(audit_ran "$repo" && echo yes || echo no)"
  rm -rf "$repo"
}
stopped_cleanly() {  # expected-status status elapsed gone scratch-gone reached
  [[ "$2" == "$1" && "$3" -lt 8 && "$4" == yes && "$5" == yes && "$6" == yes ]]
}
read -r status elapsed gone clean reached audited <<<"$(signal_gate INT triage group)"
stopped_cleanly 130 "$status" "$elapsed" "$gone" "$clean" "$reached" && [[ "$audited" == no ]]
expect "a group interrupt during triage ends the gate with 130 before any audit" \
  "$?" "status=$status after=${elapsed}s gone=$gone scratch_gone=$clean reached=$reached audit=$audited"
read -r status elapsed gone clean reached audited <<<"$(signal_gate INT audit group)"
stopped_cleanly 130 "$status" "$elapsed" "$gone" "$clean" "$reached"
expect "a group interrupt during the audit stops it and ends the gate with 130" \
  "$?" "status=$status after=${elapsed}s gone=$gone scratch_gone=$clean reached=$reached"
read -r status elapsed gone clean reached audited <<<"$(signal_gate TERM audit group)"
stopped_cleanly 143 "$status" "$elapsed" "$gone" "$clean" "$reached"
expect "a group termination during the audit stops it and ends the gate with 143" \
  "$?" "status=$status after=${elapsed}s gone=$gone scratch_gone=$clean reached=$reached"
read -r status elapsed gone clean reached audited <<<"$(signal_gate INT triage gate)"
stopped_cleanly 130 "$status" "$elapsed" "$gone" "$clean" "$reached" && [[ "$audited" == no ]]
expect "an interrupt to the gate alone during triage stops the check before any audit" \
  "$?" "status=$status after=${elapsed}s gone=$gone scratch_gone=$clean reached=$reached audit=$audited"
read -r status elapsed gone clean reached audited <<<"$(signal_gate TERM triage gate)"
stopped_cleanly 143 "$status" "$elapsed" "$gone" "$clean" "$reached" && [[ "$audited" == no ]]
expect "a termination to the gate alone during triage stops the check before any audit" \
  "$?" "status=$status after=${elapsed}s gone=$gone scratch_gone=$clean reached=$reached audit=$audited"

printf '\n## Invariant: the ask record is gitignored, so it never enters the tree hash\n'
git -C "$REPO_ROOT" check-ignore -q .agents/state/reply-summary-ask
expect ".agents/state/reply-summary-ask is gitignored" "$?" "not ignored"

printf '\n## Reply-summary prompts are loaded from the plugin on each request\n'
# Edit an isolated plugin copy: live prompt edits must not affect another test or
# the developer's installed hook. The path also exercises checkout names with spaces.
prompt_fixture="$(mktemp -d)"
cp -R "$REPO_ROOT" "$prompt_fixture/plugin copy"
original_hook="$HOOK"
HOOK="$prompt_fixture/plugin copy/.agents/hooks/stop-gate.sh"
prompt_file="$prompt_fixture/plugin copy/.agents/prompts/concise-writing.md"
HOOK_STDERR="$prompt_fixture/stderr"
edits_status=0
for host in claude codex; do
  if [[ "$host" == claude ]]; then
    prompt_field='.hookSpecificOutput.additionalContext'
  else
    prompt_field='.reason'
  fi
  printf '%s: summarize in {{max_words}} words.\n' "$host" > "$prompt_file"
  S="prompt-$host"; R="$(new_repo "$S")"
  append_assistant "$R" "$long_reply"
  out="$(gate_stop "$R" "$S" false "$long_reply" NO "$host")"
  [[ "$(field "$out" "$prompt_field")" == "$host: summarize in 60 words." ]] \
    && keeps_triage_note "$out" || edits_status=1
  for operation in 'pr comment 7' 'pr create --title "feat: share prompt"'; do
    github_output="$(jq -nc --arg command "gh $operation --body '$long_reply'" \
      '{tool_input:{command:$command}}' \
      | bash "$prompt_fixture/plugin copy/.agents/hooks/preflight-pr-review.sh")"
    github_reason="$(field "$github_output" '.hookSpecificOutput.permissionDecisionReason')"
    [[ "$(field "$github_output" '.hookSpecificOutput.permissionDecision')" == deny \
       && "${github_reason#*$'\n\n'}" == "$host: summarize in 60 words." ]] || edits_status=1
  done
  rm -rf "$R"
done
expect "Stop and GitHub hooks on both hosts render the same edited shared prompt" \
  "$edits_status" "stop=$out github=$github_output"

rm -f "$prompt_file"
S="prompt-missing"; R="$(new_repo "$S")"
append_assistant "$R" "$long_reply"
out="$(gate_stop "$R" "$S" false "$long_reply" NO codex)"
status=$?
[[ "$status" == 0 && "$(decision_of "$out")" == allow \
   && ! -e "$(session_state_path "$R" reply-summary-ask "$S")" ]] \
  && keeps_triage_note "$out" \
  && ! logged_rung "$R" "$S" 'summary ask-continue' \
  && grep -q 'no such prompt' "$HOOK_STDERR"
expect "a missing template reports an error without asking or changing the verdict" \
  "$?" "status=$status out=$out stderr=$(cat "$HOOK_STDERR")"
rm -rf "$R"
HOOK="$original_hook"
unset HOOK_STDERR
rm -rf "$prompt_fixture"

S="empty-reply-audit"; R="$(new_repo "$S")"
append_assistant "$R" "The root cause is the stale index."
payload="$(stop_payload "$R" "$S" false '' | jq '.last_assistant_message = ""')"
out="$(run_in_repo "$R" "$HOOK" YES '' "$payload")"
[[ "$(decision_of "$out")" == block ]] && audit_ran "$R"
expect "an empty reply still audits earlier claims" "$?" "$out"
rm -rf "$R"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
