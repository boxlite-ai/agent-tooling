#!/usr/bin/env bash
# Exercise discovery context across the actual runner and Stop boundaries.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
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

fixture_stop() (
  cd "$repo" &&
    CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST="$host" TMPDIR="$state/tmp" \
      bash "$plugin_root/.agents/hooks/audit/preflight-verdict-check.sh"
)

normalize_snapshot() (
  # shellcheck source=../../.agents/lib/verdict-audit-state.sh
  source "$plugin_root/.agents/lib/verdict-audit-state.sh"
  verdict_audit_normalize_turn_snapshot
)

cat > "$fixture_root/auditor.sh" <<'AUDITOR'
set -euo pipefail
state="$CLAUDE_PROJECT_DIR/.agents/state"
prompt="$(cat)"
printf '%s' "$prompt" > "$state/prompt"
task="$(sed -n '/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }' "$state/prompt")"
printf '%s' "$task" > "$state/task"
session="$(jq -er '.parent_session_id | select(length > 0)' <<<"$task")"
root="$(jq -r .repo_root <<<"$task")"
transcript=""
for candidate in "$TEST_TRANSCRIPT_STORE"/*.jsonl; do
  if head -n 1 "$candidate" | jq -e --arg session "$session" --arg root "$root" '
      (.sessionId // .payload.id) == $session and (.cwd // .payload.cwd) == $root
    ' >/dev/null; then
    [[ -z "$transcript" ]] || exit 91
    transcript="$candidate"
  fi
done
[[ -n "$transcript" ]] || exit 92
cp "$transcript" "$state/received.jsonl"
if [[ "${TEST_APPEND_DURING_AUDIT:-}" == yes ]]; then
  printf '%s\n' '{"type":"metadata","event":"fixture append after capture"}' >> "$transcript"
fi
# The stub resolves fixture storage, not a production discovery implementation.
# It establishes handoff behavior; independent skill evaluations check judgment.
find "$TMPDIR" -name transcript.jsonl -print > "$state/parent-copies"
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
  --arg verdict "${TEST_AUDIT_VERDICT:-PASS}" \
  '{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,
    verdict:$verdict,proof:[],
    findings:(if $verdict == "FAIL" then ["fixture proof gap"] else [] end)}' > "$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$TEST_HISTORY_RESULT_HELPER" "$task" "$VERDICT_AUDITOR_OUTPUT_FILE"
validator="$(sed -n 's/^Dossier validator JSON: //p' "$state/prompt" | jq -er .path)"
if [[ -n "$history" ]]; then
  jq '.history_review.coverage.reviewed=["transcript"]' "$VERDICT_AUDITOR_OUTPUT_FILE" >"$state/incomplete.json"
  if bash "$validator" verdict "$history" "$state/incomplete.json" >"$state/validation.out" 2>"$state/validation.err"; then
    exit 93
  fi
  grep -Fq 'coverage missing=["tree"]' "$state/validation.err"
fi
# The complete candidate is then checked through stdin, as read-only hosts require.
bash "$validator" verdict "${history:--}" - <"$VERDICT_AUDITOR_OUTPUT_FILE" >"$state/validation.out"
jq -e '.valid == true' "$state/validation.out" >/dev/null
AUDITOR
export TRANSCRIPT_TEST_AUDITOR="$fixture_root/auditor.sh"
export TEST_HISTORY_RESULT_HELPER="$plugin_root/tests/audit/fixtures/audit-history-result.sh"
export VERDICT_AUDITOR_CMD='bash "$TRANSCRIPT_TEST_AUDITOR"'
export VERDICT_CLASSIFIER_CMD=false
unset VERDICT_EXTRACTOR_CMD

for host in claude codex unknown; do
  for entry in runner stop no-source; do
    repo="$fixture_root/$host-$entry"
    state="$repo/.agents/state"
    mkdir -p "$state"
    repo="$(cd "$repo" && pwd -P)"
    state="$repo/.agents/state"
    session="parent-$host-$entry"
    export TEST_TRANSCRIPT_STORE="$state/sessions"
    mkdir -p "$TEST_TRANSCRIPT_STORE" "$state/tmp"
    git -C "$repo" init -q
    git -C "$repo" config user.email test@example.test
    git -C "$repo" config user.name tester
    printf '.agents/state/\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore
    git -C "$repo" commit -qm base
    # Native host envelopes, older evidence, many events, and one giant JSONL record.
    perl -MJSON::PP -e '
      my ($host, $session, $root) = @ARGV;
      my $json = JSON::PP->new->canonical;
      sub emit { print $json->encode($_[0]), "\n" }
      if ($host eq "claude") {
        emit({type=>"system",sessionId=>$session,cwd=>$root});
      } else {
        emit({type=>"session_meta",payload=>{id=>$session,cwd=>$root}});
      }
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
    ' "$host" "$session" "$repo" > "$TEST_TRANSCRIPT_STORE/parent.jsonl"
    # A newer transcript in the same repository must not win discovery by recency.
    jq -nc --arg root "$repo" \
      '{type:"session_meta",payload:{id:"auditor-session",cwd:$root}}' \
      > "$TEST_TRANSCRIPT_STORE/newer.jsonl"
    jq -nc --arg session "$session" \
      '{type:"session_meta",payload:{id:$session,cwd:"/different/repository"}}' \
      > "$TEST_TRANSCRIPT_STORE/wrong-repo.jsonl"
    source_path="$TEST_TRANSCRIPT_STORE/parent.jsonl"
    expected="$(shasum -a 256 "$source_path" | cut -d ' ' -f 1)"
    expected_range="$(perl -MDigest::SHA -MJSON::PP -e '
      open my $file, "<:raw", $ARGV[0] or die $!;
      my ($dev, $ino) = stat($file);
      my $digest = Digest::SHA->new(256);
      my ($start, $end) = (undef, 0);
      while (my $line = <$file>) {
        $start = $end if index($line, q{"Verify the new work."}) >= 0;
        $digest->add($line) if defined $start;
        $end += length $line;
      }
      die "missing fixture boundary" unless defined $start;
      print encode_json({device_inode=>"$dev:$ino",start_byte=>$start,end_byte=>$end,
        sha256=>$digest->hexdigest});
    ' "$source_path")"
    started="$(date +%s)"
    rc=0
    if [[ "$entry" != stop ]]; then
      bookkeeping="$source_path"
      [[ "$entry" != no-source ]] || bookkeeping=-
      (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" BOXLITE_HOOK_HOST="$host" \
        TMPDIR="$state/tmp" bash "$plugin_root/.agents/hooks/audit/run-verdict-audit.sh" \
        "$bookkeeping" "$session" legacy -) > "$state/stdout" 2> "$state/stderr" || rc=$?
    else
      jq -nc --arg path "$source_path" --arg session "$session" \
        '{hook_event_name:"Stop",session_id:$session,transcript_path:$path,turn_id:"fixture-turn"}' \
        | TEST_APPEND_DURING_AUDIT=yes fixture_stop \
          > "$state/stdout" 2> "$state/stderr" || rc=$?
    fi
    finished="$(date +%s)"
    check "$host $entry completes" "$rc" 0
    validated=no
    jq -e '.valid == true' "$state/validation.out" >/dev/null 2>&1 && validated=yes
    check "$host $entry exposes working pre-delivery validation" "$validated" yes
    context=no
    if jq -e --arg host "$host" --arg session "$session" --arg root "$repo" \
        --argjson start "$started" --argjson finish "$finished" '
        (has("transcript_path") | not) and .parent_host == $host
        and .parent_session_id == $session and .repo_root == $root
        and (.audit_started_at | type == "string")
        and (.audit_started_at | tonumber) >= $start
        and (.audit_started_at | tonumber) <= $finish
      ' "$state/task" >/dev/null 2>&1; then context=yes; fi
    check "$host $entry sends parent context without a transcript path" "$context" yes
    received="$(shasum -a 256 "$state/received.jsonl" 2>/dev/null | cut -d ' ' -f 1)"
    check "$host $entry discovery retains all original evidence bytes" "$received" "$expected"
    clean=no
    [[ -z "$(find "$state/tmp" -mindepth 1 -print)" ]] && clean=yes
    check "$host $entry cleans its private bookkeeping files" "$clean" yes
    check "$host $entry does not create a full parent-selected copy" \
      "$(cat "$state/parent-copies" 2>/dev/null || printf missing)" ""
    skill=no
    grep -q '^## Read the transcript' "$state/prompt" 2>/dev/null && skill=yes
    check "$host $entry loads the audit skill's transcript procedure" "$skill" yes
    if [[ "$entry" == stop ]]; then
      history_bytes="$(wc -c < "$state/history-transcript.json" 2>/dev/null | tr -d ' ')"
      bounded=no
      if [[ "$history_bytes" =~ ^[0-9]+$ && "$history_bytes" -le 262146 ]] \
        && jq -e '.[0].type == "verdict_final_turn_snapshot"' \
          "$state/history-transcript.json" >/dev/null 2>&1; then bounded=yes; fi
      check "$host history retains a bounded bookkeeping snapshot" "$bounded" yes
      check "$host Stop accepts the bound PASS" "$(cat "$state/stdout")" ""
      scope="$(printf '%s' "$session" | git -C "$repo" hash-object --stdin)"
      index="$state/last-verdict-index.json.git-$scope"
      generation="$(jq -r .audit_generation "$state/task")"
      indexed=no
      if jq -e --arg generation "$generation" --argjson range "$expected_range" '
          .version == 1 and .generation == $generation and .turn_id == "fixture-turn"
          and (.message_id | test("^cksum-")) and .native_range == $range
        ' "$index" >/dev/null 2>&1; then indexed=yes; fi
      check "$host index keeps the accepted range across a transcript append" "$indexed" yes
      locator="$(bash "$plugin_root/scripts/read-verdict-index.sh" "$repo" "$session" "$source_path")"
      check "$host reader accepts the consumed PASS index after append" \
        "$locator" "$(jq -r .end_byte <<<"$expected_range")"
      history_range=no
      if jq -e --argjson range "$expected_range" '.[0].native_range == $range' \
          "$state/history-transcript.json" >/dev/null; then history_range=yes; fi
      check "$host auditor receives the complete latest native range" "$history_range" yes
      native_snapshot="$(jq -c '.[0]' "$state/history-transcript.json")"

      jq -nc --arg session "$session" '
        {hook_event_name:"Stop", session_id:$session, transcript_path:null,
         turn_id:"payload-turn",last_assistant_message:"Verified the payload fixture."}' \
        | fixture_stop \
          > "$state/payload-stdout" 2> "$state/payload-stderr"
      indexed=no
      if jq -e --arg old "$generation" '
          .generation != $old and .turn_id == "payload-turn" and (has("native_range") | not)
        ' "$index" >/dev/null 2>&1; then indexed=yes; fi
      check "$host payload-only PASS replaces the position without inheriting an old range" "$indexed" yes

      payload_index="$(cat "$index" 2>/dev/null)"
      jq -nc --arg session "$session" '
        {hook_event_name:"Stop",session_id:$session,transcript_path:null,
         last_assistant_message:"Which fixture should I inspect?"}' \
        | fixture_stop \
          > "$state/chat-stdout" 2> "$state/chat-stderr"
      check "$host classifier-only allow keeps the last verdict index" \
        "$(cat "$index" 2>/dev/null)" "$payload_index"

      if [[ "$host" == codex ]]; then
        if jq -c 'del(.native_range)' <<<"$native_snapshot" | normalize_snapshot >/dev/null; then
          legacy=accepted
        else
          legacy=rejected
        fi
        check "legacy snapshots need no native range" "$legacy" accepted
        if jq -c '.native_range.end_byte += 1' <<<"$native_snapshot" | normalize_snapshot >/dev/null; then
          malformed=accepted
        else
          malformed=rejected
        fi
        check "a native range cannot run past its captured source" "$malformed" rejected

        jq -nc --arg session "$session" '
          {hook_event_name:"Stop",session_id:$session,transcript_path:null,
           last_assistant_message:"Verified the failing fixture."}' \
          | TEST_AUDIT_VERDICT=FAIL fixture_stop > "$state/fail-stdout" 2> "$state/fail-stderr"
        failure="$(jq -r '.reason | contains("fixture proof gap")' "$state/fail-stdout")"
        check "fixture FAIL reaches Stop" "$failure" true
        check "FAIL preserves the prior PASS index" "$(cat "$index")" "$payload_index"

        sibling_session="${session}-sibling"
        sibling_scope="$(printf '%s' "$sibling_session" | git -C "$repo" hash-object --stdin)"
        sibling_index="$state/last-verdict-index.json.git-$sibling_scope"
        jq -nc --arg id "$sibling_session" --arg cwd "$repo" \
          '{type:"session_meta",payload:{id:$id,cwd:$cwd}}' > "$TEST_TRANSCRIPT_STORE/sibling.jsonl"
        mkdir "$sibling_index"
        jq -nc --arg session "$sibling_session" '
          {hook_event_name:"Stop",session_id:$session,transcript_path:null,
           last_assistant_message:"Verified the sibling fixture."}' \
          | fixture_stop > "$state/sibling-stdout" 2> "$state/sibling-stderr"
        check "unwritable index leaves the sibling PASS valid" "$(cat "$state/sibling-stdout")" ""
        diagnosed=no
        if [[ -d "$sibling_index" ]] && grep -Fq 'could not save the last verdict index' "$state/sibling-stderr"; then
          diagnosed=yes
        fi
        check "unwritable index reports a diagnostic and preserves the directory" "$diagnosed" yes

        rmdir "$sibling_index"
        printf '{interrupted\n' > "$sibling_index"
        jq -nc --arg session "$sibling_session" '
          {hook_event_name:"Stop",session_id:$session,transcript_path:null,
           turn_id:"unexpected\nsecond line",last_assistant_message:"Verified the second sibling fixture."}' \
          | fixture_stop > "$state/sibling-stdout" 2> "$state/sibling-stderr"
        indexed=no
        if jq -e '.version == 1 and (has("native_range") or has("turn_id") | not)' \
            "$sibling_index" >/dev/null 2>&1; then
          indexed=yes
        fi
        check "a sibling PASS replaces a broken index and drops an invalid turn ID" "$indexed" yes
        check "a sibling session cannot replace the prior index" "$(cat "$index")" "$payload_index"
      fi
    fi
  done
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
