#!/usr/bin/env bash
# Tests for .agents/hooks/stop-gate.sh, the Stop hook that checks the final reply's
# TL;DR before preflight-verdict-check.sh judges the turn.
#
#   - a nonempty reply without a leading TL;DR  -> one correction on the initial Stop
#   - anything else, dense TL;DR-led replies    -> the verdict check's own output, exit
#     included                                     status and stderr, unchanged
# Each case builds a throwaway git repo with a fake transcript, runs the gate there
# (cwd + CLAUDE_PROJECT_DIR pointed at it), and asserts on its output.
#
# Run with:  bash .agents/hooks/session/stop-gate.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Hermetic baseline, as in preflight-verdict-check.test.sh: hard mode, no live
# classifier, no custom extractor.
unset VERDICT_GATE_HARD_BLOCK VERDICT_EXTRACTOR_CMD HOOK_STDERR
export VERDICT_CLASSIFIER_CMD='false'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/stop-gate.sh"
VERDICT_CHECK="$REPO_ROOT/.agents/hooks/audit/preflight-verdict-check.sh"
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
run_in_repo() {  # repo script classifier-answer host payload
  printf '%s' "$5" | (
    cd "$1" || exit 1
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    [[ "$4" != claude ]] || export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
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
# The request the gate made before a leading TL;DR was enough; it must never return.
shortening_request='Use the boxlite-writing skill to shorten this response.'
no_request() { [[ "$1" != *"$shortening_request"* && -z "$(field "$1" '.hookSpecificOutput.additionalContext')" ]]; }
keeps_triage_note() { [[ "$(field "$1" '.systemMessage')" == *"triage: NO"* ]]; }
audit_ran() { [[ -e "$1/.agents/state/SYNC_AUDIT_RAN" ]]; }

long_reply="$(printf 'word%.0s ' {1..81})"
short_reply="Done: the gate checks the summary. Say go to commit."
long_claim="$(printf 'more%.0s ' {1..121})and the root cause is the stale index."

check_writing_continuations() {
  local host S R payload out
  for host in claude codex; do
    S="tldr-to-dense-$host"; R="$(new_repo "$S")"
    payload="$(stop_payload "$R" "$S" false '' | jq '.last_assistant_message = "Missing summary."')"
    out="$(run_in_repo "$R" "$HOOK" NO "$host" "$payload")"
    jq -e '.decision == "block" and (.reason | contains("TL;DR"))' <<<"$out" >/dev/null
    expect "$host: the first missing summary gets a correction" "$?" "out=$out"
    append_assistant "$R" "$long_reply"
    out="$(gate_stop "$R" "$S" true "$long_reply" NO "$host")"
    [[ "$(classifier_ran "$R")" == yes && "$(decision_of "$out")" == allow ]] && no_request "$out"
    expect "$host: the corrected dense reply is judged and ends" "$?" "out=$out"
    append_tool_call "$R"
    append_assistant "$R" "$long_claim"
    payload="$(stop_payload "$R" "$S" true '' | jq '.last_assistant_message = "The root cause is the stale index."')"
    out="$(TEST_AUDIT_VERDICT=FAIL run_in_repo "$R" "$HOOK" YES "$host" "$payload")"
    audit_ran "$R" && [[ "$(decision_of "$out")" == block && "$out" != *'TL;DR heading missing'* ]]
    expect "$host: new work in a continuation still reaches the failing audit without TL;DR" "$?" "out=$out"
    rm -rf "$R"
  done
}
if [[ "${1:-}" == writing-continuations ]]; then
  check_writing_continuations
  printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
  exit $(( fail > 0 ? 1 : 0 ))
fi

printf '## A TL;DR-led reply, dense or short, gets exactly the verdict check'"'"'s output\n'
# Twin repos in the same state: the verdict check records what it judged, so a second
# run in one repo would see an already-judged message.
for host in claude codex; do
  for size in dense short; do
    reply="$long_reply"
    [[ "$size" == dense ]] || reply="$short_reply"
    S="$size-$host"; R="$(new_repo "$S")"; T="$(new_repo "$S")"
    append_assistant "$R" "$reply"
    append_assistant "$T" "$reply"
    out="$(gate_stop "$R" "$S" false "$reply" NO "$host")"
    direct="$(run_in_repo "$T" "$VERDICT_CHECK" NO "$host" "$(stop_payload "$T" "$S" false "$reply")")"
    [[ -n "$out" && "$out" == "$direct" ]] && keeps_triage_note "$out" && no_request "$out"
    expect "$host: a $size TL;DR-led reply ends with the verdict check's output" "$?" \
      "gate=$out direct=$direct"
    rm -rf "$R" "$T"
  done
done

S="pass"; R="$(new_repo "$S")"
append_assistant "$R" "$long_claim"
out="$(TEST_AUDIT_VERDICT=PASS gate_stop "$R" "$S" false "$long_claim" YES claude)"
audit_ran "$R" && [[ "$(decision_of "$out")" == allow ]] && no_request "$out"
expect "an audited PASS on a dense reply ends without a shortening request" "$?" "out=$out"
rm -rf "$R"

# A user's override ends the turn without an audit and without a shortening request.
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
[[ "$(field "$out" '.systemMessage')" == *"OVERRIDDEN BY USER"* && "$(decision_of "$out")" == allow ]] \
  && no_request "$out"
expect "a user's override on a dense reply ends without a shortening request" "$?" "out=$out"
rm -rf "$R"

check_writing_continuations

# Harness text is allowed without a judgment, but it still needs a TL;DR.
S="harness"; R="$(new_repo "$S")"
api_error="API Error: 529 $long_reply"
saved_summary_prefix="$summary_prefix"; summary_prefix=""
append_assistant "$R" "$api_error"
out="$(gate_stop "$R" "$S" false "$api_error" YES claude)"
summary_prefix="$saved_summary_prefix"
unjudged() { [[ "$(classifier_ran "$1")" == no ]]; }
unjudged "$R" && [[ "$(decision_of "$out")" == block && "$out" == *"TL;DR"* ]]
expect "nonempty harness text without TL;DR is blocked before judgment" \
  "$?" "out=$out classifier=$(classifier_ran "$R")"
rm -rf "$R"

S="fail"; R="$(new_repo "$S")"
append_assistant "$R" "$long_claim"
out="$(gate_stop "$R" "$S" false "$long_claim" YES claude)"
audit_ran "$R" && [[ "$(decision_of "$out")" == block && "$(field "$out" '.reason')" == *"Verdict proof check FAILED"* ]]
expect "an audited FAIL blocks with its findings" "$?" "out=$out"
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

printf '\n## Writing denials reference the skill without reading its body\n'
# Isolate skill changes and exercise checkout names with spaces.
prompt_fixture="$(mktemp -d)"
cp -R "$REPO_ROOT" "$prompt_fixture/plugin copy"
original_hook="$HOOK"
HOOK="$prompt_fixture/plugin copy/.agents/hooks/stop-gate.sh"
prompt_file="$prompt_fixture/plugin copy/.agents/skills/boxlite-writing/SKILL.md"
HOOK_STDERR="$prompt_fixture/stderr"
missing_summary() {  # repo session -> Stop payload whose reply has no TL;DR
  stop_payload "$1" "$2" false '' | jq '.last_assistant_message = "Missing summary."'
}
edits_status=0
for host in claude codex; do
  printf 'Unique writing policy marker.\n' > "$prompt_file"
  S="prompt-$host"; R="$(new_repo "$S")"
  out="$(run_in_repo "$R" "$HOOK" NO "$host" "$(missing_summary "$R" "$S")")"
  [[ "$(field "$out" '.reason')" == *'apply boxlite-writing'* && "$out" != *'Unique writing policy marker'* ]] \
    || edits_status=1
  for operation in 'pr comment 7' 'pr create --title "feat: share prompt"'; do
    github_output="$(jq -nc --arg command "gh $operation --body '$long_reply'" \
      '{tool_input:{command:$command}}' \
      | bash "$prompt_fixture/plugin copy/.agents/hooks/preflight-pr-review.sh")"
    github_reason="$(field "$github_output" '.hookSpecificOutput.permissionDecisionReason')"
    [[ "$(field "$github_output" '.hookSpecificOutput.permissionDecision')" == deny \
       && "${github_reason#*$'\n\n'}" == "$shortening_request" ]] || edits_status=1
  done
  rm -rf "$R"
done
expect "Stop and GitHub hooks on both hosts name the skill without copying its body" \
  "$edits_status" "stop=$out github=$github_output"

rm -f "$prompt_file"
S="prompt-missing"; R="$(new_repo "$S")"
out="$(run_in_repo "$R" "$HOOK" NO codex "$(missing_summary "$R" "$S")")"
status=$?
[[ "$status" == 0 && "$(decision_of "$out")" == block && "$(field "$out" '.reason')" == *'apply boxlite-writing'* ]] \
  && ! grep -q 'no such prompt' "$HOOK_STDERR"
expect "a missing local skill does not prevent the host from receiving its name" \
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
