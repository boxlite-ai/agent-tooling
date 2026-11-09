#!/usr/bin/env bash
# Tests for .agents/hooks/audit/preflight-verdict-check.sh (the Stop-stage verdict gate).
#
# The hook is DETECTION-TRIGGERED, with finding-driven loops only:
#   - no dossier + the turn asserts a verdict ("root cause is X",
#     "tests pass", "prod looks healthy", "done")      -> audit synchronously;
#                                                         PASS never reaches the model,
#                                                         FAIL blocks
#   - no dossier + chat / question / no transcript     -> allow
#   - present PASS/IN_PROGRESS, fresh + matching       -> allow (consumed)
#   - present FAIL, fresh + matching                   -> block with findings
#     (the ONE legitimate loop: persists until re-audited clean)
#   - present but stale / mismatched binding           -> DISCARD, re-detect
#     (bookkeeping never blocks — that was the meaningless-loop class)
# Each case builds a throwaway git repo with an optional fake transcript and
# dossier, runs the hook there (cwd + CLAUDE_PROJECT_DIR pointed at it), and
# asserts allow vs block.
#
# Stop contract: block = stdout {"decision":"block"}; allow = exit 0 with either
# empty stdout or {"continue":true, systemMessage:...} — the systemMessage is the
# human-only triage announcement (the model never sees it; documented hook
# contract). decide() treats any non-block output as allow.
#
# Run with:  bash tests/audit/preflight-verdict-check.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Hermetic baseline: drop any ambient VERDICT_GATE_HARD_BLOCK so absence is the
# starting point regardless of the caller's environment. Absent now means HARD, so
# every case that wants soft mode sets VERDICT_GATE_HARD_BLOCK=0 explicitly rather
# than relying on the unset — see the unset⇒block case below, which pins that.
unset VERDICT_GATE_HARD_BLOCK

# Hermetic triage: force the classifier into UNKNOWN (command fails) so every case
# below exercises the deterministic regex fallback unless a case overrides the stub.
# Without this, a machine with the `claude` CLI would call a live model mid-suite.
export VERDICT_CLASSIFIER_CMD='false'
# Its matched seam. Left ambient it replaces the text every case asserts on, so the
# suite grades a transcript it never wrote — 29/25 with `true`, 46/8 with `cat`.
unset VERDICT_EXTRACTOR_CMD

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whichever checkout the shell sits in, so running this
# suite from another worktree silently tests THAT checkout's copy instead of the
# one shipped beside these tests, and a two-side check reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/audit/preflight-verdict-check.sh"
CANCEL_HOOK="$REPO_ROOT/.agents/hooks/cancel-verdict-audit.sh"
# shellcheck source=../../.agents/lib/verdict-audit-state.sh
source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/verdict-fixtures.sh
source "$REPO_ROOT/tests/lib/verdict-fixtures.sh"

# The gate audits only session-scoped Stops. Cases that name no session run as
# DEFAULT_SESSION; its scope is a Git blob hash, identical in every fixture repository.
DEFAULT_SESSION=test-session
DEFAULT_SCOPE="git-$(printf '%s' "$DEFAULT_SESSION" | git hash-object --stdin)"
DEFAULT_GENERATION=101-102-1

dependency_bin="$(mktemp -d)"
ln -s "$(command -v bash)" "$dependency_bin/bash"
ln -s "$(command -v jq)" "$dependency_bin/jq"
missing_perl_err="$(PATH="$dependency_bin" bash "$HOOK" </dev/null 2>&1)"
missing_perl_rc=$?
if [[ "$missing_perl_rc" == 2 \
   && "$missing_perl_err" == *"required dependency not found: perl"* ]]; then
  ok "missing Perl fails closed with an actionable Stop-hook error"
else
  badf "missing Perl fails closed with an actionable Stop-hook error" 'rc=%s err=%s' "$missing_perl_rc" "$missing_perl_err"
fi
rm -rf "$dependency_bin"

# Fresh git repo with one committed production file.
setup() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  mkdir -p "$d/src"
  printf 'pub fn base() {}\n' > "$d/src/lib.rs"
  # Mirror the real repo, which ignores the whole state dir: gate-written state must
  # never enter the working-tree hash, or `git add -A` folds it into the very hash the
  # dossier is keyed to and self-invalidates a just-passed audit. Ignoring the
  # directory (not one file) keeps this true for every marker the gates write —
  # last-verdict.prev.json, verdict-last-uuid, verdict-decisions.log.
  printf '.agents/state/\nCLASSIFIER_RAN\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}

# Fake session transcript whose LAST assistant message is $2 (prior assistant
# messages may follow as $3..; they are written first). Mirrors the real JSONL
# shape: {"type":"assistant","uuid":..., "message":{"content":[{"type":"text",...}]}}.
# The last message gets uuid "uuid-last", earlier ones "uuid-<n>".
write_transcript() {
  local repo="$1" last="$2"; shift 2
  : > "$repo/transcript.jsonl"
  local earlier n=0
  for earlier in "$@"; do
    n=$((n+1))
    jq -nc --arg t "$earlier" --arg u "uuid-$n" \
      '{type:"assistant", uuid:$u, message:{content:[{type:"text",text:$t}]}}' >> "$repo/transcript.jsonl"
  done
  jq -nc --arg t "$last" --arg u "uuid-last" \
    '{type:"assistant", uuid:$u, message:{content:[{type:"text",text:$t}]}}' >> "$repo/transcript.jsonl"
}

# Codex-format transcript (rollout JSONL): response_item / payload.role=assistant /
# content[].output_text, no per-record id. Same last-message-wins semantics.
write_codex_transcript() {
  local repo="$1" last="$2"
  jq -nc --arg t "$last" \
    '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:$t}]}}' \
    > "$repo/transcript.jsonl"
}

# An INVENTED schema no harness uses today — proves new agents work with zero hook
# changes as long as they follow the conventions (role=assistant somewhere, text
# under `text` keys in *text-typed blocks, JSONL).
write_future_agent_transcript() {
  local repo="$1" last="$2"
  jq -nc --arg t "$last" \
    '{kind:"turn", actor:{role:"assistant"}, output:{parts:[{type:"rich_text", text:$t}]}}' \
    > "$repo/transcript.jsonl"
}

# The content-derived message identity the hook records (keep formula in sync).
cksum_of() { printf 'cksum-%s' "$(printf '%s' "$1" | cksum | tr ' \t' '--')"; }

# Append records to an existing fixture transcript: a REAL user message (turn
# boundary) or a further assistant text (same turn as its neighbors).
append_user() {
  jq -nc --arg t "$2" '{type:"user", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
append_assistant() {
  jq -nc --arg t "$2" '{type:"assistant", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
# Tool results ride user-role records. The array shape (produced by Read, Agent,
# ToolSearch, MCP tools) nests text-typed blocks INSIDE the tool_result — it must
# NOT read as a turn boundary.
append_tool_result_array() {
  jq -nc --arg t "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:[{type:"text", text:$t}]}]}}' \
    >> "$1/transcript.jsonl"
}
append_tool_result_string() {
  jq -nc --arg t "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:$t}]}}' \
    >> "$1/transcript.jsonl"
}
append_tool_result_object() {
  jq -nc --argjson value "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:$value}]}}' \
    >> "$1/transcript.jsonl"
}
append_root_tool_record_object() {
  jq -nc --argjson value "$2" \
    '{type:"tool_result", tool_use_id:"tu1", message:$value}' \
    >> "$1/transcript.jsonl"
}

# The message identity the hook binds a request to: every assistant text after the last
# real user record of transcript.jsonl (an independent copy of the hook's extraction).
final_id_of() {  # repo
  local text
  text="$(jq -rs '
    def is_assistant: [.. | objects | select((.role? == "assistant") or (.type? == "assistant"))] | length > 0;
    def is_real_user:
      ((.type? == "user") and
        ((.message.content? | type) == "string"
         or ([.message.content[]? | select((.type? // "") == "text")] | length) > 0))
      or ([.. | objects | select((.role? // "") == "user")
           | [.content[]? | select((.type? // "" | tostring) | test("text"))] | length]
          | any(. > 0));
    . as $r
    | ([$r[] | is_real_user] | rindex(true)) as $lastu
    | $r[(if $lastu == null then 0 else $lastu + 1 end):]
    | [.[] | select(is_assistant) | (
        ([.. | objects | select((.type? // "" | tostring) | test("text")) | .text? // empty | strings] | join("\n")) as $typed
        | (if ($typed | length) > 0 then $typed
           else ([.. | objects | .text? // empty | strings] | join("\n")) end)
      ) | select(length > 0)]
    | join("\n\n")' "$1/transcript.jsonl" 2>/dev/null)" || text=""
  cksum_of "$text"
}

# Write the default session's dossier and the current request it answers; tree_hash
# defaults to the repo's current working-tree hash.
write_verdict() {
  local repo="$1" verdict="$2" findings="$3" tree="${4:-$(tree_hash_of "$1")}"
  local br hd; br="$(git -C "$repo" branch --show-current)"; hd="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$repo/.agents/state"
  jq -nc --arg b "$br" --arg h "$hd" --arg t "$tree" --arg v "$verdict" --argjson f "$findings" \
    --arg g "$DEFAULT_GENERATION" \
    '{branch:$b, head:$h, tree_hash:$t, generation:$g, verdict:$v, proof:[], findings:$f}' \
    > "$repo/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
  write_session_request "$repo" "$DEFAULT_SESSION" "$DEFAULT_GENERATION" "$(final_id_of "$repo")"
}

# A real runner seam, not a prebuilt dossier: the Stop hook must invoke this command,
# wait for the independently produced PASS, consume it, and return no host output.
AUDITOR_STUB='audit_prompt="$(cat)"
mkdir -p "$CLAUDE_PROJECT_DIR/.agents/state"
printf "%s" "$audit_prompt" > "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_PROMPT"
task_input_json="$(printf "%s\n" "$audit_prompt" \
  | sed -n "/^UNTRUSTED_TASK_INPUT_JSON:$/ { n; p; q; }")"
printf "%s\n" "$task_input_json" \
  > "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_TASK_INPUT"
previous_path="$(printf "%s" "$task_input_json" \
  | jq -r ".previous_dossier_path // empty")"
history_path="$(printf "%s" "$task_input_json" \
  | jq -r ".history_path // empty")"
if [[ -n "$previous_path" && -r "$previous_path" ]]; then
  cp "$previous_path" "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_PREVIOUS"
fi
if [[ -n "$history_path" && -r "$history_path" ]]; then
  jq '\''.attempts[-1].input.snapshot.transcript[0]'\'' "$history_path" \
    > "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_TRANSCRIPT"
fi
touch "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_RAN"
printf "run\\n" >> "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_RUNS"
idx="$(mktemp)"
GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" read-tree HEAD >/dev/null 2>&1
GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" add -A >/dev/null 2>&1
tree="$(GIT_INDEX_FILE="$idx" git -C "$CLAUDE_PROJECT_DIR" write-tree 2>/dev/null)"
rm -f "$idx"
verdict="${TEST_AUDIT_VERDICT:-FAIL}"
findings='\''["independent audit finding"]'\''
[[ "$verdict" == PASS ]] && findings='\''[]'\''
jq -nc \
  --arg branch "$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current)" \
  --arg head "$(git -C "$CLAUDE_PROJECT_DIR" rev-parse HEAD)" \
  --arg tree "$tree" \
  --arg generation "$VERDICT_AUDITOR_GENERATION" \
  --arg verdict "$verdict" \
  --argjson findings "$findings" \
  --arg advisories "${TEST_AUDIT_ADVISORIES:-}" \
  '\''{branch:$branch,head:$head,tree_hash:$tree,generation:$generation,
     verdict:$verdict,proof:[],findings:$findings}
   + (if $advisories == "" then {} else {advisories:($advisories | fromjson)} end)'\'' \
  > "$VERDICT_AUDITOR_OUTPUT_FILE"
bash "$TEST_HISTORY_RESULT_HELPER" "$task_input_json" "$VERDICT_AUDITOR_OUTPUT_FILE"'
export TEST_HISTORY_RESULT_HELPER="$REPO_ROOT/tests/audit/fixtures/audit-history-result.sh"
export VERDICT_AUDITOR_CMD="$AUDITOR_STUB"
export TEST_AUDIT_VERDICT=FAIL

# Run the hook inside repo for an exact Stop payload.
run_payload_hook() {
  local repo="$1" payload="$2" scoped
  scoped="$(jq -ce --arg s "$DEFAULT_SESSION" 'if has("session_id") then . else . + {session_id:$s} end' \
    <<<"$payload" 2>/dev/null)" && payload="$scoped"
  # Decision-logic cases run in HARD mode so a block condition is observable as
  # decision:block. Soft mode is covered in its own section below.
  printf '%s' "$payload" \
    | ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) \
      2>/dev/null
}

decision_from_output() {
  local out="$1" d
  if [[ -z "$out" ]]; then
    printf 'allow'
  else
    d="$(printf '%s' "$out" | jq -r '.decision // "allow"' 2>/dev/null || echo parse_error)"
    [[ "$d" == "block" ]] && printf 'block' || printf 'allow'
  fi
}

decide_payload() {
  local repo="$1" payload="$2" out
  out="$(run_payload_hook "$repo" "$payload")"
  decision_from_output "$out"
}

# Uses the repo's fake transcript when present, /dev/null otherwise.
decide() {
  local repo="$1" tp="/dev/null" payload
  [[ -f "$repo/transcript.jsonl" ]] && tp="$repo/transcript.jsonl"
  payload="$(jq -nc --arg p "$tp" --arg s "$DEFAULT_SESSION" \
    '{transcript_path:$p, hook_event_name:"Stop", session_id:$s}')"
  decide_payload "$repo" "$payload"
}

check() {  # desc  repo  expect
  check_eq "$1" "$(decide "$2")" "$3"
}

# Assert the dossier file is gone (consumed on allow, or discarded on mismatch).
check_gone() {  # desc  repo
  local desc="$1" repo="$2"
  if [[ ! -e "$repo/.agents/state/last-verdict.json.$DEFAULT_SCOPE" ]]; then
    ok "$desc"
  else
    bad "$desc" 'dossier still present'
  fi
}

# Assert the written dossier is gone: absent, or replaced by a fresh audit's generation.
check_stale_gone() {  # desc  repo
  local desc="$1" generation
  generation="$(jq -r '.generation // empty' "$2/.agents/state/last-verdict.json.$DEFAULT_SCOPE" 2>/dev/null)"
  if [[ "$generation" != "$DEFAULT_GENERATION" ]]; then
    ok "$desc"
  else
    bad "$desc" 'stale dossier still present'
  fi
}

# A classifier stub that RECORDS its own invocation. Tiers A and B are latency work,
# so what has to be asserted is that the 5-10s round-trip was genuinely SKIPPED — not
# merely that its answer agreed. The stub also answers the OPPOSITE of the tier under
# test, so a run without the tier reaches the model and lands on the wrong decision.
# (Same property the in-flight rung needs: it sits ahead of triage.)
cls_stub()      { printf "while IFS= read -r _line; do :; done; : > '%s/CLASSIFIER_RAN'; printf '%s\\n'" "$1" "$2"; }
classifier_ran() { [[ -e "$1/CLASSIFIER_RAN" ]] && echo yes || echo no; }
run_hook() {  # repo  classifier-answer
  jq -nc --arg p "$1/transcript.jsonl" --arg s "$DEFAULT_SESSION" \
    '{transcript_path:$p, hook_event_name:"Stop", session_id:$s}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$2")" bash "$HOOK" ) 2>/dev/null
}

write_session_request() {  # repo session generation final-id
  local path epoch; path="$(session_state_path "$1" verdict-request "$2")"
  mkdir -p "$(dirname "$path")"
  printf '%s %s %s\n' "$3" "$(( $(date +%s) + 600 ))" "$4" > "$path"
  epoch="$(cat "$(session_state_path "$1" verdict-prompt-epoch "$2")" 2>/dev/null || true)"
  [[ -n "$epoch" ]] || epoch=-
  jq -nc --arg request "$(cat "$path")" --arg epoch "$epoch" \
    --arg branch "$(git -C "$1" branch --show-current)" --arg head "$(git -C "$1" rev-parse HEAD)" \
    --arg tree "$(tree_hash_of "$1")" \
    '{request:$request,origin_epoch:$epoch,branch:$branch,head:$head,tree_hash:$tree}' \
    > "$(session_state_path "$1" verdict-request-context.json "$2")"
}
run_session_hook() {  # repo session classifier-answer
  jq -nc --arg p "$1/transcript.jsonl" --arg s "$2" \
    '{transcript_path:$p, hook_event_name:"Stop", session_id:$s}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$3")" bash "$HOOK" ) 2>/dev/null
}

prompt_hook() {  # repo session turn
  jq -nc --arg s "$2" --arg t "$3" --arg p "new user input" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,turn_id:$t,prompt:$p}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$CANCEL_HOOK" )
}

write_quarantine_barrier_env() {  # repo
  cat > "$1/.agents/state/quarantine-barrier-env.sh" <<'QUARANTINE_BARRIER_ENV'
if [[ -z "${VERDICT_QUARANTINE_OWNER_PID:-}" ]]; then
  export VERDICT_QUARANTINE_OWNER_PID="$$"
  verdict_quarantine_debug() {
    [[ "$$" == "$VERDICT_QUARANTINE_OWNER_PID" ]] || return 0
    if [[ "$BASH_COMMAND" == dossier_file_snapshot=* \
       && -n "${dossier_quarantine:-}" \
       && ! -e "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-ready" ]]; then
      trap - DEBUG
      printf '%s\n' "${decision_lease_pid:-0}" \
        > "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-decision-holder-pid"
      touch "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-ready"
      while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-release" ]]; do
        sleep 0.01
      done
    fi
  }
  set -T
  trap verdict_quarantine_debug DEBUG
fi
QUARANTINE_BARRIER_ENV
}

write_epoch_barrier_env() {  # repo
  mkdir -p "$1/.agents/state"
  cat > "$1/.agents/state/epoch-barrier-env.sh" <<'EPOCH_BARRIER_ENV'
if [[ -z "${VERDICT_EPOCH_BARRIER_OWNER_PID:-}" ]]; then
  export VERDICT_EPOCH_BARRIER_OWNER_PID="$$"
  verdict_epoch_barrier_debug() {
    [[ "$$" == "$VERDICT_EPOCH_BARRIER_OWNER_PID" ]] || return 0
    local should_pause=false
    case "${VERDICT_EPOCH_BARRIER_MODE:-}" in
      live-fail)
        [[ "${v_verdict:-}" == FAIL \
           && "${verdict_json:-}" == *"epoch live finding"* \
           && -n "${dossier_quarantine:-}" \
           && -e "$dossier_quarantine" ]] && should_pause=true
        ;;
      stale-fail)
        [[ "$BASH_COMMAND" == prompt_epoch_is_current \
           && "${v_verdict:-}" == FAIL \
           && -n "${verdict_request_file:-}" \
           && ! -e "$verdict_request_file" ]] && should_pause=true
        ;;
      prev-restore)
        [[ "$BASH_COMMAND" == prompt_epoch_is_current \
           && -n "${parked_quarantine:-}" \
           && -e "$parked_quarantine" ]] && should_pause=true
        ;;
      prev-replacement)
        [[ "$BASH_COMMAND" == verdict_audit_unlink_if_identity* \
           && -n "${parked_quarantine:-}" \
           && -e "$parked_quarantine" ]] && should_pause=true
        ;;
      last-uuid-post-write)
        [[ "$BASH_COMMAND" == *prompt_epoch_is_current* \
           && -n "${last_uuid_file:-}" \
           && "${had_prior:-false}" == true \
           && -e "$last_uuid_file" ]] && should_pause=true
        ;;
      invalid-request-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && -n "${invalid_request:-}" ]] && should_pause=true
        ;;
      discard-dossier-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_no_clobber_exact* \
           && "${stable_path:-}" == "${verdict_file:-}" \
           && "${selected_path:-}" == *.unlink-* ]] && should_pause=true
        ;;
      prev-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && -n "${parked_quarantine:-}" ]] && should_pause=true
        ;;
      dossier-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_no_clobber_exact* \
           && "${dossier_quarantine:-}" == *.inspect-* ]] && should_pause=true
        ;;
      park-publish)
        [[ "$BASH_COMMAND" == *verdict_audit_link_no_clobber* \
           && "${dossier_quarantine:-}" == *.inspect-* \
           && -n "${prev_verdict_file:-}" ]] && should_pause=true
        ;;
    esac
    [[ "$should_pause" == true ]] || return 0
    trap - DEBUG
    touch "$CLAUDE_PROJECT_DIR/.agents/state/epoch-barrier-ready"
    if [[ "${VERDICT_EPOCH_BARRIER_MODE:-}" == prev-replacement ]]; then
      printf '%s\n' '{"verdict":"FAIL","findings":["fresh replacement finding"]}' \
        > "$prev_verdict_file"
      return 0
    fi
    while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/epoch-barrier-release" ]]; do
      sleep 0.01
    done
  }
  set -T
  trap verdict_epoch_barrier_debug DEBUG
fi
EPOCH_BARRIER_ENV
}

# ── Real-repo invariant: every gate-written .agents/state/ file is gitignored ──
# compute_tree_hash() folds the whole working tree into the dossier binding via
# `git add -A`, which SKIPS gitignored paths. So every file the gates write under
# .agents/state/ MUST be gitignored — otherwise writing it perturbs the very tree
# hash the dossier is keyed to and self-invalidates a just-passed audit (the
# class of bug that hit pr-reviewed.json: a fresh PASS discarded as "stale" the
# instant the PR-review ack was written). setup() emulates this per synthetic
# repo (only last-verdict.json); this case guards the REAL .gitignore for the
# whole class, so a new marker added without a matching ignore line fails here.
echo "## Invariant: gate state files are gitignored (never enter the tree hash)"
for f in \
  .agents/state/last-audit.json \
  .agents/state/last-verdict.json \
  .agents/state/last-verdict.prev.json \
  .agents/state/pr-reviewed.json \
  .agents/state/verdict-last-uuid \
  .agents/state/verdict-stop-message.jsonl \
  .agents/state/verdict-prompt-epoch \
  .agents/state/verdict-audit.lock \
  .agents/state/verdict-audit.lock.mutex \
  .agents/state/verdict-request.publish.mutex \
  .agents/state/verdict-decisions.log; do
  if git -C "$REPO_ROOT" check-ignore -q "$f"; then
    ok "$f gitignored"
  else
    badf "$f gitignored" '%s NOT gitignored → would perturb compute_tree_hash' "$f"
  fi
done

echo
echo "## Detection: no dossier → the turn text decides"
R="$(setup)"; write_transcript "$R" "The root cause is a race between gvproxy startup and the socket bind."
check "'root cause is X' → block (verdict asserted, unaudited)"   "$R" "block"; rm -rf "$R"

R="$(setup)"
mkfifo "$R/transcript.fifo"
fifo_payload="$(jq -nc --arg p "$R/transcript.fifo" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}')"
fifo_out="$(printf '%s' "$fifo_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 perl -e 'alarm 3; exec @ARGV' bash "$HOOK") 2>/dev/null)"
fifo_rc=$?
fifo_runs="$(wc -l < "$R/.agents/state/SYNC_AUDIT_RUNS" 2>/dev/null | tr -d ' ')"
fifo_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out") runs=${fifo_runs:-0}"
check_eq "FIFO transcript fails closed without blocking the hook" "$fifo_state" "rc=0 decision=block runs=1"
rm -rf "$R"

R="$(setup)"
perl -e '
  print qq|{"type":"assistant","message":{"content":[{"type":"text","text":"|;
  print "OLD_HISTORY_" x 700000;
  print qq|"}]}}\n|;
  print qq|{"type":"user","message":{"content":[{"type":"text","text":"new request"}]}}\n|;
  print qq|{"type":"assistant","message":{"content":[{"type":"text","text":"The root cause is FINAL_SMALL"}]}}\n|;
  print qq|{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"TOOL_EVIDENCE"}]}}\n|;
' > "$R/transcript.jsonl"
history_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop",session_id:"history-session"}')"
history_out="$(run_payload_hook "$R" "$history_payload")"
history_snapshot="$R/.agents/state/SYNC_AUDIT_TRANSCRIPT"
history_task_input="$R/.agents/state/SYNC_AUDIT_TASK_INPUT"
history_bounded=no
if [[ -f "$history_snapshot" && "$(wc -c < "$history_snapshot")" -lt 262144 ]] \
   && jq -e '.type == "verdict_final_turn_snapshot"' "$history_snapshot" >/dev/null; then
  history_bounded=yes
fi
history_context="$(jq -r '(has("transcript_path") | not) and
  .parent_session_id == "history-session"' "$history_task_input" 2>/dev/null || true)"
history_snapshot_state="decision=$(decision_from_output "$history_out")"
history_snapshot_state="$history_snapshot_state bounded=$history_bounded"
history_snapshot_state="$history_snapshot_state final=$(grep -q 'FINAL_SMALL' "$history_snapshot" 2>/dev/null && echo yes || echo no)"
history_snapshot_state="$history_snapshot_state tool=$(grep -q 'TOOL_EVIDENCE' "$history_snapshot" 2>/dev/null && echo yes || echo no)"
history_snapshot_state="$history_snapshot_state old=$(grep -q 'OLD_HISTORY_' "$history_snapshot" 2>/dev/null && echo yes || echo no)"
history_snapshot_state="$history_snapshot_state context=$history_context"
check_eq "synchronous route separates bounded history from transcript discovery" "$history_snapshot_state" "decision=block bounded=yes final=yes tool=yes old=no context=true"
rm -rf "$R"

R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
silent_pass_out="$(export TEST_AUDIT_VERDICT=PASS; run_payload_hook "$R" "$payload")"
if [[ -z "$silent_pass_out" \
   && -e "$R/.agents/state/SYNC_AUDIT_RAN" \
   && ! -e "$(session_state_path "$R" last-verdict.json session-a)" \
   && ! -e "$(session_state_path "$R" verdict-request session-a)" ]]; then
  ok "successful synchronous audit is silent and consumed"
else
  badf "successful synchronous audit is silent and consumed" 'out=%s ran=%s' "${silent_pass_out:-EMPTY}" \
    "$([[ -e "$R/.agents/state/SYNC_AUDIT_RAN" ]] && echo yes || echo no)"
fi
rm -rf "$R"

# Advisories are the auditor's non-blocking channel. A PASS that carries them still ends
# the turn and is consumed; the human sees them in a model-invisible systemMessage, and
# nothing asks the agent to revise.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
advisory_pass_out="$(export TEST_AUDIT_VERDICT=PASS \
  TEST_AUDIT_ADVISORIES='["socket.rs:59 is cited; the call is on :60"]'
  run_payload_hook "$R" "$payload")"
advisory_pass_note="$(printf '%s' "$advisory_pass_out" | jq -r '.systemMessage // ""' 2>/dev/null)"
advisory_pass_keys="$(printf '%s' "$advisory_pass_out" | jq -c 'keys' 2>/dev/null)"
if [[ "$advisory_pass_keys" == '["continue","systemMessage"]' \
   && "$advisory_pass_note" == *"socket.rs:59 is cited; the call is on :60"* \
   && ! -e "$(session_state_path "$R" last-verdict.json session-a)" \
   && ! -e "$(session_state_path "$R" verdict-request session-a)" ]]; then
  ok "PASS advisories end the turn and reach only the human"
else
  badf "PASS advisories end the turn and reach only the human" 'out=%s' "${advisory_pass_out:-EMPTY}"
fi
rm -rf "$R"

# A FAIL blocks on its findings alone. Its advisories stay out of the model-facing reason,
# so the revision addresses what blocked and nothing else.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
advisory_fail_out="$(export TEST_AUDIT_VERDICT=FAIL \
  TEST_AUDIT_ADVISORIES='["wording could be tighter"]'
  run_payload_hook "$R" "$payload")"
advisory_fail_reason="$(printf '%s' "$advisory_fail_out" | jq -r '.reason // ""' 2>/dev/null)"
if [[ "$(decision_from_output "$advisory_fail_out")" == block \
   && "$advisory_fail_reason" == *"independent audit finding"* \
   && "$advisory_fail_reason" != *"wording could be tighter"* ]]; then
  ok "FAIL blocks on findings and keeps advisories out of the reason"
else
  badf "FAIL blocks on findings and keeps advisories out of the reason" 'out=%s' "${advisory_fail_out:-EMPTY}"
fi
rm -rf "$R"

# Advisories are validated like findings: a PASS whose advisories are not a list of lines
# is not a dossier, so the audit fails closed rather than passing.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
malformed_advisory_out="$(export TEST_AUDIT_VERDICT=PASS TEST_AUDIT_ADVISORIES='"not a list"'
  run_payload_hook "$R" "$payload")"
malformed_advisory_reason="$(printf '%s' "$malformed_advisory_out" | jq -r '.reason // ""' 2>/dev/null)"
if [[ "$(decision_from_output "$malformed_advisory_out")" == block \
   && "$malformed_advisory_reason" == *"did not produce a valid dossier"* ]]; then
  ok "malformed advisories fail the audit closed"
else
  badf "malformed advisories fail the audit closed" 'out=%s' "${malformed_advisory_out:-EMPTY}"
fi
rm -rf "$R"

# Runner absence fails closed with one concise recovery message, not the routing prompt
# the old model-driven flow exposed. CODEX_BIN pins an invalid explicit candidate so an
# installed desktop app cannot make this hermetic no-runner case launch a real model.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
no_runner_out="$(printf '%s' "$payload" \
  | ( cd "$R" && env -u VERDICT_AUDITOR_CMD CLAUDE_PROJECT_DIR="$R" \
      CODEX_BIN=/nonexistent PATH=/opt/homebrew/bin:/usr/bin:/bin \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
no_runner_reason="$(printf '%s' "$no_runner_out" | jq -r '.reason // ""')"
no_runner_retry_out="$(printf '%s' "$payload" \
  | ( cd "$R" && env -u VERDICT_AUDITOR_CMD CLAUDE_PROJECT_DIR="$R" \
      CODEX_BIN=/nonexistent PATH=/opt/homebrew/bin:/usr/bin:/bin \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
if [[ "$(decision_from_output "$no_runner_out")" == block \
   && "$(decision_from_output "$no_runner_retry_out")" == block \
   && "$no_runner_reason" == *"auditor could not launch"* \
   && "$no_runner_reason" != *"collaboration.spawn_agent"* \
   && "$no_runner_reason" != *"Task("* \
   && ! -e "$(session_state_path "$R" verdict-last-uuid session-a)" ]]; then
  ok "unavailable synchronous auditor fails closed on every retry"
else
  badf "unavailable synchronous auditor fails closed on every retry" 'first=%s retry=%s reason=%s' \
    "$(decision_from_output "$no_runner_out")" \
    "$(decision_from_output "$no_runner_retry_out")" "$no_runner_reason"
fi
rm -rf "$R"

# A user steer after a tree change revokes the generation while Stop is waiting.
# The old Stop must return silently after cancellation, never block the new prompt.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
SLOW_AUDITOR_STUB='cat >/dev/null
mkdir -p "$CLAUDE_PROJECT_DIR/.agents/state"
touch "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_WAITING"
sleep 300'
( printf '%s' "$payload" \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD=false VERDICT_AUDITOR_CMD="$SLOW_AUDITOR_STUB" bash "$HOOK" ) \
        >"$R/steered-stop.out" 2>"$R/steered-stop.err" ) & steered_stop_job=$!
for (( poll_index=0; poll_index<300; poll_index++ )); do
  [[ -e "$R/.agents/state/SYNC_AUDIT_WAITING" ]] && break
  sleep 0.01
done
printf 'changed while the audit was running\n' > "$R/changed-production"
prompt_hook "$R" session-a turn-b >/dev/null 2>&1
for (( poll_index=0; poll_index<500; poll_index++ )); do
  kill -0 "$steered_stop_job" 2>/dev/null || break
  sleep 0.01
done
steered_bounded=yes
if kill -0 "$steered_stop_job" 2>/dev/null; then
  steered_bounded=no
  kill -TERM "$steered_stop_job" 2>/dev/null || true
fi
wait "$steered_stop_job" 2>/dev/null; steered_stop_rc=$?
steered_stop_out="$(cat "$R/steered-stop.out" 2>/dev/null || true)"
if [[ "$steered_bounded" == yes && "$steered_stop_rc" == 0 && -z "$steered_stop_out" ]]; then
  ok "user steer cancels synchronous audit and releases the old Stop silently"
else
  badf "user steer cancels synchronous audit and releases the old Stop silently" 'bounded=%s rc=%s out=%s' "$steered_bounded" \
    "$steered_stop_rc" "${steered_stop_out:-EMPTY}"
fi
rm -rf "$R"

# A prompt can land after the runner commits PASS but before the parent starts its
# validator re-entry. The child must remain bound to the old epoch; otherwise it adopts
# the new prompt epoch and audits the abandoned answer a second time.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
cat > "$R/reentry-gap-env.sh" <<'REENTRY_GAP_ENV'
if [[ -z "${VERDICT_REENTRY_GAP_OWNER_PID:-}" ]]; then
  export VERDICT_REENTRY_GAP_OWNER_PID="$$"
  verdict_reentry_gap_debug() {
    [[ "$$" == "$VERDICT_REENTRY_GAP_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == 'printf '\''%s'\'' "$raw_payload"' \
       && -e "$CLAUDE_PROJECT_DIR/.agents/state/SYNC_AUDIT_RAN" \
       && ! -e "$CLAUDE_PROJECT_DIR/.agents/state/reentry-gap-ready" ]] || return 0
    trap - DEBUG
    touch "$CLAUDE_PROJECT_DIR/.agents/state/reentry-gap-ready"
    while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/reentry-gap-release" ]]; do
      sleep 0.01
    done
  }
  set -T
  trap verdict_reentry_gap_debug DEBUG
fi
REENTRY_GAP_ENV
( printf '%s' "$payload" \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
        TEST_AUDIT_VERDICT=PASS VERDICT_CLASSIFIER_CMD=false \
        BASH_ENV="$R/reentry-gap-env.sh" bash "$HOOK" ) \
        >"$R/reentry-gap.out" 2>"$R/reentry-gap.err" ) & reentry_gap_job=$!
for (( poll_index=0; poll_index<300; poll_index++ )); do
  [[ -e "$R/.agents/state/reentry-gap-ready" ]] && break
  sleep 0.01
done
prompt_hook "$R" session-a turn-b >/dev/null 2>&1
( sleep 8
  touch "$R/reentry-gap-watchdog-hit"
  kill_test_pids KILL "$reentry_gap_job"
) & reentry_gap_watchdog=$!
touch "$R/.agents/state/reentry-gap-release"
wait "$reentry_gap_job" 2>/dev/null; reentry_gap_rc=$?
kill "$reentry_gap_watchdog" 2>/dev/null || true
wait "$reentry_gap_watchdog" 2>/dev/null || true
reentry_gap_runs="$(wc -l < "$R/.agents/state/SYNC_AUDIT_RUNS" 2>/dev/null | tr -d ' ')"
reentry_gap_out="$(cat "$R/reentry-gap.out" 2>/dev/null || true)"
if [[ -e "$R/.agents/state/reentry-gap-ready" \
   && "$reentry_gap_rc" == 0 \
   && "$reentry_gap_runs" == 1 \
   && ! -e "$R/reentry-gap-watchdog-hit" \
   && -z "$reentry_gap_out" ]]; then
  ok "post-audit prompt releases validator re-entry without a second audit"
else
  badf "post-audit prompt releases validator re-entry without a second audit" 'ready=%s rc=%s runs=%s watchdog=%s out=%s' \
    "$([[ -e "$R/.agents/state/reentry-gap-ready" ]] && echo yes || echo no)" \
    "$reentry_gap_rc" "${reentry_gap_runs:-0}" \
    "$([[ -e "$R/reentry-gap-watchdog-hit" ]] && echo hit || echo quiet)" \
    "${reentry_gap_out:-EMPTY}"
fi
rm -rf "$R"

# A failed synchronous audit may block, but its host-visible reason contains only the
# findings and the next action — never the auditor routing/control document.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
out="$(run_payload_hook "$R" "$payload")"
fail_reason="$(printf '%s' "$out" | jq -r '.reason // ""')"
fail_runs="$(wc -l < "$R/.agents/state/SYNC_AUDIT_RUNS" 2>/dev/null | tr -d ' ')"
if [[ "$(decision_from_output "$out")" == block \
   && "$fail_reason" == *"independent audit finding"* \
   && "$fail_reason" == *"re-audit the revised answer automatically"* \
   && "$fail_reason" != *"collaboration.spawn_agent"* \
   && "$fail_reason" != *"Task("* \
   && "$fail_reason" != *"run-verdict-audit.sh"* \
   && "$fail_runs" == 1 ]]; then
  ok "failed synchronous audit exposes only concise findings"
else
  badf "failed synchronous audit exposes only concise findings" 'reason=%s runs=%s' "$fail_reason" "${fail_runs:-0}"
fi

# The same blocked message reuses its retained FAIL; a revised message receives one
# new audit. This is the finding-driven loop without paying repeatedly for unchanged text.
unchanged_out="$(run_payload_hook "$R" "$payload")"
unchanged_runs="$(wc -l < "$R/.agents/state/SYNC_AUDIT_RUNS" 2>/dev/null | tr -d ' ')"
append_assistant "$R" "The corrected conclusion addresses the independent audit finding."
revised_out="$(run_payload_hook "$R" "$payload")"
revised_runs="$(wc -l < "$R/.agents/state/SYNC_AUDIT_RUNS" 2>/dev/null | tr -d ' ')"
if [[ "$(decision_from_output "$unchanged_out")" == block \
   && "$(decision_from_output "$revised_out")" == block \
   && "$unchanged_runs" == 1 \
   && "$revised_runs" == 2 ]]; then
  ok "unchanged FAIL is retained; revised answer is re-audited once"
else
  badf "unchanged FAIL is retained; revised answer is re-audited once" 'unchanged=%s/%s revised=%s/%s' \
    "$(decision_from_output "$unchanged_out")" "${unchanged_runs:-0}" \
    "$(decision_from_output "$revised_out")" "${revised_runs:-0}"
fi
rm -rf "$R"

# Parse one hook event once. A Stop without a non-empty string session_id cannot be
# audited, so it blocks with a reason naming the field; a concatenated JSON stream is
# rejected. Neither may consume a session's dossier.
for malformed_payload_kind in numeric-session missing-session multiple-documents; do
  R="$(setup)"; write_transcript "$R" "The fix works and 12/12 tests pass."
  write_verdict "$R" PASS '[]'
  case "$malformed_payload_kind" in
    numeric-session)
      malformed_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
        '{transcript_path:$p,hook_event_name:"Stop",session_id:7}')"
      malformed_payload_want="rc=0 decision=block reason=named dossier=present"
      ;;
    missing-session)
      malformed_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
        '{transcript_path:$p,hook_event_name:"Stop"}')"
      malformed_payload_want="rc=0 decision=block reason=named dossier=present"
      ;;
    *)
      malformed_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s "$DEFAULT_SESSION" \
        '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')$(jq -nc '{hook_event_name:"Stop"}')"
      malformed_payload_want="rc=1 decision=allow reason=absent dossier=present"
      ;;
  esac
  printf '%s' "$malformed_payload" \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) \
      >"$R/malformed-payload.out" 2>"$R/malformed-payload.err"
  malformed_payload_rc=$?
  malformed_payload_reason=absent
  if jq -e '.reason | contains("session_id")' "$R/malformed-payload.out" >/dev/null 2>&1 \
     && grep -q 'no non-empty session_id' "$R/malformed-payload.err"; then
    malformed_payload_reason=named
  fi
  malformed_payload_state="rc=$malformed_payload_rc decision=$(decision_from_output "$(cat "$R/malformed-payload.out")") reason=$malformed_payload_reason dossier=$([[ -e "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" ]] && echo present || echo gone)"
  if [[ "$malformed_payload_state" == "$malformed_payload_want" ]]; then
    ok "$malformed_payload_kind fails closed before state selection"
  else
    badf "$malformed_payload_kind fails closed before state selection" 'got=%s want=%s' "$malformed_payload_state" "$malformed_payload_want"
  fi
  rm -rf "$R"
done

# A cancellation marker cannot be consumed before its exact request is retired. Force the
# first request rename to fail: the marker must remain visible, and ensure() must reject the
# canceled generation rather than handing its native handle back to the agent.
R="$(setup)"; claim="The root cause is the stale socket path."; write_transcript "$R" "$claim"
canceled_generation="303-304-5"
write_session_request "$R" session-a "$canceled_generation" "$(cksum_of "$claim")"
canceled_request_path="$(session_state_path "$R" verdict-request session-a)"
canceled_marker="$(session_state_path "$R" verdict-canceled session-a).$canceled_generation"
printf 'canceled\n' > "$canceled_marker"
cat > "$R/canceled-consume-env.sh" <<'CANCELED_CONSUME_ENV'
if [[ -z "${VERDICT_CANCELED_CONSUME_OWNER_PID:-}" ]]; then
  export VERDICT_CANCELED_CONSUME_OWNER_PID="$$"
  verdict_canceled_consume_debug() {
    [[ "$$" == "$VERDICT_CANCELED_CONSUME_OWNER_PID" ]] || return 0
    [[ "${VERDICT_CANCELED_CONSUME_SEEN:-false}" == false ]] || return 0
    case "$BASH_COMMAND" in
      *'verdict_audit_rename_no_clobber_exact'*'"$record_path" "$quarantine"'*)
        [[ "$record_path" == *verdict-request* ]] || return 0
        VERDICT_CANCELED_CONSUME_SEEN=true
        mkdir "$quarantine"
        touch "$quarantine/block"
        touch "$CLAUDE_PROJECT_DIR/canceled-consume-gap"
        ;;
    esac
  }
  set -T
  trap verdict_canceled_consume_debug DEBUG
fi
CANCELED_CONSUME_ENV
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:"session-a",turn_id:"turn-a"}')"
canceled_consume_out="$(printf '%s' "$payload" \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" BASH_ENV="$R/canceled-consume-env.sh" \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
replacement_generation="$(awk '{print $1}' "$canceled_request_path" 2>/dev/null || echo MISSING)"
canceled_consume_state="decision=$(decision_from_output "$canceled_consume_out")"
canceled_consume_state="$canceled_consume_state barrier=$([[ -e "$R/canceled-consume-gap" ]] && echo hit || echo missed)"
canceled_consume_state="$canceled_consume_state marker=$([[ -e "$canceled_marker" ]] && echo present || echo gone)"
if [[ "$replacement_generation" != "$canceled_generation" \
   && "$replacement_generation" != MISSING ]]; then
  canceled_consume_state="$canceled_consume_state generation=fresh"
else
  canceled_consume_state="$canceled_consume_state generation=stale"
fi
if [[ "$canceled_consume_state" == \
      "decision=block barrier=hit marker=present generation=fresh" ]]; then
  ok "failed request retirement keeps cancellation authoritative"
else
  badf "failed request retirement keeps cancellation authoritative" 'got=%s' "$canceled_consume_state"
fi
rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Rolled the canary back; prod looks healthy again, error rate is flat."
check "'prod looks healthy' → block"                              "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "All tests pass: 23/23 on the hook suite."
check "'tests pass' → block"                                      "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Done."
check "bare 'Done.' → block"                                      "$R" "block"; rm -rf "$R"

# Sentence-initial assertion without a helper verb — caught a live false negative
# in the transcript sweep ("Confirmed reachable from the open internet.").
R="$(setup)"; write_transcript "$R" "Confirmed reachable from the open internet."
check "sentence-initial 'Confirmed <adj>' → block"                "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Which of the two layouts do you prefer for the config module?"
check "question → allow"                                          "$R" "allow"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Here are three options for the retry policy, with trade-offs for each."
check "neutral discussion → allow"                                "$R" "allow"; rm -rf "$R"

# Detection reads only the FINAL TURN — a verdict in a PREVIOUS turn (separated
# by a real user message) must not retrigger on a later chat turn.
R="$(setup)"; write_transcript "$R" "The root cause is the stale cache."
append_user "$R" "thanks — and what should I look at next?"
append_assistant "$R" "What to look at next depends on the retry budget you want."
check "previous-turn verdict, new chat turn → allow"              "$R" "allow"; rm -rf "$R"

# A cited file:line is EVIDENCE, and the triage question now asks whether evidence is
# shown — so stripping single-token spans deleted the very thing being asked about, and
# a turn that cited its sources was judged more harshly than one that did not. The stub
# answers NO; what this pins is that the citation still reaches the classifier, checked
# through the regex fallback (which sees the same stripped text) rather than the model.
# Keeping a span's TEXT drops its delimiters, which can pull the token to the start of a
# line and complete a pattern that was never meant to match. Feeding the citation-keeping
# text to tier A let an assertion out through harness-noise with no model call. Both
# static tiers get their own case; the stub answers NO so a tier that wrongly fires is
# the only thing that can produce the wrong decision.
# The span must lead the LINE — harness_patterns is ^-anchored, so "The `API` Error…"
# does not reproduce and would pass either way.
R="$(setup)"; write_transcript "$R" '`API` Error handling is fixed and all tests pass.'
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "citation at line start does not disguise a claim as harness noise"
else
  badf "citation at line start does not disguise a claim as harness noise" 'out=%s' "$out"
fi; rm -rf "$R"

# Tier B's only \$-anchored pattern: a trailing citation must not defeat it. Classifier
# forced UNKNOWN so tier B is what decides, not the model.
R="$(setup)"; write_transcript "$R" 'Done. `#1161`'
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "trailing citation does not defeat the done. assertion"
else
  badf "trailing citation does not defeat the done. assertion" 'out=%s' "$out"
fi; rm -rf "$R"

# The mirror of the leading-token case: a model that reasons first and answers last was
# readable under the old tail -n1 parse and must not regress to UNKNOWN.
R="$(setup)"; write_transcript "$R" "Noted, I'll wait for your call on the API shape."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "Let me think about this.\nYES\n"' \
      bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "trailing classifier answer still read"
else
  badf "trailing classifier answer still read" 'out=%s' "$out"
fi; rm -rf "$R"

# Assert on what the classifier RECEIVES, not on the decision: a stub that answers NO
# allows either way, so a decision-level assertion here would pass without the change.
# The stub captures its stdin — the exact post-strip text — and the two cases pin the
# opposite halves of the rule from one input.
R="$(setup)"
write_transcript "$R" 'Root cause is the stale socket path, at `src/proxy.rs:412`, per `tests pass` in the docs.'
jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD="_text=''; IFS= read -r -d '' _text || :; printf '%s' \"\$_text\" > '$R/seen.txt'; printf 'NO\\n'" bash "$HOOK" ) >/dev/null 2>&1
seen="$(cat "$R/seen.txt" 2>/dev/null || echo MISSING)"
kept="no";      printf '%s' "$seen" | grep -q 'src/proxy.rs:412' && kept="yes"
dropped="no";   printf '%s' "$seen" | grep -q 'tests pass'       || dropped="yes"
for probe in "single-token citation reaches the classifier:$kept" \
             "multi-word quoted prose does not:$dropped"; do
  if [[ "${probe##*:}" == "yes" ]]; then
    ok "${probe%:*}"
  else
    badf "${probe%:*}" 'post-strip text=%s' "$seen"
  fi
done
rm -rf "$R"

# An explanatory classifier answer must not silently become UNKNOWN. The stub rambles
# but leads with the word; a `tail -n1 | tr -dc` parse mangles it into nonsense, drops
# to the regex fallback, and the turn's real triage answer is lost.
R="$(setup)"; write_transcript "$R" "Noted, I'll wait for your call on the API shape."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "YES\nbecause the turn declares the fix works\n"' \
      bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "explanatory classifier answer still read as YES"
else
  badf "explanatory classifier answer still read as YES" 'out=%s' "$out"
fi; rm -rf "$R"

# Verdict phrasing quoted inside code spans/fences is documentation, not a claim.
R="$(setup)"; write_transcript "$R" 'The matcher looks for phrases like `tests pass` and `root cause is` in prose:
```
detector: "tests pass" -> block
```
Nothing is asserted here.'
check "verdict phrases only inside code → allow"                  "$R" "allow"; rm -rf "$R"

R="$(setup)"  # no transcript at all (payload points at /dev/null)
check "no transcript → allow (fail-open)"                         "$R" "allow"; rm -rf "$R"

# Codex explicitly permits a null transcript_path and provides the stable
# last_assistant_message field on Stop. Ignoring that field turns every such event
# into an empty allow even when the message is an obvious verdict.
R="$(setup)"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:false,
  last_assistant_message:"All tests pass."}')"
out="$(run_payload_hook "$R" "$payload")"
got="$(decision_from_output "$out")"
expected_id="$(cksum_of "All tests pass.")"
recorded_id="$(cat "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fallback_transcript="$(cd "$R" && pwd -P)/.agents/state/verdict-stop-message.jsonl.$DEFAULT_SCOPE"
fallback_text="$(jq -r '[.records[]? | select(.kind == "assistant") | .texts[]?] | join("\n\n")' \
  "$fallback_transcript" 2>/dev/null || echo MISSING)"
runner_context="$(jq -r '(has("transcript_path") | not) and has("parent_session_id")' \
  "$R/.agents/state/SYNC_AUDIT_TASK_INPUT" 2>/dev/null || true)"
if [[ "$got" == "block" && "$recorded_id" == "$expected_id" \
   && "$fallback_text" == "All tests pass." \
   && "$runner_context" == true ]]; then
  ok "null transcript + Stop message → block with content identity and discovery context"
else
  badf "null transcript + Stop message → block with content identity and discovery context" 'got=%s id=%s expected=%s fallback=%s handed-off=%s' "$got" "$recorded_id" "$expected_id" "$fallback_text" \
    "$runner_context"
fi

# A recursive Stop for the message just judged is stale, but only when Codex marks
# the hook active. It must avoid the transcript flush wait because there is no
# transcript to flush; otherwise every blocked Stop adds two seconds of dead time.
# A session with an open FAIL re-audits every Stop, so the guard runs in a session whose
# audit of this message passed.
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"recursion-session",
  stop_hook_active:false, last_assistant_message:"All tests pass."}')"
TEST_AUDIT_VERDICT=PASS decide_payload "$R" "$payload" >/dev/null
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"recursion-session", stop_hook_active:true,
  last_assistant_message:"All tests pass."}')"
started=$SECONDS
got="$(decide_payload "$R" "$payload")"
elapsed=$((SECONDS - started))
if [[ "$got" == "allow" && "$elapsed" -lt 2 ]]; then
  ok "same active Stop payload → immediate stale allow"
else
  badf "same active Stop payload → immediate stale allow" 'got=%s elapsed=%ss' "$got" "$elapsed"
fi

# The same text without the recursion signal may be a new user turn and must be
# judged again. Conversely, stop_hook_active never exempts changed text.
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:false,
  last_assistant_message:"All tests pass."}')"
got_same_fresh="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:true,
  last_assistant_message:"All 7/7 tests pass."}')"
got_changed_active="$(decide_payload "$R" "$payload")"
if [[ "$got_same_fresh" == "block" && "$got_changed_active" == "block" ]]; then
  ok "payload guard skips only an identical active recursion"
else
  badf "payload guard skips only an identical active recursion" 'same-fresh=%s changed-active=%s' "$got_same_fresh" "$got_changed_active"
fi; rm -rf "$R"

R="$(setup)"
payload="$(jq -nc --arg p "$R/missing.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:false,
    last_assistant_message:"Root cause is the stale index."}')"
got_missing="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"question-session", stop_hook_active:false,
  last_assistant_message:"Should I run the focused suite?"}')"
got_question="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", session_id:"empty-session", stop_hook_active:false,
  last_assistant_message:null}')"
got_empty="$(decide_payload "$R" "$payload")"
if [[ "$got_missing" == "block" && "$got_question" == "allow" && "$got_empty" == "allow" ]]; then
  ok "payload fallback distinguishes verdict, question, and empty input"
else
  badf "payload fallback distinguishes verdict, question, and empty input" 'missing=%s question=%s empty=%s' "$got_missing" "$got_question" "$got_empty"
fi; rm -rf "$R"

# A readable transcript remains authoritative because it contains the whole turn.
# The latest payload fragment must not hide a verdict asserted earlier in that turn.
R="$(setup)"; write_transcript "$R" "Root cause is the stale index."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:false,
    last_assistant_message:"Anything else?"}')"
got="$(decide_payload "$R" "$payload")"
check_eq "whole-turn transcript takes precedence over payload fragment" "$got" "block"; rm -rf "$R"

# A nonempty transcript with no assistant record may simply be ahead of its flush.
# Do not fall back to a benign latest fragment until the bounded transcript wait has
# had a chance to recover the whole turn.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
( sleep 0.6
  jq -nc '{type:"assistant", message:{content:[{type:"text",
    text:"Root cause is the stale index; all tests pass."}]}}' >> "$R/transcript.jsonl" ) &
late_writer=$!
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session", stop_hook_active:false,
    last_assistant_message:"Anything else?"}')"
got="$(decide_payload "$R" "$payload")"
wait "$late_writer" 2>/dev/null
check_eq "transcript flush wins before payload fallback" "$got" "block"; rm -rf "$R"

# ── The gate must never end a turn it could not SEE ──────────────────────────
# A zero-byte/absent transcript is genuinely nothing to judge → allow at once, and the
# rung must say `empty` so it stays distinguishable from being blind.
R="$(setup)"
decide "$R" >/dev/null
if grep -q ' extract empty-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "no transcript → allow logged as empty (not blind)"
else
  badf "no transcript → allow logged as empty (not blind)" 'log=%s' \
    "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# THE REPRODUCER. A transcript WITH content but no assistant text means the hook read
# the file before the harness flushed the turn — the text lands moments later and the
# turn must still be judged on it. Observed live at 06:06:18Z: the text record's own
# timestamp was 0.1s after the hook's read, the turn logged `extract empty-allow`, and
# a verdict-shaped turn ended completely untriaged.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
( sleep 0.6
  jq -nc '{type:"assistant", uuid:"uuid-last", message:{content:[{type:"text",
     text:"Root cause is the stale index; 12/12 tests pass."}]}}' >> "$R/transcript.jsonl" ) &
late_writer=$!
got="$(decide "$R")"
wait "$late_writer" 2>/dev/null
check_eq "text flushed mid-wait → turn is judged, not skipped" "$got" "block"; rm -rf "$R"

# Content present but the turn genuinely never produces assistant text: still fail open
# (never trap on absent state), but under a rung that ADMITS the gate was blind.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
got="$(decide "$R")"
if [[ "$got" == "allow" ]] && grep -q ' extract blind-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "still no assistant text after the wait → allow, logged blind"
else
  badf "still no assistant text after the wait → allow, logged blind" 'got=%s log=%s' "$got" \
    "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Present dossier, fresh + matching → the verdict decides"
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
check "PASS → allow"                                              "$R" "allow"
check_gone "PASS dossier consumed on allow"                       "$R"; rm -rf "$R"

# `git branch --show-current` is legitimately empty on detached HEAD (including this
# development worktree). Snapshot transport must preserve that leading empty field rather
# than shifting head/tree/verdict left as tab-delimited Bash `read` does.
R="$(setup)"; git -C "$R" checkout --detach -q
write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
check "detached-HEAD PASS with an empty branch → allow"            "$R" "allow"
check_gone "detached-HEAD dossier consumed on allow"               "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause confirmed; pausing here."; write_verdict "$R" "IN_PROGRESS" '["push pending"]'
check "IN_PROGRESS → allow"                                       "$R" "allow"
check_gone "IN_PROGRESS dossier consumed on allow"                "$R"; rm -rf "$R"

# Requirement: the gate MAY loop on real findings — FAIL persists until re-audited.
R="$(setup)"; write_transcript "$R" "The fix works."; write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
check "FAIL → block (finding-driven loop)"                        "$R" "block"
check "FAIL again (unaddressed) → still block"                    "$R" "block"; rm -rf "$R"

# Findings are auditor-controlled strings. Bound the actual public Stop response after
# the concise failure wrapper is added; bounding only classifier input leaves this path
# unbounded.
R="$(setup)"; write_transcript "$R" "The fix works."
oversized_finding="$(awk 'BEGIN {
  for (i = 0; i < 16000; i++) printf "f"
  printf "END_UNBOUNDED_VERDICT_FINDING"
}')"
oversized_findings="$(jq -nc --arg f "$oversized_finding" '[$f]')"
write_verdict "$R" "FAIL" "$oversized_findings"
oversized_fail_out="$(run_payload_hook "$R" \
  "$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')")"
oversized_fail_reason="$(printf '%s' "$oversized_fail_out" | jq -r '.reason // ""')"
oversized_fail_bytes="$(LC_ALL=C printf '%s' "$oversized_fail_reason" | wc -c | tr -d ' ')"
if [[ "$(decision_from_output "$oversized_fail_out")" == block ]] \
   && (( oversized_fail_bytes <= 8192 )) \
   && [[ "$oversized_fail_reason" != *"END_UNBOUNDED_VERDICT_FINDING"* ]] \
   && [[ "$oversized_fail_reason" == *"8192-byte safety limit"* ]] \
   && [[ "$oversized_fail_reason" == *"remains blocked"* ]]; then
  ok "oversized FAIL reason stays blocked and bounded ($oversized_fail_bytes bytes)"
else
  bad "oversized FAIL reason stays blocked and bounded ($oversized_fail_bytes bytes)" "oversized FAIL reason escaped the final-output bound ($oversized_fail_bytes bytes)"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Proof is still in progress."
write_verdict "$R" "IN_PROGRESS" "$oversized_findings"
oversized_progress_out="$(run_payload_hook "$R" \
  "$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')")"
oversized_progress_note="$(printf '%s' "$oversized_progress_out" | jq -r '.systemMessage // ""')"
oversized_progress_bytes="$(LC_ALL=C printf '%s' "$oversized_progress_note" | wc -c | tr -d ' ')"
if [[ "$(decision_from_output "$oversized_progress_out")" == allow ]] \
   && (( oversized_progress_bytes <= 8192 )) \
   && [[ "$oversized_progress_note" != *"END_UNBOUNDED_VERDICT_FINDING"* ]] \
   && [[ "$oversized_progress_note" == *"IN_PROGRESS"* ]] \
   && [[ "$oversized_progress_note" == *"details omitted"* ]]; then
  ok "oversized IN_PROGRESS note stays bounded ($oversized_progress_bytes bytes)"
else
  bad "oversized IN_PROGRESS note stays bounded ($oversized_progress_bytes bytes)" "oversized IN_PROGRESS note escaped the final-output bound ($oversized_progress_bytes bytes)"
fi; rm -rf "$R"

# PASS advisories are auditor-controlled strings too: the human-only note stays bounded
# and still says the turn passed.
R="$(setup)"; write_transcript "$R" "The fix works."
write_verdict "$R" "PASS" '[]'
jq -c --argjson a "$oversized_findings" '. + {advisories:$a}' \
  "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" > "$R/oversized-advisories.json" \
  && mv "$R/oversized-advisories.json" "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
oversized_pass_out="$(run_payload_hook "$R" \
  "$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')")"
oversized_pass_note="$(printf '%s' "$oversized_pass_out" | jq -r '.systemMessage // ""')"
oversized_pass_bytes="$(LC_ALL=C printf '%s' "$oversized_pass_note" | wc -c | tr -d ' ')"
if [[ "$(decision_from_output "$oversized_pass_out")" == allow ]] \
   && (( oversized_pass_bytes <= 8192 )) \
   && [[ "$oversized_pass_note" != *"END_UNBOUNDED_VERDICT_FINDING"* ]] \
   && [[ "$oversized_pass_note" == *"Verdict: PASS"* ]] \
   && [[ "$oversized_pass_note" == *"omitted"* ]]; then
  ok "oversized PASS advisories note stays bounded ($oversized_pass_bytes bytes)"
else
  bad "oversized PASS advisories note stays bounded ($oversized_pass_bytes bytes)" "oversized PASS advisories note escaped the final-output bound ($oversized_pass_bytes bytes)"
fi; rm -rf "$R"

echo
echo "## Audit in flight → allow (the gate must not busy-wait on its own remedy)"
# Regression: 108 blocks in one session, 39 in a 512s window, while the audit the gate
# demanded was still running. Each conjunct gets its own case — the rung must suppress
# only the window where no verdict provably exists yet.
lock_path() { printf '%s/.agents/state/verdict-audit.lock.%s' "$1" "$DEFAULT_SCOPE"; }
# $2 = body VERBATIM, except that a bare PID or "PID DEADLINE" becomes the complete lease
# a runner publishes for the default session's current request (deadline defaults to
# 300 s ahead). See take_audit_lock() in run-verdict-audit.sh.
take_lock() {
  local body="$2" pid deadline
  mkdir -p "$1/.agents/state"
  if [[ "$body" =~ ^([1-9][0-9]*)(\ ([0-9]+))?$ ]]; then
    pid="${BASH_REMATCH[1]}"; deadline="${BASH_REMATCH[3]:-$(( $(date +%s) + 300 ))}"
    write_session_request "$1" "$DEFAULT_SESSION" "$DEFAULT_GENERATION" "$(final_id_of "$1")"
    body="$pid $deadline 0 $DEFAULT_SCOPE 201-202-1 $DEFAULT_GENERATION $(verdict_audit_process_start_token "$pid" 2>/dev/null)"
  fi
  printf '%s' "$body" > "$(lock_path "$1")"
}
hold_lock_mutex() {  # lock-metadata-path
  local metadata_path="$1" ready="${1}.mutex-ready"
  perl -MFcntl=:flock -e '
    my ($path, $ready, $state_dir) = @ARGV;
    open(my $fh, ">>", "$path.mutex") or exit 2;
    flock($fh, LOCK_EX) or exit 2;
    open(my $signal, ">", $ready) or exit 2;
    close($signal);
    select(undef, undef, undef, 0.02) while -d $state_dir;
  ' "$metadata_path" "$ready" "$(dirname "$metadata_path")" &
  for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -e "$ready" ]] && return 0; sleep 0.01; done
  return 1
}
now_epoch()  { date +%s; }
overflow_epoch() {  # seconds-from-now, encoded as 2^64 + target
  perl -MMath::BigInt -e '
    my $delta = shift;
    print Math::BigInt->new("18446744073709551616")->badd(time + $delta);
  ' "$1"
}
# BSD `date -r` / GNU `date -d @`. The suite's other backdating uses a fixed 2020 stamp,
# useless here because the deadline ceiling is anchored TO the mtime.
backdate() {  # file  seconds-ago
  local target=$(( $(date +%s) - $2 )) stamp
  stamp="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [[ -n "$stamp" ]] && touch -t "$stamp" "$1"
}
futuredate() {  # file  seconds-ahead
  local target=$(( $(date +%s) + $2 )) stamp
  stamp="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [[ -n "$stamp" ]] && touch -t "$stamp" "$1"
}

sleep 300 & LIVE_PID=$!            # stands in for a running run-verdict-audit.sh

# The rung sits ahead of triage, so the 5-10s model round-trip must be skipped too —
# the stub answers YES, which is what a hook WITHOUT the rung would block on.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if [[ -z "$out" ]] \
   && grep -q ' audit inflight-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null \
   && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  ok "audit running → silent allow (classifier skipped)"
else
  badf "audit running → silent allow (classifier skipped)" 'out=%s ran=%s log=%s' "$out" \
    "$(classifier_ran "$R")" "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# A live PID plus plausible metadata is not ownership. Without the kernel lease, a stale
# file surviving SIGKILL/PID reuse must not suppress triage.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "live PID without the kernel lease → block"
else
  badf "live PID without the kernel lease → block" 'out=%s' "$out"
fi; rm -rf "$R"

# A busy flock is authoritative only on the single-link inode at the exact runtime path.
# Locking an outside file and hardlinking it into state must not buy inflight-allow.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
outside_mutex="$R/outside-owned-mutex"
printf 'outside\n' > "$outside_mutex"
ln "$outside_mutex" "$(lock_path "$R").mutex"
perl -MFcntl=:flock -e '
  my ($path, $ready, $state_dir) = @ARGV;
  open(my $fh, ">>", $path) or exit 2;
  flock($fh, LOCK_EX) or exit 2;
  open(my $mark, ">", $ready) or exit 2;
  close($mark);
  select(undef, undef, undef, 0.02) while -d $state_dir;
' "$outside_mutex" "$R/hardlink-mutex-ready" "$R/.agents/state" & hardlink_mutex_holder=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -e "$R/hardlink-mutex-ready" ]] && break
  sleep 0.01
done
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "hardlinked busy mutex cannot authorize inflight allow"
else
  badf "hardlinked busy mutex cannot authorize inflight allow" 'out=%s' "$out"
fi
rm -rf "$R"; wait "$hardlink_mutex_holder" 2>/dev/null || true

# Lease inspection itself must be bounded. Perl `open >>path` blocks before `flock` when
# the gitignored mutex is a FIFO/symlink; an outer alarm makes that old behavior a fast
# failure while the hook is expected to reject the malformed lease and triage normally.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
rm -f "$(lock_path "$R").mutex"
mkfifo "$R/audit-mutex-fifo"
ln -s "$R/audit-mutex-fifo" "$(lock_path "$R").mutex"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
fifo_out="$(printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) 2>/dev/null)"; fifo_rc=$?
fifo_gate_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
check_eq "FIFO audit mutex → bounded rejection" "$fifo_gate_state" "rc=0 decision=block"; rm -rf "$R"

# A dead runner must not buy silence: the EXIT trap misses SIGKILL, so an interrupted
# session orphans the lock.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
take_lock "$R" "$DEAD_PID"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "lock held by a DEAD pid → block (no bypass)"
else
  badf "lock held by a DEAD pid → block (no bypass)" 'out=%s' "$out"
fi; rm -rf "$R"

# A bare-PID body has no deadline, so it takes the max_age_seconds fallback — not the
# general rule; a body carrying a deadline gets the wider bound (see the 800s case).
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"; touch -t 202001010000 "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "lock older than max_age → block (pid reuse bounded)"
else
  badf "lock older than max_age → block (pid reuse bounded)" 'out=%s' "$out"
fi; rm -rf "$R"

# A future mtime is not fresh metadata; it is an invalid clock observation. The gate must
# reject it instead of extending a stale lease.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
hold_lock_mutex "$(lock_path "$R")"
futuredate "$(lock_path "$R")" 600
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "future-mtime lock → block"
else
  badf "future-mtime lock → block" 'out=%s' "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token extra-field"
hold_lock_mutex "$(lock_path "$R")"
futuredate "$(lock_path "$R")" 600
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "future-mtime deadline lock → block"
else
  badf "future-mtime deadline lock → block" 'out=%s' "$out"
fi; rm -rf "$R"

# THE soundness case. The runner removes the dossier before auditing, so a present one
# means this run already answered (the auditor writes mid-run). A held lock must not
# mute it, or a real FAIL is skippable for the runner's whole tail.
R="$(setup)"; write_transcript "$R" "The fix works."
write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
take_lock "$R" "$LIVE_PID"
check "verdict already written → FAIL blocks despite the held lock"  "$R" "block"; rm -rf "$R"

# Untrusted input: anything that is not a PID says nothing about liveness. "0" is the
# dangerous one — `kill -0 0` hits the caller's own process group and SUCCEEDS, so a
# bare numeric check would let it past the liveness conjunct.
for junk in "" "0" "not-a-pid" "12x34" "-1"; do
  R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
  take_lock "$R" "$junk"
  out="$(run_hook "$R" YES)"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    ok "lock content '${junk:-<empty>}' is not a live pid → block"
  else
    badf "lock content '${junk:-<empty>}' is not a live pid → block" 'out=%s' "$out"
  fi; rm -rf "$R"
done

# Models a long run partway through: the lock is ALREADY older than max_age_seconds, so
# a hook that ignores the deadline and falls back to the mtime bound fails here.
# Backdated 700s, not to 2020, because the ceiling is anchored to the mtime.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 ))"
hold_lock_mutex "$(lock_path "$R")"
backdate "$(lock_path "$R")" 700
out="$(run_hook "$R" YES)"
if [[ -z "$out" ]]; then
  ok "deadline beyond max_age_seconds → still silent allow (long audits covered)"
else
  badf "deadline beyond max_age_seconds → still silent allow (long audits covered)" 'out=%s' "$out"
fi; rm -rf "$R"

# Field parsing is not record parsing: `read` accepts a valid first line and silently
# ignores later records. A forged suffix must invalidate the whole persisted lease.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token extra-field
ignored second record"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "a valid lock prefix cannot hide a second persisted record"
else
  badf "a valid lock prefix cannot hide a second persisted record" 'out=%s' "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
mkdir -p "$R/.agents/state"
printf '%s\n\n' \
  "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token extra-field" \
  > "$(lock_path "$R")"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "a trailing blank record invalidates lock metadata"
else
  badf "a trailing blank record invalidates lock metadata" 'out=%s' "$out"
fi; rm -rf "$R"

# A lock without a deadline or a start token is unsupported metadata: even with a live
# PID, a held lease, and a current request it buys no silence, and stderr names the fix.
for old_lock_kind in no-deadline no-start-token; do
  R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
  take_lock "$R" "$LIVE_PID"
  case "$old_lock_kind" in
    no-deadline) printf '%s' "$LIVE_PID" > "$(lock_path "$R")" ;;
    *) printf '%s' "$LIVE_PID $(( $(now_epoch) + 300 )) 0 $DEFAULT_SCOPE 201-202-1 $DEFAULT_GENERATION" \
         > "$(lock_path "$R")" ;;
  esac
  hold_lock_mutex "$(lock_path "$R")"
  old_lock_out="$(jq -nc --arg p "$R/transcript.jsonl" --arg s "$DEFAULT_SESSION" \
      '{transcript_path:$p, hook_event_name:"Stop", session_id:$s}' \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" bash "$HOOK" ) 2>"$R/old-lock.err")"
  old_lock_state="decision=$(decision_from_output "$old_lock_out") fix=$(grep -q \
    "unsupported verdict audit lock without a deadline or start token; remove .*/verdict-audit\.lock\.$DEFAULT_SCOPE$" \
    "$R/old-lock.err" && echo named || echo missing)"
  check_eq "$old_lock_kind lock fails closed and names its removal" "$old_lock_state" "decision=block fix=named"; rm -rf "$R"
done

# The metadata path itself is workspace state. It must be opened nonblocking and
# rejected when it is not a regular file, before the in-flight rung can buy silence.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
mkdir -p "$R/.agents/state"; mkfifo "$(lock_path "$R")"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
fifo_out="$(printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  perl -e 'alarm 5; exec @ARGV' bash "$HOOK" ) 2>/dev/null)"; fifo_rc=$?
fifo_lock_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
check_eq "FIFO lock metadata → bounded rejection" "$fifo_lock_state" "rc=0 decision=block"; rm -rf "$R"

# ...but the deadline is file content, not a promise. Past it, the run is over however
# alive the PID looks.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) - 30 ))"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "deadline already passed → block"
else
  badf "deadline already passed → block" 'out=%s' "$out"
fi; rm -rf "$R"

# A lock cannot buy itself unbounded silence by claiming a deadline years out.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 86400 ))"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "deadline past the hard ceiling → block (rejected, not capped)"
else
  badf "deadline past the hard ceiling → block (rejected, not capped)" 'out=%s' "$out"
fi; rm -rf "$R"

# Decimal width is part of validation, not presentation. Bash 3 wraps 2^64 + (now+800)
# into a plausible live deadline; an overflowing persisted lease must not buy silence.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(overflow_epoch 800)"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "overflowing lock deadline → block before arithmetic"
else
  badf "overflowing lock deadline → block before arithmetic" 'out=%s' "$out"
fi; rm -rf "$R"

# Composition with the discard path, which is how a re-audit round actually looks: the
# agent fixed the findings (tree moved), the old dossier is discarded as mismatched, and
# a runner is already recomputing the verdict. The dossier branch must not consume its
# way past this rung, and the discarded dossier must not resurrect as a block.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
jq '.generation = "91-92-9"' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" > "$R/older-dossier"
mv "$R/older-dossier" "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"  # an earlier round
printf 'moved\n' >> "$R/src/lib.rs"            # invalidates the binding
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 ))"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if [[ -z "$out" ]] \
   && [[ ! -e "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" ]]; then
  ok "stale dossier discarded + audit in flight → silent allow"
else
  badf "stale dossier discarded + audit in flight → silent allow" 'out=%s dossier=%s' "$out" \
    "$([[ -e "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" ]] && echo present || echo gone)"
fi; rm -rf "$R"

# A worktree can host more than one task. Session A's live audit must suppress only A's
# repeated Stop; otherwise session B can use A's expensive proof work as an unaudited
# bypass. Session A's lock also sits at the default session's path, so only the scope
# field, not the pathname, can grant the allowance.
R="$(setup)"; claim="Root cause is the stale socket path; 12/12 tests pass."
write_transcript "$R" "$claim"
generation="901-902-3"; scope_a="$(session_scope_of "$R" session-a)"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
lock_body="$LIVE_PID $(( $(now_epoch) + 800 )) 123 $scope_a 901-902-4 $generation $(verdict_audit_process_start_token "$LIVE_PID")"
take_lock "$R" "$lock_body"
printf '%s' "$lock_body" > "$(session_state_path "$R" verdict-audit.lock session-a)"
hold_lock_mutex "$(session_state_path "$R" verdict-audit.lock session-a)"
out_a="$(run_session_hook "$R" session-a YES)"
out_b="$(run_session_hook "$R" session-b YES)"
pair="a=$(decision_from_output "$out_a") b=$(decision_from_output "$out_b")"
if [[ "$pair" == "a=allow b=block" && -z "$out_a" ]]; then
  ok "silent in-flight allowance is owned by one session"
else
  badf "silent in-flight allowance is owned by one session" 'got=%s' "$pair"
fi; rm -rf "$R"

# A canceled auditor can finish its write after the next generation is already
# running. Its stable-path dossier is garbage, but the CURRENT request and lock are not:
# deleting all three together turns a harmless late write into a needless third audit.
R="$(setup)"; claim="Root cause is the stale socket path; 12/12 tests pass."
write_transcript "$R" "$claim"
current_generation="921-922-6"; late_generation="911-912-5"
scope_a="$(session_scope_of "$R" session-a)"
request_path="$(session_state_path "$R" verdict-request session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
write_session_request "$R" session-a "$current_generation" "$(cksum_of "$claim")"
lock_body="$LIVE_PID $(( $(now_epoch) + 800 )) 123 $scope_a 921-922-7 $current_generation $(verdict_audit_process_start_token "$LIVE_PID")"
printf '%s' "$lock_body" > "$(session_state_path "$R" verdict-audit.lock session-a)"
hold_lock_mutex "$(session_state_path "$R" verdict-audit.lock session-a)"
write_verdict "$R" PASS '[]'
jq --arg g "$late_generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" > "$dossier_path"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
out="$(run_session_hook "$R" session-a YES)"
request_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
late_dossier_gone=no; [[ ! -e "$dossier_path" ]] && late_dossier_gone=yes
late_pair="decision=$(decision_from_output "$out") request=$request_generation dossier_gone=$late_dossier_gone"
if [[ "$late_pair" == "decision=allow request=$current_generation dossier_gone=yes" \
   && -z "$out" ]]; then
  ok "late generation cannot expose the current in-flight audit"
else
  badf "late generation cannot expose the current in-flight audit" 'got=%s' "$late_pair"
fi; rm -rf "$R"

# A completed PASS is equally session- and generation-bound. Running B first is
# deliberate: the old global gate consumes A's dossier, then has nothing left for A.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="911-912-5"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" > "$session_dossier"
out_b="$(run_session_hook "$R" session-b YES)"
out_a="$(run_session_hook "$R" session-a YES)"
pair="a=$(decision_from_output "$out_a") b=$(decision_from_output "$out_b")"
check_eq "completed dossier is bound to its session and audit generation" "$pair" "a=allow b=block"; rm -rf "$R"

# Hosts may invoke an absolute hook from outside the consumer while providing the
# repository through CLAUDE_PROJECT_DIR. Every binding input must come from that same
# consumer root, matching the headless runner and auditor.
R="$(setup)"; outside_repo="$(mktemp -d)"
claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="912-913-6"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
outside_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
outside_out="$(printf '%s' "$outside_payload" | ( cd "$outside_repo" \
  && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
     VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" bash "$HOOK" ) 2>/dev/null)"
outside_gate_state="decision=$(decision_from_output "$outside_out")"
outside_gate_state="$outside_gate_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
check_eq "out-of-repo Stop gate binds the consumer repository" "$outside_gate_state" "decision=allow dossier=gone"; rm -rf "$R" "$outside_repo"

# UserPromptSubmit can revoke a native audit after the Stop gate has atomically selected
# its dossier. Selection hides the inode from the prompt hook, so the gate must re-check
# the exact request before trusting PASS and cancellation must clean any state published
# while it waits for the decision mutex.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="913-914-6"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-pass.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-b >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_pass_out="$(cat "$R/quarantine-pass.out" 2>/dev/null || true)"
quarantine_pass_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_pass_state="$quarantine_pass_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_pass_out")"
quarantine_pass_state="$quarantine_pass_state gate_rc=$quarantined_gate_rc"
quarantine_pass_state="$quarantine_pass_state prompt_rc=$prompt_rc"
quarantine_pass_state="$quarantine_pass_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
[[ -e "$session_dossier" ]] && quarantine_pass_state="$quarantine_pass_state dossier=present" \
                               || quarantine_pass_state="$quarantine_pass_state dossier=gone"
[[ -e "$request_path" ]] && quarantine_pass_state="$quarantine_pass_state request=present" \
                            || quarantine_pass_state="$quarantine_pass_state request=gone"
check_eq "post-quarantine prompt revokes PASS, then cleans the decision window" "$quarantine_pass_state" "barrier=hit waiting=yes decision=allow gate_rc=0 prompt_rc=0 watchdog=quiet dossier=gone request=gone"; rm -rf "$R"

# FAIL is not special authority: after the same revocation it must neither be restored
# to the stable path nor block the superseded turn on an abandoned finding.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="914-915-7"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["abandoned generation finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-fail.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-c >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_fail_out="$(cat "$R/quarantine-fail.out" 2>/dev/null || true)"
quarantine_fail_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_fail_state="$quarantine_fail_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_fail_out")"
quarantine_fail_state="$quarantine_fail_state gate_rc=$quarantined_gate_rc old_finding=$([[ "$quarantine_fail_out" == *"abandoned generation finding"* ]] && echo leaked || echo gone)"
quarantine_fail_state="$quarantine_fail_state prompt_rc=$prompt_rc"
quarantine_fail_state="$quarantine_fail_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
[[ -e "$session_dossier" ]] && quarantine_fail_state="$quarantine_fail_state dossier=present" \
                               || quarantine_fail_state="$quarantine_fail_state dossier=gone"
check_eq "post-quarantine prompt revokes and retires FAIL" "$quarantine_fail_state" "barrier=hit waiting=yes decision=allow gate_rc=0 old_finding=gone prompt_rc=0 watchdog=quiet dossier=gone"; rm -rf "$R"

# A stale FAIL takes the park path instead of the live FAIL path. Cancellation in the
# same hidden-inode window must not let that old generation reappear as `.prev`.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="915-916-8"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["abandoned stale finding"]' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-stale-fail.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-d >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_park_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_park_out="$(cat "$R/quarantine-stale-fail.out" 2>/dev/null || true)"
quarantine_park_state="$quarantine_park_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_park_out")"
quarantine_park_state="$quarantine_park_state gate_rc=$quarantined_gate_rc prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
quarantine_park_state="$quarantine_park_state prompt_rc=$prompt_rc"
quarantine_park_state="$quarantine_park_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
quarantine_park_state="$quarantine_park_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
check_eq "prompt revocation cannot resurrect a stale FAIL park" "$quarantine_park_state" "barrier=hit waiting=yes decision=allow gate_rc=0 prev=gone prompt_rc=0 watchdog=quiet dossier=gone"; rm -rf "$R"

# The prompt hook deliberately returns after three seconds if a Stop gate is wedged. A
# persistent epoch, not the mutex wait, must prevent both post-authority FAIL restore and
# post-consume stale-FAIL parking after that return boundary.
for epoch_race_mode in live-fail stale-fail; do
  R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
  generation="925-926-9"
  write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
  if [[ "$epoch_race_mode" == live-fail ]]; then
    write_verdict "$R" FAIL '["epoch live finding"]'
  else
    write_verdict "$R" FAIL '["epoch stale finding"]' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  fi
  session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
  session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
  request_path="$(session_state_path "$R" verdict-request session-a)"
  jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
    > "$session_dossier"
  rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
  write_epoch_barrier_env "$R"
  payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
  ( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
      VERDICT_EPOCH_BARRIER_MODE="$epoch_race_mode" \
      BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
      > "$R/epoch-race.out" 2>/dev/null ) & epoch_gate_job=$!
  for (( poll_index=0; poll_index<250; poll_index++ )); do
    [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
    sleep 0.01
  done
  ( prompt_hook "$R" session-a turn-epoch >/dev/null 2>&1 ) & epoch_prompt_job=$!
  ( sleep 8
    for doomed_pid in "$epoch_gate_job" "$epoch_prompt_job"; do
      [[ "$doomed_pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$doomed_pid" 2>/dev/null || true
    done
  ) & epoch_watchdog=$!
  wait "$epoch_prompt_job" 2>/dev/null; epoch_prompt_rc=$?
  epoch_gate_live_after_prompt=no
  kill -0 "$epoch_gate_job" 2>/dev/null && epoch_gate_live_after_prompt=yes
  touch "$R/.agents/state/epoch-barrier-release"
  wait "$epoch_gate_job" 2>/dev/null; epoch_gate_rc=$?
  kill "$epoch_watchdog" 2>/dev/null || true; wait "$epoch_watchdog" 2>/dev/null || true
  epoch_gate_out="$(cat "$R/epoch-race.out" 2>/dev/null || true)"
  epoch_race_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
  epoch_race_state="$epoch_race_state prompt_rc=$epoch_prompt_rc gate_live=$epoch_gate_live_after_prompt"
  epoch_race_state="$epoch_race_state gate_rc=$epoch_gate_rc decision=$(decision_from_output "$epoch_gate_out")"
  epoch_race_state="$epoch_race_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
  epoch_race_state="$epoch_race_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
  epoch_race_state="$epoch_race_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
  check_eq "$epoch_race_mode cannot publish after bounded prompt return" "$epoch_race_state" "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow request=gone dossier=gone prev=gone"
  rm -rf "$R"
done

# The classifier can occupy nearly the whole Stop-hook timeout. A prompt arriving while
# it is blocked must make that old Stop allow at the final decision boundary, without
# recreating an audit request after the cancellation hook has returned.
for classifier_epoch_mode in regular unsafe-epoch-path; do
  R="$(setup)"; write_transcript "$R" "The deployment behaves correctly in this scenario."
  request_path="$(session_state_path "$R" verdict-request session-a)"
  epoch_path="$(session_state_path "$R" verdict-prompt-epoch session-a)"
  cat > "$R/classifier-barrier.sh" <<'CLASSIFIER_BARRIER'
#!/usr/bin/env bash
while IFS= read -r _line; do :; done
: > "$CLAUDE_PROJECT_DIR/.agents/state/classifier-barrier-ready"
while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/classifier-barrier-release" ]]; do
  :
done
printf 'YES\n'
CLASSIFIER_BARRIER
  chmod +x "$R/classifier-barrier.sh"
  payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
  ( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD="bash '$R/classifier-barrier.sh'" bash "$HOOK" ) \
      > "$R/classifier-epoch.out" 2>/dev/null ) & classifier_gate_job=$!
  for (( poll_index=0; poll_index<250; poll_index++ )); do
    [[ -e "$R/.agents/state/classifier-barrier-ready" ]] && break
    sleep 0.01
  done
  if [[ "$classifier_epoch_mode" == unsafe-epoch-path ]]; then
    mkdir "$epoch_path"
    printf 'preserve\n' > "$epoch_path/sentinel"
  fi
  ( prompt_hook "$R" session-a turn-classifier >/dev/null 2>&1 ) \
    & classifier_prompt_job=$!
  ( sleep 8; kill_test_pids KILL "$classifier_gate_job" "$classifier_prompt_job" ) \
    & classifier_watchdog=$!
  wait "$classifier_prompt_job" 2>/dev/null; classifier_prompt_rc=$?
  classifier_gate_live=no
  kill -0 "$classifier_gate_job" 2>/dev/null && classifier_gate_live=yes
  touch "$R/.agents/state/classifier-barrier-release"
  wait "$classifier_gate_job" 2>/dev/null; classifier_gate_rc=$?
  kill "$classifier_watchdog" 2>/dev/null || true
  wait "$classifier_watchdog" 2>/dev/null || true
  classifier_epoch_out="$(cat "$R/classifier-epoch.out" 2>/dev/null || true)"
  classifier_epoch_state="barrier=$([[ -e "$R/.agents/state/classifier-barrier-ready" ]] && echo hit || echo missed)"
  classifier_epoch_state="$classifier_epoch_state prompt_rc=$classifier_prompt_rc gate_live=$classifier_gate_live"
  classifier_epoch_state="$classifier_epoch_state gate_rc=$classifier_gate_rc decision=$(decision_from_output "$classifier_epoch_out")"
  classifier_epoch_state="$classifier_epoch_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
  classifier_epoch_state="$classifier_epoch_state epoch=$([[ -f "$epoch_path" && ! -L "$epoch_path" ]] && echo regular || echo unsafe)"
  check_eq "$classifier_epoch_mode chime invalidates a classifier-delayed block" "$classifier_epoch_state" "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow request=gone epoch=regular"
  rm -rf "$R"
done

# Recording the judged message is itself a publication edge. Pause immediately after
# that write, steer the session, and prove the old Stop retracts only its own UUID before
# it can reach triage or create a replacement request.
R="$(setup)"; write_transcript "$R" "The deployment behaves correctly in this scenario."
request_path="$(session_state_path "$R" verdict-request session-a)"
last_uuid_path="$(session_state_path "$R" verdict-last-uuid session-a)"
write_epoch_barrier_env "$R"
printf 'cksum-old-1\n' > "$last_uuid_path"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    VERDICT_EPOCH_BARRIER_MODE=last-uuid-post-write \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/last-uuid-epoch.out" 2>/dev/null ) & last_uuid_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-last-uuid >/dev/null 2>&1 ) & last_uuid_prompt_job=$!
( sleep 8; kill_test_pids KILL "$last_uuid_gate_job" "$last_uuid_prompt_job" ) \
  & last_uuid_watchdog=$!
wait "$last_uuid_prompt_job" 2>/dev/null; last_uuid_prompt_rc=$?
last_uuid_gate_live=no; kill -0 "$last_uuid_gate_job" 2>/dev/null && last_uuid_gate_live=yes
touch "$R/.agents/state/epoch-barrier-release"
wait "$last_uuid_gate_job" 2>/dev/null; last_uuid_gate_rc=$?
kill "$last_uuid_watchdog" 2>/dev/null || true; wait "$last_uuid_watchdog" 2>/dev/null || true
last_uuid_out="$(cat "$R/last-uuid-epoch.out" 2>/dev/null || true)"
last_uuid_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
last_uuid_state="$last_uuid_state prompt_rc=$last_uuid_prompt_rc gate_live=$last_uuid_gate_live"
last_uuid_state="$last_uuid_state gate_rc=$last_uuid_gate_rc decision=$(decision_from_output "$last_uuid_out")"
last_uuid_state="$last_uuid_state uuid=$([[ -e "$last_uuid_path" ]] && echo present || echo gone)"
last_uuid_state="$last_uuid_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
check_eq "chime retracts an old Stop's post-write UUID" "$last_uuid_state" "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow uuid=gone request=gone"; rm -rf "$R"

# An invalid request read is only an observation. If a prompt and newer Stop replace that
# pathname before the old gate selects it, the old gate must restore—not delete—the valid
# replacement it accidentally selected.
R="$(setup)"; claim="The root cause is the stale index."; write_transcript "$R" "$claim"
request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '\n\n' > "$request_path"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=invalid-request-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/invalid-request-race.out" 2>/dev/null ) & invalid_request_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-invalid-request >/dev/null 2>&1 ) \
  & invalid_request_prompt_job=$!
( sleep 8; kill_test_pids KILL "$invalid_request_gate_job" "$invalid_request_prompt_job" ) \
  & invalid_request_watchdog=$!
wait "$invalid_request_prompt_job" 2>/dev/null; invalid_request_prompt_rc=$?
new_request_body="991-992-11 $(( $(date +%s) + 600 )) $(cksum_of "$claim")"
printf '%s\n' "$new_request_body" > "$request_path"
touch "$R/.agents/state/epoch-barrier-release"
wait "$invalid_request_gate_job" 2>/dev/null; invalid_request_gate_rc=$?
kill "$invalid_request_watchdog" 2>/dev/null || true
wait "$invalid_request_watchdog" 2>/dev/null || true
invalid_request_out="$(cat "$R/invalid-request-race.out" 2>/dev/null || true)"
preserved_request_body="$(cat "$request_path" 2>/dev/null || echo MISSING)"
invalid_request_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
invalid_request_state="$invalid_request_state prompt_rc=$invalid_request_prompt_rc gate_rc=$invalid_request_gate_rc"
invalid_request_state="$invalid_request_state decision=$(decision_from_output "$invalid_request_out") preserved=$([[ "$preserved_request_body" == "$new_request_body" ]] && echo yes || echo no)"
if [[ "$invalid_request_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow preserved=yes" ]]; then
  ok "invalid-request recovery preserves a post-chime replacement"
else
  badf "invalid-request recovery preserves a post-chime replacement" 'got=%s body=%s' "$invalid_request_state" "$preserved_request_body"
fi; rm -rf "$R"

# The same select-then-check rule applies to the stale dossier removed while opening a
# fresh audit round. A native/newer writer may occupy the stable pathname after chime-in.
R="$(setup)"; claim="The root cause is the stale index."; write_transcript "$R" "$claim"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
mkdir -p "$(dirname "$session_dossier")"
printf 'old dossier\n' > "$session_dossier"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=discard-dossier-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/discard-dossier-race.out" 2>/dev/null ) & discard_dossier_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-discard-dossier >/dev/null 2>&1 ) \
  & discard_dossier_prompt_job=$!
( sleep 8; kill_test_pids KILL "$discard_dossier_gate_job" "$discard_dossier_prompt_job" ) \
  & discard_dossier_watchdog=$!
wait "$discard_dossier_prompt_job" 2>/dev/null; discard_dossier_prompt_rc=$?
printf 'fresh dossier\n' > "$session_dossier"
touch "$R/.agents/state/epoch-barrier-release"
wait "$discard_dossier_gate_job" 2>/dev/null; discard_dossier_gate_rc=$?
kill "$discard_dossier_watchdog" 2>/dev/null || true
wait "$discard_dossier_watchdog" 2>/dev/null || true
discard_dossier_out="$(cat "$R/discard-dossier-race.out" 2>/dev/null || true)"
discard_dossier_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
discard_dossier_state="$discard_dossier_state prompt_rc=$discard_dossier_prompt_rc gate_rc=$discard_dossier_gate_rc"
discard_dossier_state="$discard_dossier_state decision=$(decision_from_output "$discard_dossier_out") dossier=$(cat "$session_dossier" 2>/dev/null || echo MISSING)"
check_eq "audit-round cleanup preserves a post-chime dossier" "$discard_dossier_state" "barrier=hit prompt_rc=0 gate_rc=0 decision=allow dossier=fresh dossier"; rm -rf "$R"

# Previous-FAIL expiry starts before the decision mutex. If the prompt wins before exact
# selection and a newer gate parks replacement findings, the old expiry pass restores the
# selected new inode after seeing its stale epoch.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["old finding"]}' > "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=prev-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/prev-select-race.out" 2>/dev/null ) & prev_select_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-prev-select >/dev/null 2>&1 ) & prev_select_prompt_job=$!
( sleep 8; kill_test_pids KILL "$prev_select_gate_job" "$prev_select_prompt_job" ) \
  & prev_select_watchdog=$!
wait "$prev_select_prompt_job" 2>/dev/null; prev_select_prompt_rc=$?
printf '%s\n' '{"verdict":"FAIL","findings":["fresh replacement finding"]}' > "$session_prev"
touch "$R/.agents/state/epoch-barrier-release"
wait "$prev_select_gate_job" 2>/dev/null; prev_select_gate_rc=$?
kill "$prev_select_watchdog" 2>/dev/null || true; wait "$prev_select_watchdog" 2>/dev/null || true
prev_select_out="$(cat "$R/prev-select-race.out" 2>/dev/null || true)"
prev_select_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
prev_select_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
prev_select_state="$prev_select_state prompt_rc=$prev_select_prompt_rc gate_rc=$prev_select_gate_rc"
prev_select_state="$prev_select_state decision=$(decision_from_output "$prev_select_out") finding=$prev_select_finding"
check_eq "previous-FAIL expiry preserves a post-chime replacement" "$prev_select_state" "barrier=hit prompt_rc=0 gate_rc=0 decision=allow finding=fresh replacement finding"; rm -rf "$R"

# Dossier inspection pins the inode observed before the authority check. If prompt
# cancellation returns after its bounded mutex wait and a new generation publishes at
# the stable compatibility path, the old gate restores that replacement untouched.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="993-994-12"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=dossier-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/dossier-select-race.out" 2>/dev/null ) & dossier_select_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-dossier-select >/dev/null 2>&1 ) \
  & dossier_select_prompt_job=$!
( sleep 10; kill_test_pids KILL "$dossier_select_gate_job" "$dossier_select_prompt_job" ) \
  & dossier_select_watchdog=$!
wait "$dossier_select_prompt_job" 2>/dev/null; dossier_select_prompt_rc=$?
new_generation="995-996-13"
write_session_request "$R" session-a "$new_generation" "$(cksum_of "$claim")"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$new_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
touch "$R/.agents/state/epoch-barrier-release"
wait "$dossier_select_gate_job" 2>/dev/null; dossier_select_gate_rc=$?
kill "$dossier_select_watchdog" 2>/dev/null || true
wait "$dossier_select_watchdog" 2>/dev/null || true
dossier_select_out="$(cat "$R/dossier-select-race.out" 2>/dev/null || true)"
dossier_select_generation="$(jq -r '.generation // "MISSING"' "$session_dossier" 2>/dev/null || echo MISSING)"
dossier_select_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
dossier_select_state="$dossier_select_state prompt_rc=$dossier_select_prompt_rc gate_rc=$dossier_select_gate_rc"
dossier_select_state="$dossier_select_state decision=$(decision_from_output "$dossier_select_out") generation=$dossier_select_generation"
check_eq "dossier selection preserves a post-timeout replacement" "$dossier_select_state" "barrier=hit prompt_rc=0 gate_rc=0 decision=allow generation=$new_generation"; rm -rf "$R"

# Parking a stale FAIL preserves its original mtime through a hardlink, but publishing
# that link is no-clobber. A new turn's already-parked findings always win the stable name.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="997-998-14"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["old stale finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
printf 'pub fn changed() {}\n' >> "$R/src/lib.rs"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=park-publish \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/park-publish-race.out" 2>/dev/null ) & park_publish_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-park-publish >/dev/null 2>&1 ) \
  & park_publish_prompt_job=$!
( sleep 10; kill_test_pids KILL "$park_publish_gate_job" "$park_publish_prompt_job" ) \
  & park_publish_watchdog=$!
wait "$park_publish_prompt_job" 2>/dev/null; park_publish_prompt_rc=$?
printf '%s\n' '{"verdict":"FAIL","findings":["new parked finding"]}' > "$session_prev"
touch "$R/.agents/state/epoch-barrier-release"
wait "$park_publish_gate_job" 2>/dev/null; park_publish_gate_rc=$?
kill "$park_publish_watchdog" 2>/dev/null || true; wait "$park_publish_watchdog" 2>/dev/null || true
park_publish_out="$(cat "$R/park-publish-race.out" 2>/dev/null || true)"
park_publish_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
park_publish_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
park_publish_state="$park_publish_state prompt_rc=$park_publish_prompt_rc gate_rc=$park_publish_gate_rc"
park_publish_state="$park_publish_state decision=$(decision_from_output "$park_publish_out") finding=$park_publish_finding"
check_eq "stale-FAIL parking cannot clobber new-turn findings" "$park_publish_state" "barrier=hit prompt_rc=0 gate_rc=0 decision=allow finding=new parked finding"; rm -rf "$R"

# Killing the delegated decision-lock holder must not let a prompt return and then allow
# the lockless gate to restore its hidden FAIL. The epoch remains authoritative even when
# that cooperative lock owner disappears.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="927-928-10"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["decision holder finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
request_path="$(session_state_path "$R" verdict-request session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/decision-holder-loss.out" 2>/dev/null ) & holder_loss_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -s "$R/.agents/state/quarantine-decision-holder-pid" ]] && break
  sleep 0.01
done
decision_holder_pid="$(cat "$R/.agents/state/quarantine-decision-holder-pid" 2>/dev/null || echo 0)"
decision_holder_setup=invalid
if [[ "$decision_holder_pid" =~ ^[1-9][0-9]*$ ]]; then
  decision_holder_setup=valid
  kill -KILL "$decision_holder_pid" 2>/dev/null || true
fi
( prompt_hook "$R" session-a turn-holder-loss >/dev/null 2>&1 ) & holder_loss_prompt_job=$!
( sleep 8; kill_test_pids KILL "$holder_loss_gate_job" "$holder_loss_prompt_job" ) \
  & holder_loss_watchdog=$!
wait "$holder_loss_prompt_job" 2>/dev/null; holder_loss_prompt_rc=$?
touch "$R/.agents/state/quarantine-release"
wait "$holder_loss_gate_job" 2>/dev/null; holder_loss_gate_rc=$?
kill "$holder_loss_watchdog" 2>/dev/null || true; wait "$holder_loss_watchdog" 2>/dev/null || true
holder_loss_out="$(cat "$R/decision-holder-loss.out" 2>/dev/null || true)"
holder_loss_state="setup=$decision_holder_setup prompt_rc=$holder_loss_prompt_rc gate_rc=$holder_loss_gate_rc"
holder_loss_state="$holder_loss_state decision=$(decision_from_output "$holder_loss_out")"
holder_loss_state="$holder_loss_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
holder_loss_state="$holder_loss_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
holder_loss_state="$holder_loss_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
check_eq "decision-holder loss cannot bypass prompt revocation" "$holder_loss_state" "setup=valid prompt_rc=0 gate_rc=0 decision=allow request=gone dossier=gone prev=gone"; rm -rf "$R"

# `.prev` expiry happens before the decision mutex. Hold the selected inode for longer
# than the prompt hook's wait budget; after the chime-in returns, the old Stop must discard
# it rather than restore findings for the abandoned turn.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["fresh old-turn finding"]}' > "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    VERDICT_EPOCH_BARRIER_MODE=prev-restore \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/prev-epoch.out" 2>/dev/null ) & prev_epoch_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-prev >/dev/null 2>&1 ) & prev_epoch_prompt_job=$!
( sleep 10; kill_test_pids KILL "$prev_epoch_gate_job" "$prev_epoch_prompt_job" ) \
  & prev_epoch_watchdog=$!
wait "$prev_epoch_prompt_job" 2>/dev/null; prev_epoch_prompt_rc=$?
sleep 3.2
prev_epoch_gate_live=no; kill -0 "$prev_epoch_gate_job" 2>/dev/null && prev_epoch_gate_live=yes
touch "$R/.agents/state/epoch-barrier-release"
wait "$prev_epoch_gate_job" 2>/dev/null; prev_epoch_gate_rc=$?
kill "$prev_epoch_watchdog" 2>/dev/null || true; wait "$prev_epoch_watchdog" 2>/dev/null || true
prev_epoch_out="$(cat "$R/prev-epoch.out" 2>/dev/null || true)"
prev_epoch_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
prev_epoch_state="$prev_epoch_state prompt_rc=$prev_epoch_prompt_rc gate_live=$prev_epoch_gate_live"
prev_epoch_state="$prev_epoch_state gate_rc=$prev_epoch_gate_rc decision=$(decision_from_output "$prev_epoch_out")"
prev_epoch_state="$prev_epoch_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
check_eq "prompt epoch prevents delayed previous-FAIL restore" "$prev_epoch_state" "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow prev=gone"; rm -rf "$R"

# Expiry selects one exact inode. If another gate parks a fresh replacement after that
# selection, stale cleanup may delete only the selected old inode, never the new pathname.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["old stale finding"]}' > "$session_prev"
touch -t 202001010000 "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
replacement_out="$(printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
  VERDICT_EPOCH_BARRIER_MODE=prev-replacement \
  BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) 2>/dev/null)"
replacement_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
replacement_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
replacement_state="$replacement_state finding=$replacement_finding decision=$(decision_from_output "$replacement_out")"
check_eq "previous-FAIL expiry preserves a concurrent replacement inode" "$replacement_state" "barrier=hit finding=fresh replacement finding decision=block"; rm -rf "$R"

# jq accepts a stream of top-level values. A valid PASS followed by an object whose
# fields normalize to trailing blanks must not collapse back into the first object's
# authority through command substitution.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="916-917-6"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
jq -nc '{branch:"",head:"",tree_hash:"",generation:null,verdict:"",proof:[],findings:[]}' \
  >> "$session_dossier"
multi_value_out="$(run_session_hook "$R" session-a YES)"
if [[ "$(decision_from_output "$multi_value_out")" == block ]]; then
  ok "multiple top-level dossier values cannot authorize PASS"
else
  bad "multiple top-level dossier values cannot authorize PASS" "multiple dossier values collapsed into an authorized PASS"
fi; rm -rf "$R"

for malformed_schema_kind in \
    extra-field malformed-proof pass-findings fail-empty-findings \
    progress-empty-findings fail-blank-finding empty-claim empty-evidence \
    nul-claim nul-finding; do
  R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
  generation="917-918-7"
  write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
  session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
  branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
  tree="$(tree_hash_of "$R")"
  jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" \
    --arg g "$generation" --arg k "$malformed_schema_kind" '
      def proof:
        {claim:"claim",kind:"other",evidence:"evidence",method:"structural",
         status:"verified",blocker:null};
      {branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}
      | if $k == "extra-field" then .unexpected = true
        elif $k == "malformed-proof" then .proof = [null]
        elif $k == "pass-findings" then .findings = ["contradiction"]
        elif $k == "fail-empty-findings" then .verdict = "FAIL"
        elif $k == "progress-empty-findings" then .verdict = "IN_PROGRESS"
        elif $k == "fail-blank-finding" then .verdict = "FAIL" | .findings = [""]
        elif $k == "empty-claim" then .proof = [(proof | .claim = "")]
        elif $k == "empty-evidence" then .proof = [(proof | .evidence = "")]
        elif $k == "nul-claim" then .proof = [(proof | .claim = "\u0000")]
        elif $k == "nul-finding" then .verdict = "FAIL" | .findings = ["\u0000"]
        else . end
    ' > "$session_dossier"
  malformed_schema_out="$(run_session_hook "$R" session-a YES)"
  if [[ "$(decision_from_output "$malformed_schema_out")" == block ]]; then
    ok "$malformed_schema_kind cannot authorize a gate PASS"
  else
    bad "$malformed_schema_kind cannot authorize a gate PASS" "$malformed_schema_kind authorized a gate PASS"
  fi
  rm -rf "$R"
done


R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="918-919-8"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$generation" '
  {branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",
   proof:[
     {claim:"focused test passes",kind:"tests-pass",evidence:"bash test.sh: 2 passed",
      method:"rerun",status:"verified",blocker:null},
     {claim:"native host delivery",kind:"other",evidence:"host path unavailable here",
      method:"structural",status:"blocked",blocker:"native host E2E not available"}
   ],findings:[]}
' > "$session_dossier"
valid_proof_out="$(run_session_hook "$R" session-a YES)"
if [[ "$(decision_from_output "$valid_proof_out")" == allow \
   && ! -e "$session_dossier" ]]; then
  ok "verified and blocked proof entries authorize a valid gate PASS"
else
  bad "verified and blocked proof entries authorize a valid gate PASS" "valid non-empty proof was rejected"
fi; rm -rf "$R"

# The request's deadline is equally untrusted. With no width bound, Bash arithmetic wraps
# 2^64 + (now+600) and a canceled/forged request can authorize an otherwise valid PASS.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="931-932-7"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\n' "$generation" "$(overflow_epoch 600)" "$(cksum_of "$claim")" \
  > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
overflow_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && overflow_request_state="$overflow_request_state request=fresh" \
  || overflow_request_state="$overflow_request_state request=stale"
check_eq "overflowing request deadline cannot authorize PASS" "$overflow_request_state" "decision=block request=fresh"; rm -rf "$R"

# The request is the authority linking a Stop message to one generation. A valid first
# line plus any second record is malformed and must not authorize a matching PASS.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="936-937-8"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\nignored second record\n' \
  "$generation" "$(( $(date +%s) + 600 ))" "$(cksum_of "$claim")" > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
multiline_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && multiline_request_state="$multiline_request_state request=fresh" \
  || multiline_request_state="$multiline_request_state request=stale"
check_eq "a valid request prefix cannot hide a second persisted record" "$multiline_request_state" "decision=block request=fresh"; rm -rf "$R"

R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="938-939-9"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\n\n' \
  "$generation" "$(( $(date +%s) + 600 ))" "$(cksum_of "$claim")" > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
blank_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && blank_request_state="$blank_request_state request=fresh" \
  || blank_request_state="$blank_request_state request=stale"
check_eq "a trailing blank record invalidates the request" "$blank_request_state" "decision=block request=fresh"; rm -rf "$R"

R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"; mkfifo "$request_path"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
# Delay the audit beyond the metadata deadline: replacement must finish first,
# while the final denial still waits for the independently produced dossier.
( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  VERDICT_AUDITOR_CMD="sleep 3; $AUDITOR_STUB" VERDICT_AUDITOR_TIMEOUT=8 \
  exec perl -e 'alarm 15; exec @ARGV' bash "$HOOK" \
  <<< "$fifo_payload" ) > "$R/.agents/state/fifo-request.out" 2>/dev/null &
fifo_request_job=$!
fifo_replacement=bounded
perl -e '
  $SIG{ALRM} = sub { exit 1 }; alarm 2;
  until (-f $ARGV[0]) { select undef, undef, undef, 0.02 }
' "$request_path" || fifo_replacement=timeout
wait "$fifo_request_job" 2>/dev/null; fifo_rc=$?
fifo_out="$(cat "$R/.agents/state/fifo-request.out")"
fresh_generation=MISSING
[[ -f "$request_path" ]] \
  && fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
fifo_request_state="replacement=$fifo_replacement rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
[[ "$fresh_generation" != MISSING ]] \
  && fifo_request_state="$fifo_request_state request=fresh" \
  || fifo_request_state="$fifo_request_state request=missing"
[[ "$fifo_out" == *"independent audit finding"* ]] \
  && fifo_request_state="$fifo_request_state audit=completed"
check_eq "FIFO request metadata → bounded replacement" "$fifo_request_state" "replacement=bounded rc=0 decision=block request=fresh audit=completed"; rm -rf "$R"

# Dossier paths are auditor-controlled. A FIFO must be rejected as malformed without
# letting jq block the Stop hook outside any cancellable process group.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="939-940-10"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
mkfifo "$dossier_path"
( run_session_hook "$R" session-a YES > "$R/fifo-dossier.out" ) & fifo_dossier_job=$!
fifo_dossier_bounded=yes
# The malformed-file rejection is followed by a synchronous audit. Bound the whole
# transition, not the pre-audit substep that used to be the hook's terminal action.
for (( poll_index=0; poll_index<250; poll_index++ )); do kill -0 "$fifo_dossier_job" 2>/dev/null || break; sleep 0.02; done
if kill -0 "$fifo_dossier_job" 2>/dev/null; then
  fifo_dossier_bounded=no
  ( [[ -p "$dossier_path" ]] && printf '{}\n' > "$dossier_path" ) \
    & fifo_dossier_unblock_job=$!
else
  fifo_dossier_unblock_job=0
fi
( sleep 8; kill -KILL "$fifo_dossier_job" 2>/dev/null || true ) & watchdog=$!
wait "$fifo_dossier_job" 2>/dev/null; fifo_dossier_rc=$?
[[ "$fifo_dossier_unblock_job" =~ ^[1-9][0-9]*$ ]] \
  && kill -TERM "$fifo_dossier_unblock_job" 2>/dev/null || true
[[ "$fifo_dossier_unblock_job" =~ ^[1-9][0-9]*$ ]] \
  && wait "$fifo_dossier_unblock_job" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
fifo_dossier_out="$(cat "$R/fifo-dossier.out" 2>/dev/null || true)"
fifo_dossier_state="rc=$fifo_dossier_rc bounded=$fifo_dossier_bounded"
fifo_dossier_state="$fifo_dossier_state decision=$(decision_from_output "$fifo_dossier_out")"
check_eq "FIFO dossier → bounded rejection" "$fifo_dossier_state" "rc=0 bounded=yes decision=block"; rm -rf "$R"

# All authority-bearing fields must come from ONE file open. A late canceled writer can
# atomically replace the shared path between reads. The old implementation read verdict
# before generation, so old PASS + new current generation became a fabricated PASS that
# consumed the real current FAIL.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
old_generation="941-942-8"; current_generation="951-952-9"
write_session_request "$R" session-a "$current_generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$old_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$current_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"FAIL",proof:[],findings:["new generation failure"]}' \
  > "$R/.agents/state/current-generation-dossier"
cat > "$R/.agents/state/dossier-snapshot-env.sh" <<'DOSSIER_SNAPSHOT_ENV'
if [[ -z "${VERDICT_SNAPSHOT_OWNER_PID:-}" ]]; then
  export VERDICT_SNAPSHOT_OWNER_PID="$$"
  verdict_snapshot_debug() {
    [[ "$$" == "$VERDICT_SNAPSHOT_OWNER_PID" ]] || return 0
    if [[ "$BASH_COMMAND" == *'verdict_audit_read_json_snapshot'* \
       && "$BASH_COMMAND" == *'$dossier_quarantine'* ]]; then
      trap - DEBUG
      mv "$VERDICT_SNAPSHOT_REPLACEMENT" "$VERDICT_SNAPSHOT_TARGET"
      touch "$CLAUDE_PROJECT_DIR/.agents/state/dossier-snapshot-swapped"
    fi
  }
  set -T
  trap verdict_snapshot_debug DEBUG
fi
DOSSIER_SNAPSHOT_ENV
snapshot_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
snapshot_out="$(printf '%s' "$snapshot_payload" | ( cd "$R" \
  && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
     BASH_ENV="$R/.agents/state/dossier-snapshot-env.sh" \
     VERDICT_SNAPSHOT_REPLACEMENT="$R/.agents/state/current-generation-dossier" \
     VERDICT_SNAPSHOT_TARGET="$session_dossier" bash "$HOOK" ) 2>/dev/null)"
snapshot_generation="$(jq -r '.generation // "MISSING"' \
  "$session_dossier" 2>/dev/null || echo MISSING)"
snapshot_state="decision=$(decision_from_output "$snapshot_out") barrier=$([[ -e "$R/.agents/state/dossier-snapshot-swapped" ]] && echo hit || echo missed)"
snapshot_state="$snapshot_state stable=$snapshot_generation spliced=no"
[[ "$snapshot_out" == *"new generation failure"* ]] \
  && snapshot_state="${snapshot_state/spliced=no/spliced=yes}"
if [[ "$snapshot_state" == \
    "decision=block barrier=hit stable=$current_generation spliced=no" ]]; then
  ok "dossier selection preserves a concurrent replacement"
else
  badf "dossier selection preserves a concurrent replacement" 'got=%s' "$snapshot_state"
fi; rm -rf "$R"

kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

echo
echo "## Present dossier, stale/mismatched binding → DISCARD + re-detect (never a bookkeeping block)"
# Tree moved after the audit, but the turn ends on a chat message → the old
# dossier is discarded and the turn ends freely. Under #915 this BLOCKED — that
# was the meaningless re-audit class.
R="$(setup)"; write_transcript "$R" "Noted — I'll wait for your call on the API shape."
write_verdict "$R" "PASS" "[]"; printf 'more\n' >> "$R/src/lib.rs"
check "tree moved + chat ending → allow"                          "$R" "allow"
check_gone "mismatched dossier discarded"                         "$R"; rm -rf "$R"

# Tree moved after the audit AND the turn still asserts a verdict → the discard
# falls through to detection, which demands a FRESH audit of the current claim.
R="$(setup)"; write_transcript "$R" "Applied the follow-up; the fix works and tests pass."
write_verdict "$R" "PASS" "[]"; printf 'more\n' >> "$R/src/lib.rs"
check "tree moved + verdict ending → block (fresh audit)"         "$R" "block"
check_stale_gone "mismatched dossier discarded before re-detect"        "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Thanks, ending here."; write_verdict "$R" "FAIL" '["x"]'
jq '.head="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" > "$R/.agents/state/x" \
  && mv "$R/.agents/state/x" "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
check "HEAD-mismatched FAIL + chat ending → allow (discarded)"    "$R" "allow"
check_gone "HEAD-mismatched dossier discarded"                    "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."; write_verdict "$R" "PASS" "[]"
touch -t 202001010000 "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
check "stale-mtime PASS + verdict ending → block (re-detect)"     "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."; write_verdict "$R" "PASS" "[]"
futuredate "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" 600
check "future-mtime PASS + verdict ending → block (re-detect)"    "$R" "block"; rm -rf "$R"

echo
echo "## Tier A: harness text in the assistant slot decides without a model call"
# The assistant slot also carries text the HARNESS wrote — API errors, quota notices,
# interruption markers. No model produced it, so it asserts nothing and can never be a
# verdict. 81 of 563 real turns in this repo's transcripts (14.4%) are exactly this,
# and each one used to buy a 5-10s classifier round-trip to be told "NO".
R="$(setup)"; write_transcript "$R" "API Error: 400 Your input exceeds the context window of this model."
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  ok "harness API error only → allow, classifier never invoked"
else
  badf "harness API error only → allow, classifier never invoked" 'out=%s classifier_ran=%s' "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "No response requested."
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  ok "harness 'No response requested.' → allow, classifier never invoked"
else
  badf "harness 'No response requested.' → allow, classifier never invoked" 'out=%s classifier_ran=%s' "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

# SOUNDNESS — why EVERY non-empty line must match, not just the first. A turn that did
# real work and then hit an error still owes proof... The stub says NO, so a tier A that
# wrongly swallowed these would allow, and so would a hook with no tiers at all.
R="$(setup)"; write_transcript "$R" "Verified the socket path resolves under the jailer."
append_assistant "$R" "API Error: Overloaded"
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "real verdict THEN harness error → block (not swallowed)"
else
  badf "real verdict THEN harness error → block (not swallowed)" 'out=%s' "$out"
fi; rm -rf "$R"

# ...and so does the reverse order, which is exactly what a first-line-only anchor
# leaks: a transient error, then a retry that states the verdict in the same turn.
R="$(setup)"; write_transcript "$R" "API Error: Overloaded"
append_assistant "$R" "Verified the socket path resolves under the jailer."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "harness error THEN real verdict → block (not swallowed)"
else
  badf "harness error THEN real verdict → block (not swallowed)" 'out=%s' "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "API Error: Overloaded"
decide "$R" >/dev/null
if grep -q ' harness noise-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "tier A decision logged (rung + outcome)"
else
  badf "tier A decision logged (rung + outcome)" 'log=%s' "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Count wording uses classification; completion assertions keep the fast path"
# Stub answers NO throughout, so a hook without tier B reaches the model and allows.
R="$(setup)"; write_transcript "$R" "Reran the suite: 173/173 tests pass on the hook harness."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ -e "$R/CLASSIFIER_RAN" ]]; then
  ok "slash counts reach the same classifier as prose counts"
else
  badf "slash counts reach the same classifier as prose counts" 'out=%s classifier_ran=%s' \
    "$out" "$([[ -e "$R/CLASSIFIER_RAN" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# PRECISION — the entire reason the promoted set is a small subset. A turn merely
# DISCUSSING verdict wording must still reach the classifier and be allowed; that is
# what the ambiguous majority ("tests pass", "root cause is", "deploy is healthy")
# stays behind the model for. Reaching the stub proves tier B declined.
R="$(setup)"; write_transcript "$R" "In prose people write things like tests pass or root cause is X or deploy is healthy."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ -e "$R/CLASSIFIER_RAN" ]]; then
  ok "discussion of verdict wording → reaches the model, allowed"
else
  badf "discussion of verdict wording → reaches the model, allowed" 'out=%s classifier_ran=%s' \
    "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Verified the socket path resolves under the jailer."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  ok "line-initial 'Verified …' → block, classifier never invoked"
else
  badf "line-initial 'Verified …' → block, classifier never invoked" 'out=%s classifier_ran=%s' \
    "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "26/26 tests pass."
decide "$R" >/dev/null
if grep -q ' regex match-block$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "offline count fallback logged (rung + outcome)"
else
  badf "offline count fallback logged (rung + outcome)" 'log=%s' "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Slow path: a FAILed dossier survives the fix that invalidates its binding"
# Observed cycle before this: FAIL-block → agent fixes → tree moves → discard-stale →
# re-detect → block → a full COLD re-audit, every round. Parking the FAIL lets round
# N+1 re-check known findings against the delta instead of re-deriving everything.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null
if jq -e '.verdict == "FAIL"' "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" >/dev/null 2>&1; then
  ok "FAIL dossier parked as prev when the binding goes stale"
else
  badf "FAIL dossier parked as prev when the binding goes stale" 'prev=%s' \
    "$(cat "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi
check_stale_gone "…live dossier still discarded (re-detect, never block on bookkeeping)" "$R"; rm -rf "$R"

# An AGED-OUT FAIL means nobody acted on those findings and the round is over. Parking
# it would hand the next audit findings about unrelated work — observed live, a FAIL
# from 04:46 still being offered at 05:37 to an auditor judging a different task.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]'
touch -t 202001010000 "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]]; then
  ok "aged-out FAIL is dropped, not parked"
else
  badf "aged-out FAIL is dropped, not parked" 'prev=%s' \
    "$(cat "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" 2>/dev/null)"
fi; rm -rf "$R"

# A PASS/IN_PROGRESS that merely aged out carries nothing to re-check — it must not
# masquerade as a failed round.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "PASS" '[]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]]; then
  ok "stale PASS is dropped, not parked"
else
  bad "stale PASS is dropped, not parked" "stale PASS wrongly parked as a failed round"
fi; rm -rf "$R"

# Parking is inert unless the findings actually reach the auditor.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no command named"]'
mv "$R/.agents/state/last-verdict.json.$DEFAULT_SCOPE" "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
prior_seen="$(cat "$R/.agents/state/SYNC_AUDIT_PREVIOUS" 2>/dev/null || echo MISSING)"
if [[ "$prior_seen" == *"tests-pass: no command named"* ]]; then
  ok "synchronous auditor receives the prior findings file"
else
  badf "synchronous auditor receives the prior findings file" 'prior=%s out=%s' "$prior_seen" "$out"
fi; rm -rf "$R"

# An UNCLAIMED park expires too. Age-gating only the write bounds staleness at park time,
# but this file is read on every later block — so an abandoned round (user changed topic,
# no re-audit ever ran) would keep feeding dead findings to an auditor judging unrelated
# work, and "a finding you cannot confirm as addressed stays a finding" turns those into a
# manufactured FAIL.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["stale round, never claimed"]}' > "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE"
touch -t 202001010000 "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1 \
   && [[ ! -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]]; then
  ok "unclaimed parked FAIL expires, never reaches the next audit"
else
  badf "unclaimed parked FAIL expires, never reaches the next audit" 'prev_still_there=%s' \
    "$([[ -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# Future dating is equally invalid: a negative age must not preserve abandoned findings
# indefinitely or seed an unrelated audit with proof from a clock-skewed round.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["future-dated abandoned round"]}' \
  > "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE"
futuredate "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" 600
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1 \
   && [[ ! -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]]; then
  ok "future-dated parked FAIL expires"
else
  badf "future-dated parked FAIL expires" 'prev_still_there=%s' \
    "$([[ -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# ...but a freshly parked one is still offered, so expiry cannot swallow the live case.
# The second turn must carry DIFFERENT text: a real round writes a new turn after the fix,
# and reusing the first one trips the flush-race guard instead of reaching the park.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null                       # parks it
write_transcript "$R" "Reworked the index guard; the root cause is addressed."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
prior_seen="$(cat "$R/.agents/state/SYNC_AUDIT_PREVIOUS" 2>/dev/null || echo MISSING)"
if [[ "$prior_seen" == *"tests-pass: no re-runnable command named"* ]]; then
  ok "a just-parked FAIL reaches the next synchronous audit"
else
  badf "a just-parked FAIL reaches the next synchronous audit" 'prior=%s out=%s' "$prior_seen" "$out"
fi; rm -rf "$R"

# The cycle ended clean: a surviving prev would aim the next audit at resolved findings.
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["x"]}' > "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE"
write_verdict "$R" "PASS" "[]"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json.$DEFAULT_SCOPE" ]]; then
  ok "PASS consumption clears the parked FAIL"
else
  bad "PASS consumption clears the parked FAIL" "parked FAIL outlives the PASS that resolved it"
fi; rm -rf "$R"

echo
echo "## Triage (intelligent trigger): classifier decides; regex is the fallback"
triage_prompt_words="$(sed -n "/^triage_prompt='/,/^# The old parse/p" "$HOOK" \
  | sed '$d' | wc -w | tr -d ' ')"
if [[ "$triage_prompt_words" -le 70 ]]; then
  ok "classifier instruction stays within 70 words ($triage_prompt_words)"
else
  bad "classifier instruction stays within 70 words ($triage_prompt_words)" "classifier instruction exceeds 70 words ($triage_prompt_words)"
fi

# The default Claude Code print route is a full coding-agent request: project/user
# instructions, plugins, auto-memory, hooks, and every built-in tool schema. This fake
# is the Claude CLI boundary, so the request budget is derived from the production
# argv rather than a test-only classifier seam. It deliberately models the ambient
# payload when the isolating flags are absent and a second title request when --name
# is absent; both shapes were observed against a local dummy Anthropic endpoint.
R="$(setup)"; write_transcript "$R" "The culprit was a stale socket path."
mkdir -p "$R/bin"
cat > "$R/bin/claude" <<'CLASSIFIER_CLI'
#!/usr/bin/env bash
set -uo pipefail
is_safe=false
has_name=false
has_no_persistence=false
effort=""
system_prompt=""
tools_mode="default"
while (( $# > 0 )); do
  case "$1" in
    --safe-mode) is_safe=true; shift ;;
    --name) has_name=true; shift 2 ;;
    --no-session-persistence) has_no_persistence=true; shift ;;
    --effort) effort="${2:-}"; shift 2 ;;
    --system-prompt) system_prompt="${2:-}"; shift 2 ;;
    --tools) tools_mode="${2-default}"; shift 2 ;;
    *) shift ;;
  esac
done
message="$(cat)"
if [[ "$is_safe" != true ]]; then
  system_prompt="$(awk 'BEGIN { for (i=0; i<30000; i++) printf "s" }')"
fi
if [[ "$tools_mode" == "" ]]; then
  tools='[]'
else
  tools="$(jq -nc '[range(0;30) | {name:("tool_" + tostring), description:("schema_" + ("x" * 700))}]')"
fi
calls=2
[[ "$has_name" == true ]] && calls=1
jq -nc --arg system "$system_prompt" --arg message "$message" --arg effort "$effort" \
  --argjson tools "$tools" --argjson calls "$calls" --argjson safe "$is_safe" \
  --argjson persistence "$has_no_persistence" \
  '{system:$system,messages:[{role:"user",content:$message}],tools:$tools,
    calls:$calls,safe_mode:$safe,no_session_persistence:$persistence,effort:$effort}' \
  > "$CLAUDE_PROJECT_DIR/classifier-request.json"
printf 'NO\n'
CLASSIFIER_CLI
chmod +x "$R/bin/claude"
classifier_budget_out="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && env -u VERDICT_CLASSIFIER_CMD PATH="$R/bin:$PATH" \
      CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
classifier_request_bytes="$(wc -c < "$R/classifier-request.json" | tr -d ' ')"
classifier_system_bytes="$(jq -r '.system | length' "$R/classifier-request.json")"
classifier_tool_count="$(jq -r '.tools | length' "$R/classifier-request.json")"
if [[ "$classifier_request_bytes" -le 4096 \
   && "$classifier_system_bytes" -le 1024 \
   && "$classifier_tool_count" == 0 \
   && "$(jq -r '.calls' "$R/classifier-request.json")" == 1 \
   && "$(jq -r '.safe_mode' "$R/classifier-request.json")" == true \
   && "$(jq -r '.no_session_persistence' "$R/classifier-request.json")" == true \
   && "$(jq -r '.effort' "$R/classifier-request.json")" == low \
   && "$(decision_from_output "$classifier_budget_out")" == allow ]]; then
  ok "classifier request stays isolated and bounded (${classifier_request_bytes}B, ${classifier_tool_count} tools, one call)"
else
  badf "classifier request stays isolated and bounded (${classifier_request_bytes}B, ${classifier_tool_count} tools, one call)" 'bytes=%s system=%s tools=%s request=%s out=%.120s' "$classifier_request_bytes" \
    "$classifier_system_bytes" "$classifier_tool_count" \
    "$(jq -c '{calls,safe_mode,no_session_persistence,effort}' "$R/classifier-request.json")" \
    "$classifier_budget_out"
fi
rm -rf "$R"

# Oversized turns must not be copied into a second model request. They block safely
# and let the file-backed auditor inspect the transcript instead.
R="$(setup)"
oversized_message="$(awk 'BEGIN { for (i=0; i<12100; i++) printf "a" }')"
write_transcript "$R" "$oversized_message"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD=': > "$CLAUDE_PROJECT_DIR/classifier-called"; printf "NO\n"' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
   && [[ ! -e "$R/classifier-called" ]] \
   && [[ -e "$R/.agents/state/SYNC_AUDIT_RAN" ]]; then
  ok "oversized turn skips classifier and runs the file-backed audit"
else
  badf "oversized turn skips classifier and runs the file-backed audit" 'out=%.120s classifier=%s audit=%s' "$out" \
    "$([[ -e "$R/classifier-called" ]] && echo called || echo skipped)" \
    "$([[ -e "$R/.agents/state/SYNC_AUDIT_RAN" ]] && echo ran || echo missing)"
fi
rm -rf "$R"
# The classifier stub receives the stripped message on stdin and answers YES/NO.
# YES on a message the regex would MISS → the intelligence adds recall.
R="$(setup)"; write_transcript "$R" "The culprit involved an unusual interaction."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "YES\n"' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "classifier YES on regex-miss phrasing → block"
else
  badf "classifier YES on regex-miss phrasing → block" 'out=%s' "$out"
fi; rm -rf "$R"

# NO on a message the regex would HIT (quoting/discussion) → intelligence removes
# the static false positive.
R="$(setup)"; write_transcript "$R" "In prose people write things like tests pass or root cause is X when they conclude."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "NO\n"' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block" and .continue == true and (.systemMessage | test("triage: NO"))' >/dev/null 2>&1; then
  ok "classifier NO → allow, announced to the human only"
else
  badf "classifier NO → allow, announced to the human only" 'out=%s' "$out"
fi; rm -rf "$R"

# Classifier unavailable / garbage → UNKNOWN → deterministic regex fallback still gates.
R="$(setup)"; write_transcript "$R" "All tests pass: 23/23 on the hook suite."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "MAYBE\n"' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "classifier garbage → regex fallback → block"
else
  badf "classifier garbage → regex fallback → block" 'out=%s' "$out"
fi; rm -rf "$R"

# Closing stdout is not process completion. A classifier can make the answer pipe
# reach EOF and then stay alive forever; the Stop hook must still apply the same
# classifier deadline to that producer and reap it. The DEBUG fixture shortens the
# existing production timeout variable to one second so this regression stays fast.
R="$(setup)"; write_transcript "$R" "The culprit was the stale socket path all along."
classifier_timeout_env="$R/classifier-timeout-env.sh"
cat > "$classifier_timeout_env" <<'CLASSIFIER_TIMEOUT_ENV'
if [[ -z "${VERDICT_CLASSIFIER_TIMEOUT_OWNER_PID:-}" ]]; then
  export VERDICT_CLASSIFIER_TIMEOUT_OWNER_PID="$$"
  verdict_classifier_timeout_debug() {
    [[ "$$" == "$VERDICT_CLASSIFIER_TIMEOUT_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == triage=*should_audit* ]] || return 0
    trap - DEBUG
    classifier_timeout_seconds=1
    : > "$CLAUDE_PROJECT_DIR/classifier-timeout-shortened"
  }
  set -T
  trap verdict_classifier_timeout_debug DEBUG
fi
CLASSIFIER_TIMEOUT_ENV
classifier_sleep_cmd='printf "%s\n" "$$" > "$CLAUDE_PROJECT_DIR/classifier-sleeper.pid"; : > "$CLAUDE_PROJECT_DIR/classifier-sleeper-ready"; exec 1>&-; exec sleep 6'
classifier_sleep_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
classifier_sleep_started=$SECONDS
classifier_sleep_out="$(printf '%s' "$classifier_sleep_payload" \
  | (cd "$R" && BASH_ENV="$classifier_timeout_env" CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$classifier_sleep_cmd" \
      perl -e 'alarm 4; exec @ARGV' bash "$HOOK") 2>/dev/null)"
classifier_sleep_rc=$?
classifier_sleep_elapsed=$(( SECONDS - classifier_sleep_started ))
classifier_sleep_pid="$(cat "$R/classifier-sleeper.pid" 2>/dev/null || true)"
classifier_sleep_live=no
if [[ "$classifier_sleep_pid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$classifier_sleep_pid" 2>/dev/null; then
  classifier_sleep_live=yes
fi
kill_test_pids TERM "$classifier_sleep_pid"
sleep 0.05
kill_test_pids KILL "$classifier_sleep_pid"
if [[ "$classifier_sleep_rc" -eq 0 \
   && -e "$R/classifier-timeout-shortened" \
   && -e "$R/classifier-sleeper-ready" \
   && "$classifier_sleep_elapsed" -lt 4 \
   && "$classifier_sleep_live" == no ]]; then
  ok "classifier timeout reaps a producer that closed stdout early"
else
  badf "classifier timeout reaps a producer that closed stdout early" 'rc=%s elapsed=%ss timeout_hook=%s ready=%s child_live=%s out=%.80s' \
    "$classifier_sleep_rc" "$classifier_sleep_elapsed" \
    "$([[ -e "$R/classifier-timeout-shortened" ]] && echo hit || echo missed)" \
    "$([[ -e "$R/classifier-sleeper-ready" ]] && echo yes || echo no)" \
    "$classifier_sleep_live" "$classifier_sleep_out"
fi; rm -rf "$R"

echo
echo "## Flush-race guard: never judge a message that was already judged"
# The harness may fire Stop before appending the turn's final message; the last
# transcript entry is then the PREVIOUS turn's (already gated) message. The hook
# records the identity it judged (checksum of the text — harness-agnostic);
# seeing the same identity again → allow, never re-block.
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."   # verdict-shaped
mkdir -p "$R/.agents/state"; cksum_of "Fix verified; tests pass." > "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE"
check "stale transcript (identity already judged) → allow"       "$R" "allow"; rm -rf "$R"

# Normal path records the judged identity so the NEXT stale sighting is recognized.
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
got="$(decide "$R")"
recorded="$(cat "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
if [[ "$got" == "block" && "$recorded" == "$(cksum_of "Deploy is healthy.")" ]]; then
  ok "detection block records the judged identity"
else
  badf "detection block records the judged identity" 'got=%s recorded=%s' "$got" "$recorded"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Anything else to adjust?"
got="$(decide "$R")"
recorded="$(cat "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
if [[ "$got" == "allow" && "$recorded" == "$(cksum_of "Anything else to adjust?")" ]]; then
  ok "detection allow records the judged identity"
else
  badf "detection allow records the judged identity" 'got=%s recorded=%s' "$got" "$recorded"
fi; rm -rf "$R"

echo
echo "## Turn-level extraction: mid-turn findings cannot hide behind closing narration"
# The classifier stub greps its stdin for the finding — proving the JOINED turn
# text (not just the trailing fragment) is what triage judges. This is the class
# a sibling session's decision log caught escaping: finding asserted mid-turn,
# turn ends on "let me check X".
GREP_STUB='text=""; IFS= read -r -d "" text || :; [[ "$text" == *"1:1 port"* ]] && printf "YES\n" || printf "NO\n"'

R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "mid-turn finding + closing narration → block (joined text judged)"
else
  badf "mid-turn finding + closing narration → block (joined text judged)" 'out=%s' "$out"
fi; rm -rf "$R"

# The dominant real-transcript shape: a tool call sits between the finding and
# the closing narration. ARRAY-shaped tool_results nest text blocks inside the
# tool_result — they must not split the turn (that miss shipped once).
R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_tool_result_array "$R" "src/proxy.go: 200 lines, no timer, no activity import"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "array tool_result mid-turn does not split the turn → block"
else
  badf "array tool_result mid-turn does not split the turn → block" 'out=%s' "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_tool_result_string "$R" "ok"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "string tool_result mid-turn does not split the turn → block"
else
  badf "string tool_result mid-turn does not split the turn → block" 'out=%s' "$out"
fi; rm -rf "$R"

# Tool output is untrusted structured data. User- or assistant-shaped objects nested
# inside it are neither a prompt boundary nor an assistant claim.
R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_tool_result_object "$R" '{"role":"user","content":"nested tool data"}'
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "nested user-shaped tool data does not split the turn → block"
else
  badf "nested user-shaped tool data does not split the turn → block" 'out=%s' "$out"
fi; rm -rf "$R"

NESTED_ASSISTANT_STUB='text=""; IFS= read -r -d "" text || :; [[ "$text" == *"NESTED_ASSISTANT_CLAIM"* ]] && printf "YES\n" || printf "NO\n"'
R="$(setup)"; write_transcript "$R" "Want me to inspect the remaining boundary?"
append_tool_result_object "$R" '{"role":"assistant","content":[{"type":"text","text":"NESTED_ASSISTANT_CLAIM"}]}'
append_assistant "$R" "I am still checking."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$NESTED_ASSISTANT_STUB" bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
  ok "nested assistant-shaped tool data is evidence, not a claim → allow"
else
  badf "nested assistant-shaped tool data is evidence, not a claim → allow" 'out=%s' "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Want me to inspect the remaining boundary?"
append_root_tool_record_object "$R" '{"role":"assistant","content":[{"type":"text","text":"NESTED_ASSISTANT_CLAIM"}]}'
append_assistant "$R" "I am still checking."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$NESTED_ASSISTANT_STUB" bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
  ok "root tool records cannot supply assistant claims → allow"
else
  badf "root tool records cannot supply assistant claims → allow" 'out=%s' "$out"
fi; rm -rf "$R"

# Same finding but in a PREVIOUS turn (real user message between): the final
# turn is narration only — must not retrigger.
R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_user "$R" "ok — check the proxy then"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
  ok "same finding in a previous turn → allow (turn boundary respected)"
else
  badf "same finding in a previous turn → allow (turn boundary respected)" 'out=%s' "$out"
fi; rm -rf "$R"

# Codex rollout shape, same semantics: user boundary + two assistant texts join.
R="$(setup)"
jq -nc '{type:"response_item", payload:{type:"message", role:"user", content:[{type:"input_text", text:"compare with upstream"}]}}' > "$R/transcript.jsonl"
jq -nc '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:"The activity service is a 1:1 port of upstream."}]}}' >> "$R/transcript.jsonl"
jq -nc '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:"Let me check the proxy next."}]}}' >> "$R/transcript.jsonl"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "codex shape: mid-turn finding joined across records → block"
else
  badf "codex shape: mid-turn finding joined across records → block" 'out=%s' "$out"
fi; rm -rf "$R"

echo
echo "## Final-turn reader: parsing tracks the turn, not the session"
# The reader scans back from the end of the transcript to the last real user message,
# so earlier history is hashed, never parsed. A whole-file cap made every Stop after a
# session passed 64 MiB fail as unreadable evidence (#262).
R="$(setup)"
perl -e 'my $pad = "x" x 1048000; print qq({"type":"progress","data":"$pad"}\n) for 1 .. 66' \
  > "$R/transcript.jsonl"
append_user "$R" "How is the session going?"
append_assistant "$R" "Nothing here is a verdict; just chatting."
long_decision="$(decide "$R")"
long_rung="none"
grep -q 'extract truncated-block' "$R"/.agents/state/verdict-decisions.log* 2>/dev/null \
  && long_rung="extract truncated-block"
if [[ "$long_decision" == allow && "$long_rung" == none ]]; then
  ok 'a 66 MiB session with a small final turn is judged, not truncated'
else
  badf 'a 66 MiB session with a small final turn is judged, not truncated' 'decision=%s rung=%s' \
    "$long_decision" "$long_rung"
fi
rm -rf "$R"

snapshot_of() {  # transcript turn-max -> snapshot JSON; non-zero when the reader refuses
  local dir rc=0
  dir="$(mktemp -d)"
  ( source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
    verdict_audit_snapshot_final_turn "$1" "$dir/snapshot.json" "$2" 262144 ) 2>/dev/null \
    && cat "$dir/snapshot.json" || rc=1
  rm -rf "$dir"
  return "$rc"
}
sha256_of() { perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$1"; }

# Lines come back exactly as a forward read gives them: one spanning several 64 KiB
# blocks, a blank line, CRLF, and a last line without its LF.
R="$(mktemp -d)"; t="$R/transcript.jsonl"
long_claim="$(perl -e 'print "y" x 153600')"
jq -nc '{type:"assistant", message:{content:[{type:"text",text:"OLD_TURN_CLAIM"}]}}' > "$t"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go on"}]}}' >> "$t"
jq -nc --arg c "$long_claim" '{type:"assistant", message:{content:[{type:"text",text:$c}]}}' >> "$t"
printf '\n' >> "$t"
printf '%s\r\n' "$(jq -nc '{type:"assistant", message:{content:[{type:"text",text:"crlf"}]}}')" >> "$t"
printf '%s' "$(jq -nc '{type:"assistant", message:{content:[{type:"text",text:"no final LF"}]}}')" >> "$t"
boundary_snapshot="$(snapshot_of "$t" 67108864)" || boundary_snapshot=""
boundary_texts="$(jq -c '[.records[] | select(.kind == "assistant") | .texts[]]' \
  <<<"$boundary_snapshot" 2>/dev/null)"
if [[ "$boundary_texts" == "$(jq -nc --arg c "$long_claim" '[$c, "crlf", "no final LF"]')" \
   && "$(jq -r '.source_sha256' <<<"$boundary_snapshot")" == "$(sha256_of "$t")" \
   && "$(jq -r '.source_bytes' <<<"$boundary_snapshot")" == "$(wc -c < "$t" | tr -d ' ')" ]]; then
  ok 'block-spanning, blank, CRLF and unterminated lines read as a forward read does'
else
  badf 'block-spanning, blank, CRLF and unterminated lines read as a forward read does' 'texts=%.80s' \
    "$boundary_texts"
fi
rm -rf "$R"

# The decode bound covers the final turn, not the file.
R="$(mktemp -d)"; t="$R/transcript.jsonl"
perl -e 'print qq({"type":"progress","data":"), "z" x 100000, qq("}\n)' > "$t"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go on"}]}}' >> "$t"
jq -nc '{type:"assistant", message:{content:[{type:"text",text:"small turn"}]}}' >> "$t"
small_turn_rc=0; snapshot_of "$t" 4096 >/dev/null || small_turn_rc=$?
jq -nc --arg c "$(perl -e 'print "w" x 8192')" \
  '{type:"assistant", message:{content:[{type:"text",text:$c}]}}' >> "$t"
large_turn_rc=0; snapshot_of "$t" 4096 >/dev/null || large_turn_rc=$?
if [[ "$small_turn_rc" == 0 && "$large_turn_rc" != 0 ]]; then
  ok 'the decode bound covers the final turn, not the file'
else
  badf 'the decode bound covers the final turn, not the file' 'small=%s large=%s' \
    "$small_turn_rc" "$large_turn_rc"
fi
rm -rf "$R"

# History is hashed, not parsed: NUL anywhere still fails, as does a malformed final-turn
# line, but a malformed line before the last real user message does not.
R="$(mktemp -d)"
for history_case in nul malformed-turn malformed-history; do
  t="$R/$history_case.jsonl"
  case "$history_case" in
    nul) printf '{"type":"progress","data":"a\0b"}\n' > "$t" ;;
    malformed-turn) printf '{"type":"progress","data":"ok"}\n' > "$t" ;;
    malformed-history) printf '{"type":"progress","data":\n' > "$t" ;;
  esac
  jq -nc '{type:"user", message:{content:[{type:"text",text:"go on"}]}}' >> "$t"
  jq -nc '{type:"assistant", message:{content:[{type:"text",text:"turn"}]}}' >> "$t"
  [[ "$history_case" == malformed-turn ]] && printf '{"type":"assistant","message":\n' >> "$t"
done
nul_rc=0; snapshot_of "$R/nul.jsonl" 67108864 >/dev/null || nul_rc=$?
turn_rc=0; snapshot_of "$R/malformed-turn.jsonl" 67108864 >/dev/null || turn_rc=$?
history_rc=0; snapshot_of "$R/malformed-history.jsonl" 67108864 >/dev/null || history_rc=$?
if [[ "$nul_rc" != 0 && "$turn_rc" != 0 && "$history_rc" == 0 ]]; then
  ok 'NUL and malformed final-turn lines fail; malformed history is only hashed'
else
  badf 'NUL and malformed final-turn lines fail; malformed history is only hashed' 'nul=%s turn=%s history=%s' \
    "$nul_rc" "$turn_rc" "$history_rc"
fi
rm -rf "$R"

echo
echo "## Harness-agnostic extraction: conventions, not schema lists"
R="$(setup)"; write_codex_transcript "$R" "Root cause is the missing bind mount; all tests pass now."
check "codex rollout schema, verdict → block"                    "$R" "block"
recorded="$(cat "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
if [[ "$recorded" == cksum-* ]]; then
  ok "codex record (no id) → checksum identity recorded"
else
  badf "codex record (no id) → checksum identity recorded" 'recorded=%s' "$recorded"
fi; rm -rf "$R"

R="$(setup)"; write_codex_transcript "$R" "Which retry policy do you prefer here?"
check "codex rollout schema, chat → allow"                       "$R" "allow"; rm -rf "$R"

# Race guard on content identity: same text → same checksum → stale.
R="$(setup)"; write_codex_transcript "$R" "Deploy is healthy."
mkdir -p "$R/.agents/state"; cksum_of "Deploy is healthy." > "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE"
check "codex stale (identity already judged) → allow"            "$R" "allow"; rm -rf "$R"

# The acceptance test for "all kinds of coding agents": a schema NO harness uses
# today must work with ZERO hook changes.
R="$(setup)"; write_future_agent_transcript "$R" "Root cause is the stale DNS cache; fix verified."
check "invented future-agent schema, verdict → block"            "$R" "block"; rm -rf "$R"

R="$(setup)"; write_future_agent_transcript "$R" "Want me to sketch the two options first?"
check "invented future-agent schema, chat → allow"               "$R" "allow"; rm -rf "$R"

# VERDICT_EXTRACTOR_CMD: the escape hatch for a truly alien (non-JSONL) format.
R="$(setup)"; printf 'PLAIN TEXT LOG. verdict: tests pass\n' > "$R/transcript.jsonl"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_EXTRACTOR_CMD='last=""; while IFS= read -r line || [[ -n "$line" ]]; do last="$line"; done < "$1"; printf "%s\n" "$last"' \
      bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "custom extractor (non-JSONL format) → block"
else
  badf "custom extractor (non-JSONL format) → block" 'out=%s' "$out"
fi; rm -rf "$R"

# The extractor is an external producer, so the snapshot cap must close its pipe before
# Bash materializes all stdout in a command-substitution variable. Four MiB is small
# enough for the suite but well beyond the 256 KiB model-visible transcript ceiling.
R="$(setup)"; printf 'ALIEN TRANSCRIPT\n' > "$R/transcript.jsonl"
extractor_script="$R/oversized-extractor"
extractor_progress="$R/extractor-progress"
extractor_complete="$R/extractor-complete"
printf '%s\n' '#!/usr/bin/env perl' \
  'use strict; use warnings;' \
  '$SIG{PIPE} = sub { exit 0 };' \
  'binmode STDOUT; $| = 1;' \
  'for my $index (1 .. 64) {' \
  '  my $chunk = "x" x 65536;' \
  '  my $written = syswrite(STDOUT, $chunk);' \
  '  exit 0 unless defined($written) && $written == length($chunk);' \
  '  open(my $mark, ">", $ENV{EXTRACTOR_PROGRESS}) or exit 2;' \
  '  print {$mark} $index; close($mark) or exit 2;' \
  '}' \
  'open(my $done, ">", $ENV{EXTRACTOR_COMPLETE}) or exit 2;' \
  'print {$done} "complete\n"; close($done) or exit 2;' > "$extractor_script"
chmod +x "$extractor_script"
oversized_extractor_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
oversized_extractor_out="$(printf '%s' "$oversized_extractor_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      EXTRACTOR_PROGRESS="$extractor_progress" \
      EXTRACTOR_COMPLETE="$extractor_complete" \
      VERDICT_EXTRACTOR_CMD="$extractor_script" \
      perl -e 'alarm 5; exec @ARGV' bash "$HOOK") 2>/dev/null)"
oversized_extractor_rc=$?
oversized_extractor_chunks="$(cat "$extractor_progress" 2>/dev/null || echo 0)"
if [[ "$oversized_extractor_rc" -eq 0 && ! -e "$extractor_complete" \
   && "$oversized_extractor_chunks" =~ ^[0-9]+$ \
   && "$oversized_extractor_chunks" -lt 64 ]]; then
  ok "custom extractor stdout is cut off before unbounded Bash materialization"
else
  badf "custom extractor stdout is cut off before unbounded Bash materialization" 'rc=%s chunks=%s complete=%s out=%.120s' \
    "$oversized_extractor_rc" "$oversized_extractor_chunks" \
    "$([[ -e "$extractor_complete" ]] && echo yes || echo no)" \
    "$oversized_extractor_out"
fi; rm -rf "$R"

# The five-second alarm covers the FIFO reader, not just receipt of EOF. An
# extractor that closes stdout and keeps running must be terminated at the same
# absolute deadline instead of sending capture_bounded_extractor into an
# unbounded wait after its reader has already disarmed the alarm. The re-entry marker
# isolates that capture deadline from the independent audit that an initial Stop would
# correctly run after receiving an incomplete snapshot.
R="$(setup)"; printf 'ALIEN TRANSCRIPT\n' > "$R/transcript.jsonl"
closed_extractor="$R/closed-stdout-extractor"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" > "$EXTRACTOR_SLEEP_PID_FILE"' \
  ': > "$EXTRACTOR_SLEEP_READY"' \
  'exec 1>&-' \
  'exec sleep 10' > "$closed_extractor"
chmod +x "$closed_extractor"
closed_extractor_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
closed_extractor_started=$SECONDS
closed_extractor_out="$(printf '%s' "$closed_extractor_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      EXTRACTOR_SLEEP_PID_FILE="$R/closed-extractor.pid" \
      EXTRACTOR_SLEEP_READY="$R/closed-extractor-ready" \
      VERDICT_EXTRACTOR_CMD="$closed_extractor" \
      VERDICT_STOP_REENTRY_EPOCH=- \
      perl -e 'alarm 10; exec @ARGV' bash "$HOOK") 2>/dev/null)"
closed_extractor_rc=$?
closed_extractor_elapsed=$(( SECONDS - closed_extractor_started ))
closed_extractor_pid="$(cat "$R/closed-extractor.pid" 2>/dev/null || true)"
closed_extractor_live=no
if [[ "$closed_extractor_pid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$closed_extractor_pid" 2>/dev/null; then
  closed_extractor_live=yes
fi
kill_test_pids TERM "$closed_extractor_pid"
sleep 0.05
kill_test_pids KILL "$closed_extractor_pid"
if [[ "$closed_extractor_rc" -eq 0 \
   && -e "$R/closed-extractor-ready" \
   && "$closed_extractor_elapsed" -le 8 \
   && "$closed_extractor_live" == no ]]; then
  ok "custom extractor deadline reaps a producer that closed stdout early"
else
  badf "custom extractor deadline reaps a producer that closed stdout early" 'rc=%s elapsed=%ss ready=%s child_live=%s out=%.80s' \
    "$closed_extractor_rc" "$closed_extractor_elapsed" \
    "$([[ -e "$R/closed-extractor-ready" ]] && echo yes || echo no)" \
    "$closed_extractor_live" "$closed_extractor_out"
fi; rm -rf "$R"

echo
echo "## Bounded capture: publication, escaped descendants, and exact cleanup"

if [[ "$(uname -s)" == Darwin ]]; then
  # Explicit overrides may still use pure shell logic under the macOS fork-denial
  # boundary. This is the positive half of the containment contract: the override is
  # restricted, not disabled wholesale.
  R="$(setup)"; write_transcript "$R" \
    "In prose people write things like tests pass when they conclude."
  override_builtin_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
    '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
  override_builtin_out="$(printf '%s' "$override_builtin_payload" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD='while IFS= read -r _line; do :; done; printf "NO\n"' \
        bash "$HOOK") 2>/dev/null)"
  if [[ "$(decision_from_output "$override_builtin_out")" == allow \
     && "$override_builtin_out" == *"triage: NO"* ]]; then
    ok "macOS containment permits a builtin-only classifier override"
  else
    badf "macOS containment permits a builtin-only classifier override" 'out=%.120s' "$override_builtin_out"
  fi
  rm -rf "$R"

  # A helper process would be able to double-fork, close ownership descriptors, and
  # leave the process group. macOS denies that first fork; its output is discarded and
  # regex fallback remains fail-closed.
  R="$(setup)"; write_transcript "$R" \
    "In prose people write things like tests pass when they conclude."
  override_spawn_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
    '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
  override_spawn_cmd='perl -e '\''open(my $f, ">", $ENV{CLAUDE_PROJECT_DIR}."/override-spawned") or exit 2; close($f)'\''; printf "NO\n"'
  override_spawn_out="$(printf '%s' "$override_spawn_payload" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$override_spawn_cmd" bash "$HOOK") 2>/dev/null)"
  if [[ "$(decision_from_output "$override_spawn_out")" == block \
     && ! -e "$R/override-spawned" ]]; then
    ok "macOS containment rejects a child-spawning classifier override"
  else
    badf "macOS containment rejects a child-spawning classifier override" 'spawned=%s out=%.120s' \
      "$([[ -e "$R/override-spawned" ]] && echo yes || echo no)" \
      "$override_spawn_out"
  fi
  rm -rf "$R"

  # Linux hosts without usable unshare must reject only the explicit override. A fake
  # kernel identity exercises that branch on the macOS release host without moving or
  # replacing any system binary.
  R="$(setup)"; write_transcript "$R" "All tests pass."
  linux_unavailable_env="$R/linux-unavailable-env.sh"
  cat > "$linux_unavailable_env" <<'LINUX_UNAVAILABLE_ENV'
if [[ -z "${VERDICT_LINUX_UNAVAILABLE_ENV_LOADED:-}" ]]; then
  export VERDICT_LINUX_UNAVAILABLE_ENV_LOADED=1
  uname() { printf 'Linux\n'; }
fi
LINUX_UNAVAILABLE_ENV
  linux_unavailable_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
    '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
  printf '%s' "$linux_unavailable_payload" \
    | (cd "$R" && BASH_ENV="$linux_unavailable_env" CLAUDE_PROJECT_DIR="$R" \
        VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD=': > "$CLAUDE_PROJECT_DIR/linux-override-ran"; printf "NO\n"' \
        bash "$HOOK") > "$R/linux-unavailable.out" 2> "$R/linux-unavailable.err"
  linux_unavailable_rc=$?
  linux_unavailable_out="$(cat "$R/linux-unavailable.out" 2>/dev/null || true)"
  linux_unavailable_err="$(cat "$R/linux-unavailable.err" 2>/dev/null || true)"
  if [[ "$linux_unavailable_rc" -eq 0 \
     && "$(decision_from_output "$linux_unavailable_out")" == block \
     && ! -e "$R/linux-override-ran" \
     && "$linux_unavailable_err" == *"Linux user/PID namespace support is unavailable"* ]]; then
    ok "Linux without unshare rejects only the explicit override with a diagnostic"
  else
    badf "Linux without unshare rejects only the explicit override with a diagnostic" 'rc=%s ran=%s err=%.120s out=%.100s' \
      "$linux_unavailable_rc" \
      "$([[ -e "$R/linux-override-ran" ]] && echo yes || echo no)" \
      "$linux_unavailable_err" "$linux_unavailable_out"
  fi
  rm -rf "$R"
fi

# DEBUG runs after the background fork and before the next simple command assigns
# $! to active_bounded_capture_pgid. TERM in that exact gap must not leave the
# unpublished sentinel group behind. BASH_ENV scopes the barrier to this hook.
R="$(setup)"; write_transcript "$R" "The culprit was the stale socket path all along."
capture_gap_env="$R/capture-gap-env.sh"
cat > "$capture_gap_env" <<'CAPTURE_GAP_ENV'
if [[ -z "${VERDICT_CAPTURE_GAP_ENV_LOADED:-}" ]]; then
  export VERDICT_CAPTURE_GAP_ENV_LOADED=1
  export VERDICT_CAPTURE_GAP_OWNER_PID="$$"
  printf '%s\n' "$$" > "$VERDICT_CAPTURE_GAP_HOOK_PID_FILE"
  verdict_capture_gap_debug() {
    [[ "$$" == "$VERDICT_CAPTURE_GAP_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == 'active_bounded_capture_pgid=$!' ]] || return 0
    trap - DEBUG
    printf '%s\n' "$!" > "$VERDICT_CAPTURE_GAP_PGID_FILE"
    : > "$VERDICT_CAPTURE_GAP_READY"
    while [[ ! -e "$VERDICT_CAPTURE_GAP_RELEASE" ]]; do
      perl -e 'select undef, undef, undef, 0.01'
    done
  }
  set -T
  trap verdict_capture_gap_debug DEBUG
fi
CAPTURE_GAP_ENV
capture_gap_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
capture_gap_extractor='printf "%s\n" "$$" > "$VERDICT_CAPTURE_GAP_CHILD_PID_FILE"; : > "$VERDICT_CAPTURE_GAP_CHILD_READY"; exec 1>&-; exec sleep 20 #'
(
  printf '%s' "$capture_gap_payload" \
    | (cd "$R" && BASH_ENV="$capture_gap_env" CLAUDE_PROJECT_DIR="$R" \
        VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CAPTURE_GAP_HOOK_PID_FILE="$R/capture-gap-hook.pid" \
        VERDICT_CAPTURE_GAP_PGID_FILE="$R/capture-gap-pgid" \
        VERDICT_CAPTURE_GAP_READY="$R/capture-gap-ready" \
        VERDICT_CAPTURE_GAP_RELEASE="$R/capture-gap-release" \
        VERDICT_CAPTURE_GAP_CHILD_PID_FILE="$R/capture-gap-child.pid" \
        VERDICT_CAPTURE_GAP_CHILD_READY="$R/capture-gap-child-ready" \
        VERDICT_EXTRACTOR_CMD="$capture_gap_extractor" bash "$HOOK")
) > "$R/capture-gap.out" 2> "$R/capture-gap.err" &
capture_gap_job=$!
capture_gap_ready_deadline=$(( SECONDS + 4 ))
while (( SECONDS < capture_gap_ready_deadline )); do
  [[ -e "$R/capture-gap-ready" ]] && break
  kill -0 "$capture_gap_job" 2>/dev/null || break
  perl -e 'select undef, undef, undef, 0.01'
done
capture_gap_hook_pid="$(cat "$R/capture-gap-hook.pid" 2>/dev/null || true)"
capture_gap_pgid="$(cat "$R/capture-gap-pgid" 2>/dev/null || true)"
capture_gap_child_pid="$(cat "$R/capture-gap-child.pid" 2>/dev/null || true)"
capture_gap_barrier=missed
[[ -e "$R/capture-gap-ready" \
   && "$capture_gap_hook_pid" =~ ^[1-9][0-9]*$ \
   && "$capture_gap_pgid" =~ ^[1-9][0-9]*$ ]] \
  && capture_gap_barrier=hit
capture_gap_started=$SECONDS
kill_test_pids TERM "$capture_gap_hook_pid"
: > "$R/capture-gap-release"
capture_gap_deadline=$(( SECONDS + 3 ))
while (( SECONDS < capture_gap_deadline )) \
   && kill -0 "$capture_gap_job" 2>/dev/null; do
  perl -e 'select undef, undef, undef, 0.02'
done
capture_gap_elapsed=$(( SECONDS - capture_gap_started ))
capture_gap_hook_live=no
capture_gap_group_live=no
kill -0 "$capture_gap_hook_pid" 2>/dev/null && capture_gap_hook_live=yes
if [[ "$capture_gap_pgid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 -- "-$capture_gap_pgid" 2>/dev/null; then
  capture_gap_group_live=yes
fi
if [[ "$capture_gap_pgid" =~ ^[1-9][0-9]*$ ]]; then
  kill -TERM -- "-$capture_gap_pgid" 2>/dev/null || true
  kill -KILL -- "-$capture_gap_pgid" 2>/dev/null || true
fi
kill_test_pids KILL "$capture_gap_hook_pid" "$capture_gap_child_pid"
wait "$capture_gap_job" 2>/dev/null; capture_gap_rc=$?
if [[ "$capture_gap_barrier" == hit \
   && "$capture_gap_hook_live/$capture_gap_group_live" == no/no \
   && "$capture_gap_elapsed" -le 3 ]]; then
  ok "TERM across capture fork publication leaves no process group"
else
  badf "TERM across capture fork publication leaves no process group" 'barrier=%s rc=%s elapsed=%ss hook=%s group=%s pgid=%s' \
    "$capture_gap_barrier" "$capture_gap_rc" "$capture_gap_elapsed" \
    "$capture_gap_hook_live" "$capture_gap_group_live" "$capture_gap_pgid"
fi
rm -rf "$R"

# A configurable command can try to create a new session and escape the supervisor's
# process group. The kernel boundary may prevent that fork/session transition outright;
# if a child did start, the marker witness must still account for it before the
# bounded run returns.
escaped_capture_root="$(mktemp -d)"
escaped_capture_script="$escaped_capture_root/escape-capture.sh"
cat > "$escaped_capture_script" <<'ESCAPED_CAPTURE_SCRIPT'
#!/usr/bin/env bash
mode="$1"
perl -MPOSIX -e '
  my ($pid_path, $ready_path) = @ARGV;
  POSIX::setsid() >= 0 or exit 2;
  $SIG{TERM} = "IGNORE";
  $SIG{INT} = "IGNORE";
  open(STDOUT, ">", "/dev/null") or exit 2;
  open(STDERR, ">", "/dev/null") or exit 2;
  open(my $pid, ">", $pid_path) or exit 2;
  print {$pid} "$$\n"; close($pid) or exit 2;
  open(my $ready, ">", $ready_path) or exit 2;
  print {$ready} "ready\n"; close($ready) or exit 2;
  sleep 20;
' "$ESCAPED_CAPTURE_PID_FILE" "$ESCAPED_CAPTURE_READY" &
for (( escape_wait = 0; escape_wait < 300; escape_wait++ )); do
  [[ -e "$ESCAPED_CAPTURE_READY" ]] && break
  perl -e 'select undef, undef, undef, 0.01'
done
[[ -e "$ESCAPED_CAPTURE_READY" ]] || exit 9
case "$mode" in
  classifier) printf 'NO\n' ;;
  extractor) printf 'PLAIN TEXT LOG. verdict: tests pass\n' ;;
  *) exit 9 ;;
esac
exit 0
ESCAPED_CAPTURE_SCRIPT
chmod +x "$escaped_capture_script"
for escaped_capture_mode in classifier extractor; do
  R="$(setup)"
  if [[ "$escaped_capture_mode" == classifier ]]; then
    write_transcript "$R" \
      "In prose people write things like tests pass when they conclude."
    escaped_capture_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
      '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
    escaped_capture_command_env="VERDICT_CLASSIFIER_CMD"
  else
    printf 'ALIEN TRANSCRIPT\n' > "$R/transcript.jsonl"
    escaped_capture_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
      '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
    escaped_capture_command_env="VERDICT_EXTRACTOR_CMD"
  fi
  escaped_capture_started=$SECONDS
  if [[ "$escaped_capture_command_env" == VERDICT_CLASSIFIER_CMD ]]; then
    escaped_capture_out="$(printf '%s' "$escaped_capture_payload" \
      | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
          ESCAPED_CAPTURE_PID_FILE="$R/escaped-capture.pid" \
          ESCAPED_CAPTURE_READY="$R/escaped-capture-ready" \
          VERDICT_CLASSIFIER_CMD="$escaped_capture_script classifier" \
          perl -e 'alarm 8; exec @ARGV' bash "$HOOK") 2>/dev/null)"
  else
    escaped_capture_out="$(printf '%s' "$escaped_capture_payload" \
      | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
          ESCAPED_CAPTURE_PID_FILE="$R/escaped-capture.pid" \
          ESCAPED_CAPTURE_READY="$R/escaped-capture-ready" \
          VERDICT_EXTRACTOR_CMD="$escaped_capture_script extractor" \
          perl -e 'alarm 8; exec @ARGV' bash "$HOOK") 2>/dev/null)"
  fi
  escaped_capture_rc=$?
  escaped_capture_elapsed=$(( SECONDS - escaped_capture_started ))
  escaped_capture_pid="$(cat "$R/escaped-capture.pid" 2>/dev/null || true)"
  escaped_capture_live=no
  if [[ "$escaped_capture_pid" =~ ^[1-9][0-9]*$ ]] \
     && kill -0 "$escaped_capture_pid" 2>/dev/null; then
    escaped_capture_live=yes
  fi
  kill_test_pids KILL "$escaped_capture_pid"
  escaped_capture_safe=no
  if [[ ! -e "$R/escaped-capture-ready" && -z "$escaped_capture_pid" ]] \
     || [[ -e "$R/escaped-capture-ready" && "$escaped_capture_live" == no ]]; then
    escaped_capture_safe=yes
  fi
  if [[ "$escaped_capture_rc" -eq 0 \
     && "$escaped_capture_elapsed" -lt 8 \
     && "$escaped_capture_safe" == yes ]]; then
    ok "$escaped_capture_mode prevents or reaps a setsid TERM-ignoring descendant"
  else
    badf "$escaped_capture_mode prevents or reaps a setsid TERM-ignoring descendant" 'rc=%s elapsed=%ss ready=%s child_live=%s pid=%s out=%.80s' \
      "$escaped_capture_rc" "$escaped_capture_elapsed" \
      "$([[ -e "$R/escaped-capture-ready" ]] && echo yes || echo no)" \
      "$escaped_capture_live" "$escaped_capture_pid" "$escaped_capture_out"
  fi
  rm -rf "$R"
done
rm -rf "$escaped_capture_root"

# A normal daemonization sequence closes every inherited ownership channel after
# escaping the original process group. The hook must either prevent that escape at
# launch or retain a kernel-verifiable lifetime boundary; accepting classifier output
# while the close_fds daemon survives is never a successful bounded capture.
R="$(setup)"; write_transcript "$R" "All tests pass."
closed_marker_script="$R/close-marker-daemon.sh"
cat > "$closed_marker_script" <<'CLOSED_MARKER_SCRIPT'
#!/usr/bin/env bash
perl -MPOSIX -MFcntl=:DEFAULT -e '
  my ($pid_path, $ready_path) = @ARGV;
  my $first = fork();
  exit 2 unless defined($first);
  exit 0 if $first;
  POSIX::setsid() >= 0 or exit 2;
  my $second = fork();
  exit 2 unless defined($second);
  exit 0 if $second;
  $SIG{TERM} = "IGNORE";
  $SIG{INT} = "IGNORE";
  POSIX::close($_) for (0, 1, 2, 9);
  sysopen(my $pid, $pid_path, O_WRONLY | O_CREAT | O_EXCL, 0600) or exit 2;
  print {$pid} "$$\n"; close($pid) or exit 2;
  sysopen(my $ready, $ready_path, O_WRONLY | O_CREAT | O_EXCL, 0600) or exit 2;
  print {$ready} "ready\n"; close($ready) or exit 2;
  sleep 20;
' "$CLOSED_MARKER_PID_FILE" "$CLOSED_MARKER_READY" || exit $?
for (( close_wait = 0; close_wait < 300; close_wait++ )); do
  [[ -e "$CLOSED_MARKER_READY" ]] && break
  perl -e 'select undef, undef, undef, 0.01'
done
[[ -e "$CLOSED_MARKER_READY" ]] || exit 9
printf 'NO\n'
CLOSED_MARKER_SCRIPT
chmod +x "$closed_marker_script"
closed_marker_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
closed_marker_started=$SECONDS
closed_marker_out="$(printf '%s' "$closed_marker_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      CLOSED_MARKER_PID_FILE="$R/closed-marker.pid" \
      CLOSED_MARKER_READY="$R/closed-marker-ready" \
      VERDICT_CLASSIFIER_CMD="$closed_marker_script" \
      perl -e 'alarm 8; exec @ARGV' bash "$HOOK") 2>/dev/null)"
closed_marker_rc=$?
closed_marker_elapsed=$(( SECONDS - closed_marker_started ))
closed_marker_decision="$(decision_from_output "$closed_marker_out")"
closed_marker_pid="$(cat "$R/closed-marker.pid" 2>/dev/null || true)"
closed_marker_live=no
if [[ "$closed_marker_pid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$closed_marker_pid" 2>/dev/null; then
  closed_marker_live=yes
fi
kill_test_pids KILL "$closed_marker_pid"
if [[ "$closed_marker_rc" -eq 0 \
   && "$closed_marker_elapsed" -lt 8 \
   && "$closed_marker_decision" == block \
   && "$closed_marker_live" == no ]]; then
  ok "bounded capture fails closed on a close_fds daemon escape"
else
  badf "bounded capture fails closed on a close_fds daemon escape" 'rc=%s elapsed=%ss ready=%s decision=%s child_live=%s pid=%s out=%.80s' \
    "$closed_marker_rc" "$closed_marker_elapsed" \
    "$([[ -e "$R/closed-marker-ready" ]] && echo yes || echo no)" \
    "$closed_marker_decision" "$closed_marker_live" "$closed_marker_pid" \
    "$closed_marker_out"
fi
rm -rf "$R"

# A TERM handler must not create an unowned late descendant. The isolation boundary
# normally denies the fork; marker rescans remain the defense on a backend where that
# child was already created before teardown froze the producer.
R="$(setup)"; printf 'ALIEN TRANSCRIPT\n' > "$R/transcript.jsonl"
late_escape_script="$R/late-term-escape.sh"
cat > "$late_escape_script" <<'LATE_ESCAPE_SCRIPT'
#!/usr/bin/env bash
late_escape_on_term() {
  trap - TERM
  perl -MPOSIX -e '
    my ($pid_path, $ready_path) = @ARGV;
    POSIX::setsid() >= 0 or exit 2;
    $SIG{TERM} = "IGNORE";
    $SIG{INT} = "IGNORE";
    open(STDOUT, ">", "/dev/null") or exit 2;
    open(STDERR, ">", "/dev/null") or exit 2;
    open(my $pid, ">", $pid_path) or exit 2;
    print {$pid} "$$\n"; close($pid) or exit 2;
    open(my $ready, ">", $ready_path) or exit 2;
    print {$ready} "ready\n"; close($ready) or exit 2;
    sleep 20;
  ' "$LATE_ESCAPE_PID_FILE" "$LATE_ESCAPE_READY" &
  for (( late_wait = 0; late_wait < 100; late_wait++ )); do
    [[ -e "$LATE_ESCAPE_READY" ]] && break
    perl -e 'select undef, undef, undef, 0.005'
  done
}
trap late_escape_on_term TERM
exec 1>&-
sleep 20
LATE_ESCAPE_SCRIPT
chmod +x "$late_escape_script"
late_escape_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
late_escape_started=$SECONDS
late_escape_out="$(printf '%s' "$late_escape_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      LATE_ESCAPE_PID_FILE="$R/late-escape.pid" \
      LATE_ESCAPE_READY="$R/late-escape-ready" \
      VERDICT_EXTRACTOR_CMD="$late_escape_script" \
      perl -e 'alarm 10; exec @ARGV' bash "$HOOK") 2>/dev/null)"
late_escape_rc=$?
late_escape_elapsed=$(( SECONDS - late_escape_started ))
late_escape_pid="$(cat "$R/late-escape.pid" 2>/dev/null || true)"
late_escape_live=no
if [[ "$late_escape_pid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$late_escape_pid" 2>/dev/null; then
  late_escape_live=yes
fi
kill_test_pids KILL "$late_escape_pid"
late_escape_safe=no
if [[ ! -e "$R/late-escape-ready" && -z "$late_escape_pid" ]] \
   || [[ -e "$R/late-escape-ready" && "$late_escape_live" == no ]]; then
  late_escape_safe=yes
fi
if [[ "$late_escape_rc" -eq 0 \
   && "$late_escape_elapsed" -lt 10 \
   && "$late_escape_safe" == yes ]]; then
  ok "teardown prevents or reaps a TERM-spawned setsid descendant"
else
  badf "teardown prevents or reaps a TERM-spawned setsid descendant" 'rc=%s elapsed=%ss ready=%s child_live=%s pid=%s out=%.80s' \
    "$late_escape_rc" "$late_escape_elapsed" \
    "$([[ -e "$R/late-escape-ready" ]] && echo yes || echo no)" \
    "$late_escape_live" "$late_escape_pid" "$late_escape_out"
fi
rm -rf "$R"

# Transcript staging owns the inode created by its exclusive writer, not the pathname
# forever. Swap each relevant filesystem type into the stable stage name immediately
# before cleanup; the replacement must survive and the selected inode may be retired
# only through its recorded device/inode authority.
for transcript_stage_replacement_kind in regular directory symlink fifo; do
  R="$(setup)"; write_transcript "$R" "All tests pass."
  transcript_stage_env="$R/transcript-stage-replace-env.sh"
  cat > "$transcript_stage_env" <<'TRANSCRIPT_STAGE_REPLACE_ENV'
if [[ -z "${VERDICT_TRANSCRIPT_STAGE_REPLACE_ENV_LOADED:-}" ]]; then
  export VERDICT_TRANSCRIPT_STAGE_REPLACE_ENV_LOADED=1
  export VERDICT_TRANSCRIPT_STAGE_REPLACE_OWNER_PID="$$"
  verdict_transcript_stage_replace_debug() {
    [[ "$$" == "$VERDICT_TRANSCRIPT_STAGE_REPLACE_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == 'rm -f "$staged"'* \
       || "$BASH_COMMAND" == 'cleanup_bounded_capture_destination "$staged"'* ]] \
      || return 0
    [[ "${staged:-}" == */verdict-stop-message.jsonl*.stage-* \
       && -f "$staged" && ! -L "$staged" ]] || return 0
    trap - DEBUG
    mv "$staged" "${staged}.selected" || return 0
    case "$VERDICT_TRANSCRIPT_STAGE_REPLACE_KIND" in
      regular) printf 'replacement-sentinel\n' > "$staged" ;;
      directory) mkdir "$staged" ;;
      symlink) ln -s replacement-target "$staged" ;;
      fifo) mkfifo "$staged" ;;
      *) return 0 ;;
    esac
    printf '%s\n' "$staged" > "$VERDICT_TRANSCRIPT_STAGE_REPLACE_PATH"
    : > "$VERDICT_TRANSCRIPT_STAGE_REPLACE_READY"
  }
  set -T
  trap verdict_transcript_stage_replace_debug DEBUG
fi
TRANSCRIPT_STAGE_REPLACE_ENV
  transcript_stage_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
    '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
  transcript_stage_out="$(printf '%s' "$transcript_stage_payload" \
    | (cd "$R" && BASH_ENV="$transcript_stage_env" CLAUDE_PROJECT_DIR="$R" \
        VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_TRANSCRIPT_STAGE_REPLACE_KIND="$transcript_stage_replacement_kind" \
        VERDICT_TRANSCRIPT_STAGE_REPLACE_PATH="$R/transcript-stage.path" \
        VERDICT_TRANSCRIPT_STAGE_REPLACE_READY="$R/transcript-stage.ready" \
        VERDICT_EXTRACTOR_CMD='printf "All tests pass.\n"' \
        bash "$HOOK") 2>/dev/null)"
  transcript_stage_rc=$?
  transcript_stage_path="$(cat "$R/transcript-stage.path" 2>/dev/null || true)"
  transcript_stage_preserved=no
  case "$transcript_stage_replacement_kind" in
    regular) [[ -f "$transcript_stage_path" && ! -L "$transcript_stage_path" \
      && "$(cat "$transcript_stage_path" 2>/dev/null)" == replacement-sentinel ]] \
      && transcript_stage_preserved=yes ;;
    directory) [[ -d "$transcript_stage_path" && ! -L "$transcript_stage_path" ]] \
      && transcript_stage_preserved=yes ;;
    symlink) [[ -L "$transcript_stage_path" \
      && "$(readlink "$transcript_stage_path")" == replacement-target ]] \
      && transcript_stage_preserved=yes ;;
    fifo) [[ -p "$transcript_stage_path" ]] && transcript_stage_preserved=yes ;;
  esac
  if [[ "$transcript_stage_rc" -eq 0 \
     && -e "$R/transcript-stage.ready" \
     && "$transcript_stage_preserved" == yes ]]; then
    ok "transcript cleanup preserves a $transcript_stage_replacement_kind pathname replacement"
  else
    badf "transcript cleanup preserves a $transcript_stage_replacement_kind pathname replacement" 'rc=%s barrier=%s preserved=%s path=%s out=%.80s' \
      "$transcript_stage_rc" \
      "$([[ -e "$R/transcript-stage.ready" ]] && echo hit || echo missed)" \
      "$transcript_stage_preserved" "$transcript_stage_path" "$transcript_stage_out"
  fi
  if [[ -n "$transcript_stage_path" ]]; then
    rm -f "$transcript_stage_path" 2>/dev/null || rmdir "$transcript_stage_path" 2>/dev/null || true
    rm -f "${transcript_stage_path}.selected" 2>/dev/null || true
  fi
  rm -rf "$R"
done

# Failure cleanup may retire only the exact output inode it selected. Swap that
# inode for a sentinel immediately before the cleanup command, then inspect the
# boundary at the following return before the caller performs its own teardown.
R="$(setup)"; write_transcript "$R" "The culprit was the stale socket path all along."
capture_replace_env="$R/capture-replace-env.sh"
cat > "$capture_replace_env" <<'CAPTURE_REPLACE_ENV'
if [[ -z "${VERDICT_CAPTURE_REPLACE_ENV_LOADED:-}" ]]; then
  export VERDICT_CAPTURE_REPLACE_ENV_LOADED=1
  capture_replace_state=waiting
  verdict_capture_replacement_debug() {
    if [[ "$capture_replace_state" == waiting \
       && ( "$BASH_COMMAND" == 'rm -f "$destination"'* \
         || "$BASH_COMMAND" == 'cleanup_bounded_capture_destination "$destination"'* ) \
       && "${destination:-}" == */boxlite-verdict-classifier.*/output \
       && -f "$destination" && ! -L "$destination" ]]; then
      trap - DEBUG
      mv "$destination" "${destination}.selected" || return 0
      printf 'replacement-sentinel\n' > "$destination"
      printf '%s\n' "$destination" > "$VERDICT_CAPTURE_REPLACE_PATH"
      : > "$VERDICT_CAPTURE_REPLACE_READY"
      capture_replace_state=swapped
      trap verdict_capture_replacement_debug DEBUG
      return 0
    fi
    if [[ "$capture_replace_state" == swapped \
       && "$BASH_COMMAND" == 'return 1' ]]; then
      trap - DEBUG
      if [[ -f "$destination" \
         && "$(cat "$destination" 2>/dev/null)" == replacement-sentinel ]]; then
        printf 'preserved\n' > "$VERDICT_CAPTURE_REPLACE_RESULT"
      else
        printf 'removed\n' > "$VERDICT_CAPTURE_REPLACE_RESULT"
      fi
    fi
  }
  set -T
  trap verdict_capture_replacement_debug DEBUG
fi
CAPTURE_REPLACE_ENV
capture_replace_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
capture_replace_out="$(printf '%s' "$capture_replace_payload" \
  | (cd "$R" && BASH_ENV="$capture_replace_env" CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CAPTURE_REPLACE_PATH="$R/capture-replace.path" \
      VERDICT_CAPTURE_REPLACE_READY="$R/capture-replace.ready" \
      VERDICT_CAPTURE_REPLACE_RESULT="$R/capture-replace.result" \
      VERDICT_CLASSIFIER_CMD='printf "NO\n"; exit 7' \
      bash "$HOOK") 2>/dev/null)"
capture_replace_rc=$?
capture_replace_result="$(cat "$R/capture-replace.result" 2>/dev/null || echo missing)"
capture_replace_path="$(cat "$R/capture-replace.path" 2>/dev/null || true)"
if [[ "$capture_replace_rc" -eq 0 \
   && -e "$R/capture-replace.ready" \
   && "$capture_replace_result" == preserved ]]; then
  ok "capture failure cleanup preserves a pathname replacement"
else
  badf "capture failure cleanup preserves a pathname replacement" 'rc=%s barrier=%s replacement=%s path=%s out=%.80s' \
    "$capture_replace_rc" \
    "$([[ -e "$R/capture-replace.ready" ]] && echo hit || echo missed)" \
    "$capture_replace_result" "$capture_replace_path" "$capture_replace_out"
fi
[[ -z "$capture_replace_path" ]] \
  || rm -f "$capture_replace_path" "${capture_replace_path}.selected"
rm -rf "$R"

# Exact unlink must reject a pre-existing pathname replacement before selecting it.
# This is type-independent: directories cannot be hardlinked back from quarantine,
# while symlinks and FIFOs must likewise remain byte/type stable at the public path.
for unlink_replacement_kind in directory symlink fifo; do
  R="$(mktemp -d)"
  unlink_target="$R/output"
  printf 'owned\n' > "$unlink_target"
  unlink_expected_identity="$(
    source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
    verdict_audit_path_identity "$unlink_target"
  )"
  mv "$unlink_target" "$R/original"
  case "$unlink_replacement_kind" in
    directory) mkdir "$unlink_target" ;;
    symlink)   ln -s replacement-target "$unlink_target" ;;
    fifo)      mkfifo "$unlink_target" ;;
  esac
  (
    source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
    verdict_audit_unlink_if_identity \
      "$unlink_target" "$unlink_expected_identity" >/dev/null 2>&1
  )
  unlink_replacement_rc=$?
  unlink_replacement_preserved=no
  case "$unlink_replacement_kind" in
    directory) [[ -d "$unlink_target" && ! -L "$unlink_target" ]] \
      && unlink_replacement_preserved=yes ;;
    symlink) [[ -L "$unlink_target" \
      && "$(readlink "$unlink_target")" == replacement-target ]] \
      && unlink_replacement_preserved=yes ;;
    fifo) [[ -p "$unlink_target" ]] && unlink_replacement_preserved=yes ;;
  esac
  unlink_quarantine_count="$(find "$R" -maxdepth 1 \
    -name 'output.unlink-*' -print | wc -l | tr -d ' ')"
  if [[ "$unlink_replacement_rc" -eq 1 \
     && "$unlink_replacement_preserved" == yes \
     && "$unlink_quarantine_count" -eq 0 ]]; then
    ok "exact unlink preserves a $unlink_replacement_kind replacement in place"
  else
    badf "exact unlink preserves a $unlink_replacement_kind replacement in place" 'rc=%s preserved=%s quarantine=%s' \
      "$unlink_replacement_rc" "$unlink_replacement_preserved" \
      "$unlink_quarantine_count"
  fi
  rm -rf "$R"
done

# A replacement that lands at the checked path immediately before selection must be
# restored without clobbering. Wrap the production rename boundary deterministically;
# the production identity/unlink protocol remains the code under test.
R="$(mktemp -d)"
unlink_target="$R/output"
printf 'owned\n' > "$unlink_target"
(
  source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
  unlink_expected_identity="$(verdict_audit_path_identity "$unlink_target")"
  unlink_selection_race_debug() {
    if [[ "$BASH_COMMAND" == verdict_audit_rename_no_clobber_exact* \
       && "${stable_path:-}" == "$unlink_target" \
       && ! -e "$R/race-fired" ]]; then
      trap - DEBUG
      mv "$unlink_target" "$R/original"
      printf 'replacement\n' > "$unlink_target"
      : > "$R/race-fired"
    fi
  }
  set -T
  trap unlink_selection_race_debug DEBUG
  verdict_audit_unlink_if_identity \
    "$unlink_target" "$unlink_expected_identity" >/dev/null 2>&1
  printf '%s\n' "$?" > "$R/race-rc"
)
unlink_race_rc="$(cat "$R/race-rc" 2>/dev/null || echo missing)"
unlink_race_body="$(cat "$unlink_target" 2>/dev/null || echo missing)"
if [[ -e "$R/race-fired" && "$unlink_race_rc" -eq 1 \
   && "$unlink_race_body" == replacement ]]; then
  ok "exact unlink restores a replacement swapped at selection"
else
  badf "exact unlink restores a replacement swapped at selection" 'barrier=%s rc=%s body=%s' \
    "$([[ -e "$R/race-fired" ]] && echo hit || echo missed)" \
    "$unlink_race_rc" "$unlink_race_body"
fi
rm -rf "$R"

# Identity validation is not deletion authority by itself. Swap each pathname type
# into the selected quarantine immediately after the production validator returns
# success. Cleanup must fail closed, preserve that replacement, and never report that
# the displaced owned inode was consumed.
for unlink_postcheck_kind in regular symlink fifo directory; do
  R="$(mktemp -d)"
  unlink_target="$R/output"
  printf 'owned\n' > "$unlink_target"
  (
    source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
    unlink_expected_identity="$(verdict_audit_path_identity "$unlink_target")"
    verdict_audit_selected_identity_matches() {
      local selected_path="$1" expected_identity="$2" selected_rc
      perl -e '
        my ($path, $expected) = @ARGV;
        exit 1 unless $expected =~ /\A[0-9]+:[0-9]+\z/;
        my @selected = lstat($path);
        exit 1 unless @selected;
        exit(($selected[0] . ":" . $selected[1]) eq $expected ? 0 : 1);
      ' "$selected_path" "$expected_identity"
      selected_rc=$?
      if [[ "$selected_rc" -eq 0 \
         && "$selected_path" == "$unlink_target".unlink-* \
         && ! -e "$R/postcheck-fired" ]]; then
        mv "$selected_path" "$R/displaced-owned"
        case "$unlink_postcheck_kind" in
          regular) printf 'replacement\n' > "$selected_path" ;;
          symlink) ln -s replacement-target "$selected_path" ;;
          fifo) mkfifo "$selected_path" ;;
          directory) mkdir "$selected_path" ;;
        esac
        printf '%s\n' "$selected_path" > "$R/replacement-path"
        : > "$R/postcheck-fired"
      fi
      return "$selected_rc"
    }
    verdict_audit_unlink_if_identity \
      "$unlink_target" "$unlink_expected_identity" >/dev/null 2>&1
    printf '%s\n' "$?" > "$R/postcheck-rc"
  )
  unlink_postcheck_rc="$(cat "$R/postcheck-rc" 2>/dev/null || echo missing)"
  unlink_postcheck_path="$(cat "$R/replacement-path" 2>/dev/null || true)"
  # Failed retirement restores the selected replacement to the API's stable name.
  # If restoration itself cannot publish, it remains at the selected quarantine.
  [[ -e "$unlink_postcheck_path" || -L "$unlink_postcheck_path" ]] \
    || unlink_postcheck_path="$unlink_target"
  unlink_postcheck_preserved=no
  case "$unlink_postcheck_kind" in
    regular) [[ -f "$unlink_postcheck_path" && ! -L "$unlink_postcheck_path" \
      && "$(cat "$unlink_postcheck_path" 2>/dev/null)" == replacement ]] \
      && unlink_postcheck_preserved=yes ;;
    symlink) [[ -L "$unlink_postcheck_path" \
      && "$(readlink "$unlink_postcheck_path")" == replacement-target ]] \
      && unlink_postcheck_preserved=yes ;;
    fifo) [[ -p "$unlink_postcheck_path" ]] && unlink_postcheck_preserved=yes ;;
    directory) [[ -d "$unlink_postcheck_path" && ! -L "$unlink_postcheck_path" ]] \
      && unlink_postcheck_preserved=yes ;;
  esac
  if [[ -e "$R/postcheck-fired" \
     && "$unlink_postcheck_rc" -ne 0 \
     && "$unlink_postcheck_preserved" == yes \
     && "$(cat "$R/displaced-owned" 2>/dev/null)" == owned ]]; then
    ok "exact unlink preserves a post-validation $unlink_postcheck_kind replacement"
  else
    badf "exact unlink preserves a post-validation $unlink_postcheck_kind replacement" 'barrier=%s rc=%s preserved=%s owned=%s path=%s' \
      "$([[ -e "$R/postcheck-fired" ]] && echo hit || echo missed)" \
      "$unlink_postcheck_rc" "$unlink_postcheck_preserved" \
      "$(cat "$R/displaced-owned" 2>/dev/null || echo missing)" \
      "$unlink_postcheck_path"
  fi
  rm -rf "$R"
done

# The epoch-bound publisher owns both its new staging inode and the prior record it
# selected. Race a regular replacement into each checked cleanup name after validation;
# the replacement must remain published at that private pathname and the hook must not
# claim successful retirement of the displaced inode.
for publish_cleanup_kind in staged prior; do
  R="$(setup)"; write_transcript "$R" "Which retry policy do you prefer here?"
  mkdir -p "$R/.agents/state"
  if [[ "$publish_cleanup_kind" == prior ]]; then
    printf 'old-identity\n' > "$R/.agents/state/verdict-last-uuid.$DEFAULT_SCOPE"
  fi
  publish_cleanup_env="$R/publish-cleanup-env.sh"
  cat > "$publish_cleanup_env" <<'PUBLISH_CLEANUP_ENV'
if [[ -z "${VERDICT_PUBLISH_CLEANUP_ENV_LOADED:-}" ]]; then
  export VERDICT_PUBLISH_CLEANUP_ENV_LOADED=1
  export VERDICT_PUBLISH_CLEANUP_OWNER_PID="$$"
  verdict_publish_cleanup_debug() {
    [[ "$$" == "$VERDICT_PUBLISH_CLEANUP_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == verdict_audit_unlink_selected_identity* \
       && -n "${stable_path:-}" && -n "${selected_path:-}" \
       && -e "$selected_path" && ! -L "$selected_path" ]] || return 0
    case "$VERDICT_PUBLISH_CLEANUP_KIND" in
      staged) [[ "$stable_path" == *.stage-* ]] || return 0 ;;
      prior) [[ "$stable_path" == *.prior-* ]] || return 0 ;;
      *) return 0 ;;
    esac
    trap - DEBUG
    mv "$selected_path" "$VERDICT_PUBLISH_CLEANUP_OWNED" || return 0
    printf 'replacement\n' > "$selected_path"
    printf '%s\n' "$stable_path" > "$VERDICT_PUBLISH_CLEANUP_PATH"
    : > "$VERDICT_PUBLISH_CLEANUP_READY"
  }
  set -T
  trap verdict_publish_cleanup_debug DEBUG
fi
PUBLISH_CLEANUP_ENV
  publish_cleanup_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
    '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
  publish_cleanup_out="$(printf '%s' "$publish_cleanup_payload" \
    | (cd "$R" && BASH_ENV="$publish_cleanup_env" CLAUDE_PROJECT_DIR="$R" \
        VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_PUBLISH_CLEANUP_KIND="$publish_cleanup_kind" \
        VERDICT_PUBLISH_CLEANUP_OWNED="$R/publish-cleanup-owned" \
        VERDICT_PUBLISH_CLEANUP_PATH="$R/publish-cleanup.path" \
        VERDICT_PUBLISH_CLEANUP_READY="$R/publish-cleanup.ready" \
        VERDICT_CLASSIFIER_CMD=false bash "$HOOK") 2>/dev/null)"
  publish_cleanup_rc=$?
  publish_cleanup_path="$(cat "$R/publish-cleanup.path" 2>/dev/null || true)"
  if [[ "$publish_cleanup_rc" -eq 0 \
     && -e "$R/publish-cleanup.ready" \
     && -f "$publish_cleanup_path" && ! -L "$publish_cleanup_path" \
     && "$(cat "$publish_cleanup_path" 2>/dev/null)" == replacement \
     && -f "$R/publish-cleanup-owned" ]]; then
    ok "epoch publisher preserves a post-validation $publish_cleanup_kind replacement"
  else
    badf "epoch publisher preserves a post-validation $publish_cleanup_kind replacement" 'rc=%s barrier=%s path=%s preserved=%s out=%.80s' \
      "$publish_cleanup_rc" \
      "$([[ -e "$R/publish-cleanup.ready" ]] && echo hit || echo missed)" \
      "$publish_cleanup_path" \
      "$([[ -f "$publish_cleanup_path" ]] && cat "$publish_cleanup_path" || echo missing)" \
      "$publish_cleanup_out"
  fi
  rm -rf "$R"
done

# Identity publication is part of the exclusive writer transaction. If its stdout is
# closed, the writer must fail and retract only the exact inode it opened.
R="$(mktemp -d)"
identity_stdout_target="$R/output"
(
  source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
  printf 'captured\n' \
    | verdict_audit_write_exclusive_regular_identity \
        "$identity_stdout_target" >&-
) 2>/dev/null
identity_stdout_rc=$?
if [[ "$identity_stdout_rc" -ne 0 && ! -e "$identity_stdout_target" ]]; then
  ok "identity writer retracts its inode when identity publication fails"
else
  badf "identity writer retracts its inode when identity publication fails" 'rc=%s destination=%s' \
    "$identity_stdout_rc" \
    "$([[ -e "$identity_stdout_target" ]] && echo leaked || echo absent)"
fi
rm -rf "$R"

# Snapshot identity publication is the caller's sole cleanup authority. If that
# sidecar cannot cross stdout, the producer must retract its exact stage inode rather
# than leave a pathname the failed caller cannot safely own.
R="$(setup)"; write_transcript "$R" "All tests pass."
snapshot_identity_stdout_target="$R/snapshot-output"
(
  source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
  verdict_audit_snapshot_final_turn_identity \
    "$R/transcript.jsonl" "$snapshot_identity_stdout_target" \
    67108864 262144 >&-
) 2>/dev/null
snapshot_identity_stdout_rc=$?
if [[ "$snapshot_identity_stdout_rc" -ne 0 \
   && ! -e "$snapshot_identity_stdout_target" ]]; then
  ok "snapshot writer retracts its inode when identity publication fails"
else
  badf "snapshot writer retracts its inode when identity publication fails" 'rc=%s destination=%s' \
    "$snapshot_identity_stdout_rc" \
    "$([[ -e "$snapshot_identity_stdout_target" ]] && echo leaked || echo absent)"
fi
rm -rf "$R"

# The capture facade may succeed only with a valid identity sidecar. Corrupt that
# private record at the exact read boundary: classifier NO must be discarded and the
# regex fallback must still block the verdict.
R="$(setup)"; write_transcript "$R" "All tests pass."
identity_sidecar_env="$R/identity-sidecar-env.sh"
cat > "$identity_sidecar_env" <<'IDENTITY_SIDECAR_ENV'
if [[ -z "${VERDICT_IDENTITY_SIDECAR_ENV_LOADED:-}" ]]; then
  export VERDICT_IDENTITY_SIDECAR_ENV_LOADED=1
  identity_sidecar_debug() {
    [[ "$BASH_COMMAND" == 'destination_identity="$(verdict_audit_read_single_record '* ]] \
      || return 0
    trap - DEBUG
    : > "$destination_identity_file"
    : > "$VERDICT_IDENTITY_SIDECAR_READY"
  }
  set -T
  trap identity_sidecar_debug DEBUG
fi
IDENTITY_SIDECAR_ENV
identity_sidecar_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop", session_id:"test-session"}')"
identity_sidecar_out="$(printf '%s' "$identity_sidecar_payload" \
  | (cd "$R" && BASH_ENV="$identity_sidecar_env" CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_IDENTITY_SIDECAR_READY="$R/identity-sidecar-ready" \
      VERDICT_CLASSIFIER_CMD='printf "NO\n"' bash "$HOOK") 2>/dev/null)"
identity_sidecar_decision="$(decision_from_output "$identity_sidecar_out")"
if [[ -e "$R/identity-sidecar-ready" \
   && "$identity_sidecar_decision" == block ]]; then
  ok "capture rejects a missing destination identity sidecar"
else
  badf "capture rejects a missing destination identity sidecar" 'barrier=%s decision=%s out=%.100s' \
    "$([[ -e "$R/identity-sidecar-ready" ]] && echo hit || echo missed)" \
    "$identity_sidecar_decision" "$identity_sidecar_out"
fi
rm -rf "$R"

echo
echo "## Chinese fallback patterns"
R="$(setup)"; write_transcript "$R" "排查结束：根因是 gvproxy 套接字路径冲突，已修复。"
check "中文 verdict (根因是/已修复) → block"                       "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "接下来你想先看哪个模块？我可以先画个调用图。"
check "中文 chat → allow"                                         "$R" "allow"; rm -rf "$R"

echo
echo "## Decision log: every Stop decision leaves one greppable line"
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
decide "$R" >/dev/null
if grep -q ' regex match-block$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "block decision logged (rung + outcome)"
else
  badf "block decision logged (rung + outcome)" 'log=%s' "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Anything else to adjust?"
decide "$R" >/dev/null
if grep -q ' regex none-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "allow decision logged"
else
  badf "allow decision logged" 'log=%s' "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# In-place rotation must not follow a hard link and truncate a file outside runtime
# state. Logging is best-effort, so a multiply linked inode is rejected unchanged.
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
outside_log="$R/outside-owned.log"
decision_log_path="$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE"
mkdir -p "$(dirname "$decision_log_path")"
printf 'outside sentinel\n' > "$outside_log"
ln "$outside_log" "$decision_log_path"
decide "$R" >/dev/null
hardlink_log_state="$(cat "$outside_log" 2>/dev/null || echo MISSING)"
check_eq "decision logging rejects a multiply linked inode" "$hardlink_log_state" "outside sentinel"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."
decision_log_path="$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE"
mkdir -p "$(dirname "$decision_log_path")"
perl -MFcntl=:flock -e '
  my ($path, $ready) = @ARGV;
  open(my $fh, ">>", $path) or exit 2;
  flock($fh, LOCK_EX) or exit 2;
  open(my $mark, ">", $ready) or exit 2;
  close($mark);
  sleep 30;
' "$decision_log_path" "$R/log-lock-ready" & log_holder_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -e "$R/log-lock-ready" ]] && break
  sleep 0.01
done
log_started="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
log_lock_decision="$(decide "$R")"
log_finished="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
kill -TERM "$log_holder_pid" 2>/dev/null || true; wait "$log_holder_pid" 2>/dev/null || true
# The same Stop in a fresh repository, with no writer holding the log, is the baseline.
B="$(setup)"; write_transcript "$B" "Deploy is healthy."
log_base_started="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
decide "$B" >/dev/null
log_base_finished="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
rm -rf "$B"
log_elapsed_ok="$(perl -e 'print(($ARGV[1] - $ARGV[0]) - ($ARGV[3] - $ARGV[2]) < 1.5 ? "yes" : "no")' \
  "$log_started" "$log_finished" "$log_base_started" "$log_base_finished")"
if [[ "$log_elapsed_ok" == yes && "$log_lock_decision" == block ]]; then
  ok "a held decision-log flock cannot delay the Stop decision"
else
  badf "a held decision-log flock cannot delay the Stop decision" 'bounded=%s decision=%s' "$log_elapsed_ok" "$log_lock_decision"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
decide "$R" >/dev/null
if grep -q ' dossier PASS-allow$' "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null; then
  ok "dossier consumption logged"
else
  badf "dossier consumption logged" 'log=%s' "$(cat "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Soft mode (VERDICT_GATE_HARD_BLOCK=0 ONLY): block conditions become nudges"
# Soft is an EXPLICIT opt-out, not the default. It used to be reached by leaving the
# variable unset, which meant only Claude Code — the sole caller that sets it, via
# settings.json env — was ever gated; the Codex registration and any direct
# invocation silently got a nudge. The unset case is asserted to BLOCK below.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
soft_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=0 bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$soft_out" | jq -e '(.decision // "") != "block" and .continue == true and (.systemMessage | type) == "string"' >/dev/null 2>&1; then
  ok "detected verdict → nudge in soft mode, not block"
else
  badf "detected verdict → nudge in soft mode, not block" 'out=%s' "$soft_out"
fi
rm -rf "$R"

R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
unset_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
  | ( cd "$R" && env -u VERDICT_GATE_HARD_BLOCK CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$unset_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "unset VERDICT_GATE_HARD_BLOCK blocks (documented default is hard)"
else
  badf "unset VERDICT_GATE_HARD_BLOCK blocks (documented default is hard)" 'out=%.120s' "$unset_out"
fi
rm -rf "$R"

# One repo per mode. Both calls used to share one, and the first writes
# verdict-last-uuid, so the second returned "transcript unchanged since last
# judgment" without ever consulting its mode — this case named two modes and
# exercised one. Rejecting that short-circuit is part of the assertion: it is an
# allow like any other, so "neither blocked" alone would still pass on it.
chat_ok=yes
chat_detail=""
for chat_mode in 0 1; do
  R="$(setup)"; write_transcript "$R" "Anything else you want changed?"
  chat_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop", session_id:"test-session"}' \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK="$chat_mode" bash "$HOOK" ) 2>/dev/null)"
  if [[ -n "$chat_out" ]] && printf '%s' "$chat_out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
    chat_ok=no
  fi
  printf '%s' "$chat_out" | grep -q 'transcript unchanged' && chat_ok=no
  chat_detail="$chat_detail mode=$chat_mode:$(printf '%.60s' "$chat_out")"
  rm -rf "$R"
done
if [[ "$chat_ok" == "yes" ]]; then
  ok "chat turn → allow via triage in soft AND hard"
else
  bad "chat turn → allow via triage in soft AND hard" "$chat_detail"
fi

# Wait until the gate publishes the hollow snapshot (source_bytes 0), so a test that
# changes the source afterwards is known to be acting after the first read failed —
# a fixed sleep can lose that race on a loaded machine and pass vacuously.
await_hollow_snapshot() {  # repo
  local repo="$1" snapshot deadline=$(( SECONDS + 20 ))
  while (( SECONDS < deadline )); do
    snapshot="$(ls "$repo"/.agents/state/verdict-stop-message.jsonl* 2>/dev/null | head -1)"
    if [[ -n "$snapshot" && -r "$snapshot" ]] \
       && [[ "$(jq -r '.source_bytes // empty' "$snapshot" 2>/dev/null)" == 0 ]]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

echo
echo "## a transcript unreadable at one moment is re-read, not judged incomplete"
# The live failure: the gate reads the transcript while the harness is still appending
# to it, the extractor's two passes disagree on the bytes, and the hollow snapshot it
# publishes reads downstream as "evidence incomplete" — forcing a FAIL dossier about a
# turn nobody actually looked at. A regular file the extractor refuses on sight (only
# NUL bytes) reproduces that moment deterministically, and a helper swaps in
# the settled transcript inside the retry window.
R="$(setup)"
write_transcript "$R" "Nothing here is a verdict; just chatting."
mv "$R/transcript.jsonl" "$R/settled.jsonl"
truncate -s 65M "$R/transcript.jsonl"
( await_hollow_snapshot "$R" && cp "$R/settled.jsonl" "$R/transcript.jsonl" ) &
swap_pid=$!
retry_decision="$(decide "$R")"
wait "$swap_pid" 2>/dev/null || true
# The observable difference is that the turn never reaches the truncated rung at all.
# Asserting on the published snapshot cannot tell the two apart: after a
# truncated-block the gate re-enters itself, and that second pass re-extracts the
# by-then settled file, so both fixed and unfixed end with a good snapshot.
retry_log="$(ls "$R"/.agents/state/verdict-decisions.log* 2>/dev/null | head -1)"
retry_rung="none"
[[ -n "$retry_log" && -r "$retry_log" ]] \
  && grep -q 'extract truncated-block' "$retry_log" && retry_rung="extract truncated-block"
if [[ "$retry_decision" == allow && "$retry_rung" == none ]]; then
  ok 'a settled re-read keeps the turn off the truncated rung'
else
  badf 'a settled re-read keeps the turn off the truncated rung' 'decision=%s rung=%s' \
    "$retry_decision" "$retry_rung"
fi
rm -rf "$R"

# The retry must never turn "unreadable" into "unjudged". A refresh that publishes no
# snapshot — the transcript vanished, or it never settles — has to leave the turn on
# the same truncated-block path it took before the retry existed.
check_still_blocks() {  # desc repo
  local desc="$1" repo="$2" decision log rung
  decision="$(decide "$repo")"
  log="$(ls "$repo"/.agents/state/verdict-decisions.log* 2>/dev/null | head -1)"
  # The truncated-block rung is what must appear; a later dossier rung may follow it
  # once the audit it triggers comes back.
  rung="none"
  [[ -n "$log" && -r "$log" ]] \
    && grep -q 'extract truncated-block' "$log" && rung="extract truncated-block"
  if [[ "$decision" == block && "$rung" == "extract truncated-block" ]]; then
    ok "$desc"
  else
    badf "$desc" 'decision=%s rung=%s' "$decision" "$rung"
  fi
}

# Publication precedes retry setup: polling for the hollow snapshot can delete the
# source on either side of that check. Force both orderings and require the FAIL
# dossier, so an auditor-startup error cannot masquerade as the expected block.
for retry_boundary in before-arm refresh-delete refresh-empty; do
  for retry_mode in session session-payload; do
    retry_session=retry-session; retry_payload_text=""
    [[ "$retry_mode" == *-payload ]] && retry_payload_text="Just chatting."
    R="$(setup)"
    mkdir -p "$R/.agents/state"
    truncate -s 65M "$R/transcript.jsonl"
    retry_env="$R/.agents/state/retry-env.sh"
    cat > "$retry_env" <<'RETRY_ENV'
if [[ -z "${VERDICT_RETRY_ENV_LOADED:-}" ]]; then
  export VERDICT_RETRY_ENV_LOADED=1
  verdict_retry_debug() {
    case "$VERDICT_RETRY_BOUNDARY" in
      before-arm)
        [[ "$BASH_COMMAND" == 'AUDIT_TRANSCRIPT_SOURCE_KIND="failed"' ]] || return 0 ;;
      refresh-*)
        [[ "$BASH_COMMAND" == 'prepare_audit_transcript "$AUDIT_TRANSCRIPT_SOURCE_PATH" refresh'* ]] || return 0 ;;
    esac
    trap - DEBUG
    if [[ "$VERDICT_RETRY_BOUNDARY" == refresh-empty ]]; then
      : > "$CLAUDE_PROJECT_DIR/transcript.jsonl"
    else
      rm -f "$CLAUDE_PROJECT_DIR/transcript.jsonl"
    fi
    : > "$CLAUDE_PROJECT_DIR/.agents/state/retry-boundary-hit"
  }
  set -T
  trap verdict_retry_debug DEBUG
fi
RETRY_ENV
    retry_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s "$retry_session" \
      --arg t "$retry_payload_text" \
      '{transcript_path:$p,hook_event_name:"Stop",last_assistant_message:$t,session_id:$s}')"
    retry_out="$(BASH_ENV="$retry_env" VERDICT_RETRY_BOUNDARY="$retry_boundary" \
      run_payload_hook "$R" "$retry_payload")"
    retry_decision="$(decision_from_output "$retry_out")"
    retry_state="decision=$retry_decision boundary=missed evidence=missing dossier=missing"
    [[ -e "$R/.agents/state/retry-boundary-hit" ]] \
      && retry_state="${retry_state/boundary=missed/boundary=hit}"
    retry_snapshot="$(session_state_path "$R" verdict-stop-message.jsonl "$retry_session")"
    if jq -e '.truncated == true and .source_bytes == 0' \
        "$retry_snapshot" >/dev/null 2>&1; then
      retry_state="${retry_state/evidence=missing/evidence=incomplete}"
    fi
    if [[ "$retry_out" == *"independent audit finding"* ]] \
       && grep -q ' extract truncated-block$' "$R"/.agents/state/verdict-decisions.log* \
       && grep -q ' dossier FAIL-block$' "$R"/.agents/state/verdict-decisions.log*; then
      retry_state="${retry_state/dossier=missing/dossier=FAIL}"
    fi
    check_eq "unreadable transcript $retry_boundary ($retry_mode) consumes FAIL" \
      "$retry_state" "decision=block boundary=hit evidence=incomplete dossier=FAIL"
    rm -rf "$R"
  done
done

R="$(setup)"
truncate -s 65M "$R/transcript.jsonl"
check_still_blocks "a transcript that never settles still blocks as unreadable" "$R"
rm -rf "$R"

# A symlink is refused by the extractor for being a link, whatever it points at, so
# arming it would spend the whole retry window on a source that can never be read.
R="$(setup)"
write_transcript "$R" "Nothing here is a verdict; just chatting."
mv "$R/transcript.jsonl" "$R/target.jsonl"
ln -s "$R/target.jsonl" "$R/transcript.jsonl"
symlink_decision="$(decide "$R")"
symlink_elapsed="$(sed -n 's/.* elapsed_seconds=\([0-9]*\) .* extract truncated-block$/\1/p' \
  "$R/.agents/state/verdict-decisions.log.$DEFAULT_SCOPE" 2>/dev/null | head -n 1)"
symlink_elapsed="${symlink_elapsed:-unlogged}"
if [[ "$symlink_decision" == block && "$symlink_elapsed" =~ ^[0-9]+$ && "$symlink_elapsed" -lt 2 ]]; then
  ok 'a symlinked transcript fails closed without spending the retry window'
else
  badf 'a symlinked transcript fails closed without spending the retry window' 'decision=%s elapsed=%ss' \
    "$symlink_decision" "$symlink_elapsed"
fi
rm -rf "$R"

# The session's decision log names the rung that decided, including after the audit
# child re-enters the check. Its scope suffix is the Git object hash of the session id.
printf '\n## The decision log records the rung that decided\n'
decided_rung() {  # repo classifier-answer -> rung and outcome of the last logged decision
  local log
  log="$1/.agents/state/verdict-decisions.log.git-$(printf decision-log | git -C "$1" hash-object --stdin)"
  jq -nc --arg p "$1/transcript.jsonl" \
    '{transcript_path:$p, hook_event_name:"Stop", session_id:"decision-log"}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$2")" bash "$HOOK" ) >/dev/null 2>&1
  tail -n 1 "$log" 2>/dev/null | awk '{print $(NF-1), $NF}'
}
R="$(setup)"; write_transcript "$R" "Nothing here is a verdict; just chatting."
rung="$(decided_rung "$R" NO)"
check_eq 'a triage allow reports its rung' "$rung" "triage NO-allow"
rm -rf "$R"
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
rung="$(decided_rung "$R" YES)"
check_eq 'the re-entered audit child reports the rung that decided' "$rung" "dossier FAIL-block"
rm -rf "$R"

assert_result
