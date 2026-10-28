#!/usr/bin/env bash
# Exercise the auditor's actual input, through both public entry points.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
pass=0 fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"
  fi
}

cat > "$fixture_root/auditor.sh" <<'AUDITOR'
set -euo pipefail
state="$CLAUDE_PROJECT_DIR/.agents/state"
prompt="$(cat)"
printf '%s' "$prompt" > "$state/prompt"
task="$(sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }' "$state/prompt")"
printf '%s' "$task" > "$state/task"
transcript="$(jq -r .transcript_path <<<"$task")"
cp "$transcript" "$state/received.jsonl"
if [[ "${TEST_APPEND_SOURCE:-false}" == true ]]; then
  printf '{"type":"system","text":"appended after launch"}\n' >> "$state/source.jsonl"
  shasum -a 256 "$transcript" | cut -d ' ' -f 1 > "$state/after-append.sha"
fi
history="$(jq -r '.history_path // empty' <<<"$task")"
if [[ -n "$history" ]]; then
  jq -c '.attempts[-1].input.snapshot.transcript' "$history" > "$state/history-transcript.json"
fi
idx="$(mktemp)"
GIT_INDEX_FILE="$idx" git read-tree HEAD
GIT_INDEX_FILE="$idx" git add -A
tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
rm -f "$idx"
jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
  --arg tree "$tree" --arg generation "$VERDICT_AUDITOR_GENERATION" \
  '{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,
    verdict:"PASS",proof:[],findings:[]}' > "$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$TEST_HISTORY_RESULT_HELPER" "$task" "$VERDICT_AUDITOR_OUTPUT_FILE"
AUDITOR
export TRANSCRIPT_TEST_AUDITOR="$fixture_root/auditor.sh"
export TEST_HISTORY_RESULT_HELPER="$plugin_root/scripts/fixtures/audit-history-result.sh"
export VERDICT_AUDITOR_CMD='bash "$TRANSCRIPT_TEST_AUDITOR"'
export VERDICT_CLASSIFIER_CMD=false
unset VERDICT_EXTRACTOR_CMD

for host in claude codex; do
  for entry in runner stop; do
    repo="$fixture_root/$host-$entry"
    state="$repo/.agents/state"
    mkdir -p "$state"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.test
    git -C "$repo" config user.name tester
    printf '.agents/state/\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore
    git -C "$repo" commit -qm base
    # Native host envelopes, older evidence, many events, and one giant JSONL record.
    perl -MJSON::PP -e '
      my $host = shift;
      my $json = JSON::PP->new->canonical;
      sub emit { print $json->encode($_[0]), "\n" }
      sub message {
        my ($role, $text) = @_;
        if ($host eq "claude") {
          emit({type=>$role, message=>{content=>[{type=>"text",text=>$text}]}});
        } else {
          emit({type=>"response_item",payload=>{type=>"message",role=>$role,
            content=>[{type=>($role eq "user" ? "input_text" : "output_text"),text=>$text}]}});
        }
      }
      sub call {
        my ($id, $command) = @_;
        if ($host eq "claude") {
          emit({type=>"assistant",message=>{content=>[
            {type=>"tool_use",id=>$id,name=>"Bash",input=>{command=>$command}}]}});
        } else {
          emit({type=>"response_item",payload=>{type=>"function_call",call_id=>$id,
            name=>"exec_command",arguments=>$json->encode({cmd=>$command})}});
        }
      }
      sub result {
        my ($id, $output) = @_;
        if ($host eq "claude") {
          emit({type=>"user",message=>{content=>[
            {type=>"tool_result",tool_use_id=>$id,content=>$output}]}});
        } else {
          emit({type=>"response_item",payload=>{type=>"function_call_output",call_id=>$id,output=>$output}});
        }
      }
      message("user", "previous request");
      call("old-test", "make test-old");
      result("old-test", "OLD_EVIDENCE " . ("o" x 1100000));
      message("assistant", "Previous check finished.");
      message("user", "Verify the new work.");
      for my $i (1..200) {
        call("read-$i", "inspect file-$i");
        result("read-$i", "x" x 4096);
      }
      call("late-test", "make test-late");
      result("late-test", ("x" x 700000) . "\n80 tests passed; exit code 0\n" . ("y" x 700000));
      message("assistant", "The tests pass.");
    ' "$host" > "$state/source.jsonl"
    expected="$(shasum -a 256 "$state/source.jsonl" | cut -d ' ' -f 1)"
    rc=0
    if [[ "$entry" == runner ]]; then
      (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST="$host" \
        TEST_APPEND_SOURCE=true bash "$plugin_root/.agents/hooks/audit/run-verdict-audit.sh" \
        "$state/source.jsonl") > "$state/stdout" 2> "$state/stderr" || rc=$?
    else
      jq -nc --arg path "$state/source.jsonl" \
        '{hook_event_name:"Stop",session_id:"full-transcript",transcript_path:$path}' \
        | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST="$host" \
          bash "$plugin_root/.agents/hooks/audit/preflight-verdict-check.sh") \
          > "$state/stdout" 2> "$state/stderr" || rc=$?
    fi
    check "$host $entry completes" "$rc" 0
    received="$(shasum -a 256 "$state/received.jsonl" 2>/dev/null | cut -d ' ' -f 1)"
    check "$host $entry gives auditor every original byte" "$received" "$expected"
    path="$(jq -r '.transcript_path // empty' "$state/task" 2>/dev/null)"
    clean=no
    [[ "$path" == /* && "$path" != "$state/source.jsonl" && ! -e "$path" \
      && ! -d "$(dirname "$path")" ]] && clean=yes
    check "$host $entry cleans its private transcript directory" "$clean" yes
    skill=no
    grep -q '^## Read the transcript' "$state/prompt" 2>/dev/null && skill=yes
    check "$host $entry loads the audit skill's transcript procedure" "$skill" yes
    if [[ "$entry" == runner ]]; then
      check "$host copy stays frozen when source appends" \
        "$(cat "$state/after-append.sha" 2>/dev/null)" "$expected"
    else
      history_bytes="$(wc -c < "$state/history-transcript.json" 2>/dev/null | tr -d ' ')"
      bounded=no
      if [[ "$history_bytes" =~ ^[0-9]+$ && "$history_bytes" -le 262146 ]] \
        && jq -e '.[0].type == "verdict_final_turn_snapshot"' \
          "$state/history-transcript.json" >/dev/null 2>&1; then bounded=yes; fi
      check "$host history retains a bounded bookkeeping snapshot" "$bounded" yes
      check "$host Stop accepts the bound PASS" "$(cat "$state/stdout")" ""
    fi
  done
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
