#!/usr/bin/env bash
# Tests for .agents/hooks/post-remote-write-watch.sh
#
# Covers:
#   1. Command matcher: git push / gh pr writes vs. unrelated bash, chained and
#      multi-line forms, literal mentions.
#   2. Failure handling: a rejected or no-op push must not arm anything.
#   3. PR-number resolution from the tool response.
#
# `gh` is stubbed on PATH — this suite makes no network calls.
#
# Run with:  bash .agents/hooks/post-remote-write-watch.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whatever checkout the shell happens to sit in, so
# running this suite from another directory silently tests that checkout's hook
# instead of the one shipped beside these tests — a reverted-hook two-side check
# then reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/post-remote-write-watch.sh"
WATCHER="$REPO_ROOT/.agents/watch/pr-watch.sh"
POLICY="$REPO_ROOT/.agents/watch/escalation-policy.md"
# shellcheck source=../lib/pr-watch-state.sh
source "$REPO_ROOT/.agents/lib/pr-watch-state.sh"
# shellcheck source=../lib/verdict-audit-state.sh
source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# Only `gh pr list --json number` is reached from the hook.
printf '%s\n' "${STUB_PR_NUMBER:-}"
EOF
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"

# The hook's opt-out, and the one knob CONTRIBUTING tells developers to export.
# Inherited from the caller it silences every arm case, giving the same 17/14 the
# detached-cwd bug did — loud, but attributed to the wrong thing: 14 arm cases fail
# for a reason that is nowhere in the diff being tested. The dedicated case below
# sets it explicitly.
unset BOXLITE_PR_WATCH

# Hermetic repo. The hook reads `git branch --show-current` from its cwd and exits
# 0 when that is empty, so run from a detached worktree every "should arm" case
# reported passthrough and the suite scored 17/14 instead of 31/0. Pin the branch
# and the remote here, so that together with the unset above the suite gives the
# same answer wherever it is invoked from.
REPO="$TMP/repo"
git init -q -b harness-branch "$REPO"
git -C "$REPO" remote add origin git@github.com:acme/widget.git
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$REPO" || exit 1

pass=0
fail=0

# Feed a PostToolUse payload; report "armed" when the hook injects context.
run() {
  local desc="$1" cmd="$2" resp="$3" expect="$4" out decision
  out=$(jq -nc --arg c "$cmd" --arg r "$resp" \
          '{tool_input:{command:$c}, tool_response:{stdout:$r, stderr:""}}' \
        | "$HOOK" 2>/dev/null)
  if [[ -z "$out" ]]; then
    decision="passthrough"
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    decision="armed"
  else
    decision="parse_error"
  fi
  if [[ "$decision" == "$expect" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (got=%s expected=%s)\n' "$desc" "$decision" "$expect"
  fi
}

export STUB_PR_NUMBER=42

echo "## Matcher: should pass through"
run "ls"                          "ls"                        ""  "passthrough"
run "git status"                  "git status"                ""  "passthrough"
run "git commit (not a push)"     "git commit -m x"           ""  "passthrough"
run "gh pr list"                  "gh pr list"                ""  "passthrough"
run "gh pr view"                  "gh pr view 42"             ""  "passthrough"
run "gh issue create"             "gh issue create -t x"      ""  "passthrough"
run "echo literal git push"       "echo 'git push'"           ""  "passthrough"
run "echo literal gh pr create"   "echo 'gh pr create'"       ""  "passthrough"
run "heredoc body mentions push"  $'git commit -m "$(cat <<\'EOF\'\nmentions `git push`\nEOF\n)"' "" "passthrough"

echo
echo "## Matcher: should arm"
run "git push direct"             "git push"                  ""  "armed"
run "git push with args"          "git push -u origin feat"   ""  "armed"
run "gh pr create"                "gh pr create -t x"         ""  "armed"
run "gh pr ready"                 "gh pr ready 42"            ""  "armed"
run "gh pr comment"               "gh pr comment 42 -b hi"    ""  "armed"
run "gh pr review"                "gh pr review 42 -a"        ""  "armed"
run "chained with &&"             "cd x && git push"          ""  "armed"
run "chained with ;"              "echo done; git push"       ""  "armed"
run "env var prefix"              "FOO=bar git push"          ""  "armed"
run "newline before verb"         $'cd x\ngit push'           ""  "armed"

echo
echo "## Failed remote writes must not arm"
run "rejected push"               "git push" "! [rejected] main -> main (fetch first)" "passthrough"
run "fatal push"                  "git push" "fatal: repository not found"             "passthrough"
run "everything up-to-date"       "git push" "Everything up-to-date"                   "passthrough"
run "permission denied"           "git push" "Permission denied (publickey)"           "passthrough"
run "remote rejected"             "git push" "! [remote rejected] main -> main (pre-receive hook declined)" "passthrough"
# git's generic summary line. A local pre-push hook that exits non-zero (this
# repo's own audit gate) prints ONLY this — no 'fatal:', no '[rejected]' — so
# without it the hook reports a blocked push as a successful remote write.
run "pre-push hook declined"      "git push" "error: failed to push some refs to 'github.com:boxlite-ai/boxlite.git'" "passthrough"
run "src refspec error"           "git push" "error: src refspec main does not match any" "passthrough"

echo
echo "## Opt-out"
out=$(jq -nc '{tool_input:{command:"git push"}, tool_response:{stdout:"",stderr:""}}' \
      | BOXLITE_PR_WATCH=0 "$HOOK" 2>/dev/null)
if [[ -z "$out" ]]; then
  pass=$((pass + 1)); printf '  PASS  BOXLITE_PR_WATCH=0 passes through\n'
else
  fail=$((fail + 1)); printf '  FAIL  BOXLITE_PR_WATCH=0 passes through (got output)\n'
fi

echo
echo "## PR resolution"
# Both plugin roots are cleared so the default is genuinely the unknown host. Running
# the suite from inside a hook would otherwise leave a real root exported, and every
# case built on this would quietly exercise that host's route instead.
ctx() {
  jq -nc --arg c "$1" --arg r "$2" \
     '{tool_input:{command:$c}, tool_response:{stdout:$r, stderr:""}}' \
   | env -u CLAUDE_PLUGIN_ROOT -u PLUGIN_ROOT "$HOOK" 2>/dev/null \
   | jq -r '.hookSpecificOutput.additionalContext // ""'
}

ctx_at() { # repo, command, response
  local repo="$1" cmd="$2" response="$3"
  (cd "$repo" && jq -nc --arg c "$cmd" --arg r "$response" \
     '{tool_input:{command:$c}, tool_response:{stdout:$r, stderr:""}}' \
   | "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
}

ctx_session_at() { # repo, session, command, response
  local repo="$1" session="$2" cmd="$3" response="$4"
  (cd "$repo" && jq -nc --arg session "$session" --arg c "$cmd" --arg r "$response" \
     '{session_id:$session,tool_input:{command:$c},tool_response:{stdout:$r,stderr:""}}' \
   | "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
}

attachment_key_for() { # session-scope command-hash
  local digest
  digest="$(printf 'scope=%s\ncommand=%s' "$1" "$2" \
    | shasum -a 256 | awk '{print $1}')"
  printf 'attach-%s' "$digest"
}

write_attachment_manifest() { # repo session command entries-json [omitted] [prompt-epoch]
  local repo="$1" session="$2" command="$3" entries="$4" omitted="${5:-0}"
  local prompt_epoch="${6:-1-1-0}"
  local state_dir state_root scope command_hash key owner_token prompt_epoch_path
  state_dir="$(git -C "$repo" rev-parse --git-path pr-watch)"
  [[ "$state_dir" == /* ]] || state_dir="$(cd "$repo" && pwd -P)/$state_dir"
  state_root="$repo/.agents/state"
  mkdir -p "$state_dir" "$state_root"
  scope="git-$(printf '%s' "$session" | git -C "$repo" hash-object --stdin)"
  command_hash="$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')"
  key="$(attachment_key_for "$scope" "$command_hash")"
  owner_token="$(verdict_audit_process_start_token "$$")"
  prompt_epoch_path="$(verdict_audit_state_path "$state_root/verdict-prompt-epoch" "$scope")"
  printf '%s\n' "$prompt_epoch" | verdict_audit_write_atomic "$prompt_epoch_path"
  jq -nc --arg command_hash "$command_hash" --arg scope "$scope" \
    --arg prompt_epoch "$prompt_epoch" \
    --argjson owner_pid "$$" --arg owner_token "$owner_token" \
    --argjson created_at "$(date +%s)" --argjson entries "$entries" \
    --argjson omitted "$omitted" \
    '{schema:1,command_hash:$command_hash,session_scope:$scope,created_at:$created_at,
      prompt_epoch:$prompt_epoch,owner:{pid:$owner_pid,start_token:$owner_token},
      entries:$entries,omitted_refs:$omitted}' \
    > "$state_dir/${key}.json"
  printf '%s' "$state_dir/${key}.json"
}

stream_command_from_context() {
  sed -n '/Stream command:/{n;s/^[[:space:]]*//;p;q;}'
}

EXEC_STUB="$TMP/exec-bin"
mkdir -p "$EXEC_STUB"
cat > "$EXEC_STUB/bash" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" "$@" > "$WATCH_ARGS_FILE"
EOF
chmod +x "$EXEC_STUB/bash"
cat > "$EXEC_STUB/tail" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" "$@" > "$WATCH_ARGS_FILE"
EOF
chmod +x "$EXEC_STUB/tail"

attachment_claim_from_command() { # rendered-command
  local rendered_command="$1" args_file="$TMP/attachment-command-args"
  : > "$args_file"
  WATCH_ARGS_FILE="$args_file" PATH="$EXEC_STUB:$PATH" \
    /bin/bash -c "$rendered_command" >/dev/null 2>/dev/null || return 1
  sed -n '3p' "$args_file"
}

consume_attachment_claim() { # claim-path
  local claim="$1" identity snapshot body body_hash
  identity="$(verdict_audit_path_identity "$claim" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$claim" 2>/dev/null)" || return 1
  [[ "$snapshot" == *$'\n'* ]] || return 1
  body="${snapshot#*$'\n'}"
  body_hash="$(LC_ALL=C printf '%s' "$body" | shasum -a 256 | awk '{print $1}')" \
    || return 1
  pr_watch_consume_regular_file "$claim" "$identity" "$body_hash" 2>/dev/null
}

echo
echo "## Exact pushed-ref attachment"
ATTACH_SCRIPT="$REPO_ROOT/.agents/watch/pr-watch-attach.sh"
ATTACH_SESSION="post-watch-session"
OTHER_COMMAND="git push origin refs/heads/local:refs/heads/other"
OTHER_KEY="$(pr_watch_branch_key other)"
OTHER_LOG="$(git -C "$REPO" rev-parse --git-path pr-watch)/$OTHER_KEY.jsonl"
[[ "$OTHER_LOG" == /* ]] || OTHER_LOG="$(cd "$REPO" && pwd -P)/$OTHER_LOG"
OTHER_ENTRIES="$(jq -nc --arg log "$OTHER_LOG" \
  '[{remote_ref:"refs/heads/other",branch:"other",watch_id:"watch-111111111111111111111111",event_log:$log}]')"
OTHER_MANIFEST="$(write_attachment_manifest "$REPO" "$ATTACH_SESSION" "$OTHER_COMMAND" "$OTHER_ENTRIES")"
other_context="$(ctx_session_at "$REPO" "$ATTACH_SESSION" "$OTHER_COMMAND" "")"
other_command="$(printf '%s' "$other_context" | stream_command_from_context)"
other_args="$TMP/other-watch-args"
WATCH_ARGS_FILE="$other_args" PATH="$EXEC_STUB:$PATH" \
  /bin/bash -c "$other_command" >/dev/null 2>"$TMP/other-watch.err"
other_status=$?
other_claim="$(sed -n '3p' "$other_args" 2>/dev/null)"
other_identity="$(jq -r '.entries[0] | .remote_ref + ":" + .branch + ":" + .watch_id + ":" + .event_log' "$other_claim" 2>/dev/null)"
other_ack=no
if [[ -n "$other_claim" ]] && consume_attachment_claim "$other_claim"; then
  other_ack=yes
fi
other_replay_context="$(ctx_session_at "$REPO" "$ATTACH_SESSION" "$OTHER_COMMAND" "")"
if [[ "$other_status" -eq 0 \
   && "$(sed -n '2p' "$other_args" 2>/dev/null)" == "$ATTACH_SCRIPT" \
   && "$other_claim" != "$OTHER_MANIFEST" && -e "$OTHER_MANIFEST" \
   && "$other_ack" == yes && -z "$other_replay_context" \
   && "$other_identity" \
      == "refs/heads/other:other:watch-111111111111111111111111:$OTHER_LOG" ]]; then
  pass=$((pass + 1)); printf '  PASS  explicit local:other attaches once to the armed remote generation\n'
else
  fail=$((fail + 1)); printf '  FAIL  explicit local:other attaches once to the armed remote generation (status=%s args=%s stable=%s replay=%s claim=%s)\n' \
    "$other_status" "$(tr '\n' '|' < "$other_args" 2>/dev/null)" \
    "$([[ -e "$OTHER_MANIFEST" ]] && echo present || echo missing)" \
    "$([[ -n "$other_replay_context" ]] && echo armed || echo rejected)" "$other_claim"
fi

MULTI_COMMAND="git push origin refs/heads/one:refs/heads/remote-one refs/heads/two:refs/heads/remote-two"
ONE_KEY="$(pr_watch_branch_key remote-one)"
TWO_KEY="$(pr_watch_branch_key remote-two)"
STATE_DIR="$(git -C "$REPO" rev-parse --git-path pr-watch)"
[[ "$STATE_DIR" == /* ]] || STATE_DIR="$(cd "$REPO" && pwd -P)/$STATE_DIR"
MULTI_ENTRIES="$(jq -nc \
  --arg one "$STATE_DIR/$ONE_KEY.jsonl" --arg two "$STATE_DIR/$TWO_KEY.jsonl" \
  '[{remote_ref:"refs/heads/remote-one",branch:"remote-one",watch_id:"watch-222222222222222222222222",event_log:$one},
    {remote_ref:"refs/heads/remote-two",branch:"remote-two",watch_id:"watch-333333333333333333333333",event_log:$two}]')"
MULTI_MANIFEST="$(write_attachment_manifest "$REPO" "$ATTACH_SESSION" "$MULTI_COMMAND" "$MULTI_ENTRIES")"
multi_context="$(ctx_session_at "$REPO" "$ATTACH_SESSION" "$MULTI_COMMAND" "")"
multi_command="$(printf '%s' "$multi_context" | stream_command_from_context)"
multi_args="$TMP/multi-watch-args"
WATCH_ARGS_FILE="$multi_args" PATH="$EXEC_STUB:$PATH" \
  /bin/bash -c "$multi_command" >/dev/null 2>"$TMP/multi-watch.err"
multi_status=$?
multi_claim="$(sed -n '3p' "$multi_args" 2>/dev/null)"
multi_identity="$(jq -r '[.entries[] | .remote_ref + ":" + .watch_id] | join("|")' "$multi_claim" 2>/dev/null)"
multi_ack=no
if [[ -n "$multi_claim" ]] && consume_attachment_claim "$multi_claim"; then
  multi_ack=yes
fi
multi_replay_context="$(ctx_session_at "$REPO" "$ATTACH_SESSION" "$MULTI_COMMAND" "")"
if [[ "$multi_status" -eq 0 \
   && "$(sed -n '2p' "$multi_args" 2>/dev/null)" == "$ATTACH_SCRIPT" \
   && "$multi_claim" != "$MULTI_MANIFEST" && -e "$MULTI_MANIFEST" \
   && "$multi_ack" == yes && -z "$multi_replay_context" \
   && "$multi_identity" == "refs/heads/remote-one:watch-222222222222222222222222|refs/heads/remote-two:watch-333333333333333333333333" ]]; then
  pass=$((pass + 1)); printf '  PASS  one push attaches both exact remote generations once\n'
else
  fail=$((fail + 1)); printf '  FAIL  one push attaches both exact remote generations once (status=%s args=%s replay=%s identity=%s)\n' \
    "$multi_status" "$(tr '\n' '|' < "$multi_args" 2>/dev/null)" \
    "$([[ -n "$multi_replay_context" ]] && echo armed || echo rejected)" "$multi_identity"
fi

STALE_SESSION="post-watch-stale-session"
STALE_COMMAND="git push origin refs/heads/local:refs/heads/stale"
STALE_KEY="$(pr_watch_branch_key stale)"
STALE_LOG="$STATE_DIR/$STALE_KEY.jsonl"
STALE_ENTRIES="$(jq -nc --arg log "$STALE_LOG" \
  '[{remote_ref:"refs/heads/stale",branch:"stale",watch_id:"watch-444444444444444444444444",event_log:$log}]')"
STALE_MANIFEST="$(write_attachment_manifest \
  "$REPO" "$STALE_SESSION" "$STALE_COMMAND" "$STALE_ENTRIES" 0 "1-1-0")"
stale_scope="git-$(printf '%s' "$STALE_SESSION" | git -C "$REPO" hash-object --stdin)"
stale_epoch_path="$(verdict_audit_state_path \
  "$REPO/.agents/state/verdict-prompt-epoch" "$stale_scope")"
printf '2-2-0\n' | verdict_audit_write_atomic "$stale_epoch_path"
stale_context="$(ctx_session_at "$REPO" "$STALE_SESSION" "$STALE_COMMAND" "")"
if [[ -z "$stale_context" && -e "$STALE_MANIFEST" ]]; then
  pass=$((pass + 1)); printf '  PASS  attachment from an older prompt epoch is ignored without consumption\n'
else
  fail=$((fail + 1)); printf '  FAIL  attachment from an older prompt epoch is ignored without consumption (context=%.80s stable=%s)\n' \
    "$stale_context" "$([[ -e "$STALE_MANIFEST" ]] && echo present || echo consumed)"
fi

# The PostToolUse check above closes a race before the command is rendered. The
# rendered three-argument claim is itself a delayed capability, so the consumer
# must repeat both lifecycle checks immediately before it consumes that claim.
REVOKED_CLAIM_SESSION="post-watch-revoked-rendered-claim"
REVOKED_CLAIM_COMMAND="git push origin refs/heads/local:refs/heads/revoked-rendered-claim"
REVOKED_CLAIM_BRANCH="revoked-rendered-claim"
REVOKED_CLAIM_ID="watch-555555555555555555555555"
REVOKED_CLAIM_KEY="$(pr_watch_branch_key "$REVOKED_CLAIM_BRANCH")"
REVOKED_CLAIM_LOG="$STATE_DIR/$REVOKED_CLAIM_KEY.jsonl"
REVOKED_CLAIM_ENTRIES="$(jq -nc --arg branch "$REVOKED_CLAIM_BRANCH" \
  --arg id "$REVOKED_CLAIM_ID" --arg log "$REVOKED_CLAIM_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$REVOKED_CLAIM_SESSION" \
  "$REVOKED_CLAIM_COMMAND" "$REVOKED_CLAIM_ENTRIES" >/dev/null
revoked_claim_context="$(ctx_session_at "$REPO" "$REVOKED_CLAIM_SESSION" \
  "$REVOKED_CLAIM_COMMAND" "")"
revoked_claim_command="$(printf '%s' "$revoked_claim_context" \
  | stream_command_from_context)"
revoked_claim_path="$(attachment_claim_from_command \
  "$revoked_claim_command" 2>/dev/null)"
revoked_claim_scope="git-$(printf '%s' "$REVOKED_CLAIM_SESSION" \
  | git -C "$REPO" hash-object --stdin)"
revoked_claim_epoch_path="$(verdict_audit_state_path \
  "$REPO/.agents/state/verdict-prompt-epoch" "$revoked_claim_scope")"
printf '2-2-0\n' | verdict_audit_write_atomic "$revoked_claim_epoch_path"
jq -nc --arg id "$REVOKED_CLAIM_ID" '{kind:"watch_start",watch_id:$id}' \
  > "$REVOKED_CLAIM_LOG"
jq -nc --arg id "$REVOKED_CLAIM_ID" \
  '{kind:"watch_end",watch_id:$id,reason:"revoked claim must not run"}' \
  >> "$REVOKED_CLAIM_LOG"
PR_WATCH_STREAM_WAIT=1 /bin/bash -c "$revoked_claim_command" \
  >"$TMP/revoked-rendered-claim.out" 2>"$TMP/revoked-rendered-claim.err"
revoked_claim_status=$?
revoked_claim_events="$(jq -s 'length' \
  "$TMP/revoked-rendered-claim.out" 2>/dev/null || printf invalid)"
revoked_claim_consumed=no
if [[ -f "$revoked_claim_path" ]] \
   && grep -q '^consumed:' "$revoked_claim_path" 2>/dev/null; then
  revoked_claim_consumed=yes
fi
if [[ -n "$revoked_claim_command" && "$revoked_claim_status" -ne 0 \
   && "$revoked_claim_events" == 0 && "$revoked_claim_consumed" == no \
   && -s "$TMP/revoked-rendered-claim.err" ]]; then
  pass=$((pass + 1)); printf '  PASS  rendered claim rechecks prompt-epoch revocation before consumption\n'
else
  fail=$((fail + 1)); printf '  FAIL  rendered claim rechecks prompt-epoch revocation before consumption (command=%s status=%s events=%s consumed=%s stderr=%.120s)\n' \
    "$([[ -n "$revoked_claim_command" ]] && echo present || echo missing)" \
    "$revoked_claim_status" "$revoked_claim_events" "$revoked_claim_consumed" \
    "$(tr '\n' ' ' < "$TMP/revoked-rendered-claim.err" 2>/dev/null)"
fi

# The lifecycle check must be adjacent to the one-shot consume. Branch
# validation calls external helpers, so revocation while that validation is in
# flight must still reject the claim without consuming it.
RACE_CLAIM_SESSION="post-watch-racing-rendered-claim"
RACE_CLAIM_COMMAND="git push origin refs/heads/local:refs/heads/racing-rendered-claim"
RACE_CLAIM_BRANCH="racing-rendered-claim"
RACE_CLAIM_ID="watch-777777777777777777777777"
RACE_CLAIM_KEY="$(pr_watch_branch_key "$RACE_CLAIM_BRANCH")"
RACE_CLAIM_LOG="$STATE_DIR/$RACE_CLAIM_KEY.jsonl"
RACE_CLAIM_ENTRIES="$(jq -nc --arg branch "$RACE_CLAIM_BRANCH" \
  --arg id "$RACE_CLAIM_ID" --arg log "$RACE_CLAIM_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$RACE_CLAIM_SESSION" \
  "$RACE_CLAIM_COMMAND" "$RACE_CLAIM_ENTRIES" >/dev/null
race_claim_context="$(ctx_session_at "$REPO" "$RACE_CLAIM_SESSION" \
  "$RACE_CLAIM_COMMAND" "")"
race_claim_command="$(printf '%s' "$race_claim_context" \
  | stream_command_from_context)"
race_claim_path="$(attachment_claim_from_command \
  "$race_claim_command" 2>/dev/null)"
race_claim_scope="git-$(printf '%s' "$RACE_CLAIM_SESSION" \
  | git -C "$REPO" hash-object --stdin)"
race_claim_epoch_path="$(verdict_audit_state_path \
  "$REPO/.agents/state/verdict-prompt-epoch" "$race_claim_scope")"
jq -nc --arg id "$RACE_CLAIM_ID" '{kind:"watch_start",watch_id:$id}' \
  > "$RACE_CLAIM_LOG"
jq -nc --arg id "$RACE_CLAIM_ID" \
  '{kind:"watch_end",watch_id:$id,reason:"racing claim must not run"}' \
  >> "$RACE_CLAIM_LOG"

RACE_CLAIM_BIN="$TMP/rendered-claim-race-bin"
RACE_CLAIM_REAL_SHASUM="$(command -v shasum)"
RACE_CLAIM_COUNT="$TMP/rendered-claim-race.count"
RACE_CLAIM_BLOCKED="$TMP/rendered-claim-race.blocked"
RACE_CLAIM_RELEASE="$TMP/rendered-claim-race.release"
mkdir -p "$RACE_CLAIM_BIN"
cat > "$RACE_CLAIM_BIN/shasum" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -r "$RACE_CLAIM_COUNT" ]] || read -r count < "$RACE_CLAIM_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$RACE_CLAIM_COUNT"
if [[ "$count" -eq 2 ]]; then
  : > "$RACE_CLAIM_BLOCKED"
  while [[ ! -e "$RACE_CLAIM_RELEASE" ]]; do sleep 0.01; done
fi
exec "$RACE_CLAIM_REAL_SHASUM" "$@"
EOF
chmod +x "$RACE_CLAIM_BIN/shasum"
PATH="$RACE_CLAIM_BIN:$PATH" \
RACE_CLAIM_REAL_SHASUM="$RACE_CLAIM_REAL_SHASUM" \
RACE_CLAIM_COUNT="$RACE_CLAIM_COUNT" RACE_CLAIM_BLOCKED="$RACE_CLAIM_BLOCKED" \
RACE_CLAIM_RELEASE="$RACE_CLAIM_RELEASE" PR_WATCH_STREAM_WAIT=1 \
  /bin/bash -c "$race_claim_command" \
  >"$TMP/rendered-claim-race.out" 2>"$TMP/rendered-claim-race.err" &
race_claim_pid=$!
race_claim_barrier=missed
for _ in {1..300}; do
  if [[ -e "$RACE_CLAIM_BLOCKED" ]]; then
    race_claim_barrier=hit
    break
  fi
  kill -0 "$race_claim_pid" 2>/dev/null || break
  sleep 0.01
done
printf '2-2-0\n' | verdict_audit_write_atomic "$race_claim_epoch_path"
: > "$RACE_CLAIM_RELEASE"
wait "$race_claim_pid"
race_claim_status=$?
race_claim_events="$(jq -s 'length' \
  "$TMP/rendered-claim-race.out" 2>/dev/null || printf invalid)"
race_claim_consumed=no
if [[ -f "$race_claim_path" ]] \
   && grep -q '^consumed:' "$race_claim_path" 2>/dev/null; then
  race_claim_consumed=yes
fi
if [[ "$race_claim_barrier" == hit && "$race_claim_status" -ne 0 \
   && "$race_claim_events" == 0 && "$race_claim_consumed" == no \
   && -s "$TMP/rendered-claim-race.err" ]]; then
  pass=$((pass + 1)); printf '  PASS  rendered claim closes revocation race at consumption\n'
else
  fail=$((fail + 1)); printf '  FAIL  rendered claim closes revocation race at consumption (barrier=%s status=%s events=%s consumed=%s stderr=%.120s)\n' \
    "$race_claim_barrier" "$race_claim_status" "$race_claim_events" \
    "$race_claim_consumed" \
    "$(tr '\n' ' ' < "$TMP/rendered-claim-race.err" 2>/dev/null)"
fi

EXPIRED_CLAIM_SESSION="post-watch-expired-rendered-claim"
EXPIRED_CLAIM_COMMAND="git push origin refs/heads/local:refs/heads/expired-rendered-claim"
EXPIRED_CLAIM_BRANCH="expired-rendered-claim"
EXPIRED_CLAIM_ID="watch-666666666666666666666666"
EXPIRED_CLAIM_KEY="$(pr_watch_branch_key "$EXPIRED_CLAIM_BRANCH")"
EXPIRED_CLAIM_LOG="$STATE_DIR/$EXPIRED_CLAIM_KEY.jsonl"
EXPIRED_CLAIM_ENTRIES="$(jq -nc --arg branch "$EXPIRED_CLAIM_BRANCH" \
  --arg id "$EXPIRED_CLAIM_ID" --arg log "$EXPIRED_CLAIM_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$EXPIRED_CLAIM_SESSION" \
  "$EXPIRED_CLAIM_COMMAND" "$EXPIRED_CLAIM_ENTRIES" >/dev/null
expired_claim_context="$(ctx_session_at "$REPO" "$EXPIRED_CLAIM_SESSION" \
  "$EXPIRED_CLAIM_COMMAND" "")"
expired_claim_command="$(printf '%s' "$expired_claim_context" \
  | stream_command_from_context)"
expired_claim_path="$(attachment_claim_from_command \
  "$expired_claim_command" 2>/dev/null)"
expired_claim_at=$(( $(date +%s) - 601 ))
if [[ -n "$expired_claim_path" ]]; then
  perl -e 'my $time = shift; utime($time, $time, @ARGV) == @ARGV or exit 1' \
    "$expired_claim_at" "$expired_claim_path"
fi
jq -nc --arg id "$EXPIRED_CLAIM_ID" '{kind:"watch_start",watch_id:$id}' \
  > "$EXPIRED_CLAIM_LOG"
jq -nc --arg id "$EXPIRED_CLAIM_ID" \
  '{kind:"watch_end",watch_id:$id,reason:"expired claim must not run"}' \
  >> "$EXPIRED_CLAIM_LOG"
PR_WATCH_STREAM_WAIT=1 /bin/bash -c "$expired_claim_command" \
  >"$TMP/expired-rendered-claim.out" 2>"$TMP/expired-rendered-claim.err"
expired_claim_status=$?
expired_claim_events="$(jq -s 'length' \
  "$TMP/expired-rendered-claim.out" 2>/dev/null || printf invalid)"
expired_claim_consumed=no
if [[ -f "$expired_claim_path" ]] \
   && grep -q '^consumed:' "$expired_claim_path" 2>/dev/null; then
  expired_claim_consumed=yes
fi
if [[ -n "$expired_claim_command" && "$expired_claim_status" -ne 0 \
   && "$expired_claim_events" == 0 && "$expired_claim_consumed" == no \
   && -s "$TMP/expired-rendered-claim.err" ]]; then
  pass=$((pass + 1)); printf '  PASS  rendered claim rechecks its 600-second lease before consumption\n'
else
  fail=$((fail + 1)); printf '  FAIL  rendered claim rechecks its 600-second lease before consumption (command=%s status=%s events=%s consumed=%s stderr=%.120s)\n' \
    "$([[ -n "$expired_claim_command" ]] && echo present || echo missing)" \
    "$expired_claim_status" "$expired_claim_events" "$expired_claim_consumed" \
    "$(tr '\n' ' ' < "$TMP/expired-rendered-claim.err" 2>/dev/null)"
fi

CONSUMED_SLOT_SESSION="post-watch-consumed-slots"
CONSUMED_SLOT_COMMAND="git push origin refs/heads/local:refs/heads/consumed-slots"
CONSUMED_SLOT_BRANCH="consumed-slots"
CONSUMED_SLOT_KEY="$(pr_watch_branch_key "$CONSUMED_SLOT_BRANCH")"
CONSUMED_SLOT_LOG="$STATE_DIR/$CONSUMED_SLOT_KEY.jsonl"
consumed_slot_setup="yes"
for consumed_slot_index in 0 1 2 3; do
  consumed_slot_watch_id="watch-$(printf '%024x' "$((consumed_slot_index + 32))")"
  consumed_slot_entries="$(jq -nc --arg branch "$CONSUMED_SLOT_BRANCH" \
    --arg id "$consumed_slot_watch_id" --arg log "$CONSUMED_SLOT_LOG" \
    '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
  write_attachment_manifest "$REPO" "$CONSUMED_SLOT_SESSION" \
    "$CONSUMED_SLOT_COMMAND" "$consumed_slot_entries" >/dev/null
  consumed_slot_context="$(ctx_session_at "$REPO" "$CONSUMED_SLOT_SESSION" \
    "$CONSUMED_SLOT_COMMAND" "")"
  consumed_slot_command="$(printf '%s' "$consumed_slot_context" \
    | stream_command_from_context)"
  consumed_slot_claim="$(attachment_claim_from_command \
    "$consumed_slot_command" 2>/dev/null)"
  if [[ -z "$consumed_slot_claim" ]] \
     || ! consume_attachment_claim "$consumed_slot_claim"; then
    consumed_slot_setup="no"
    break
  fi
done
consumed_slot_fresh_id="watch-$(printf '%024x' 36)"
consumed_slot_fresh_entries="$(jq -nc --arg branch "$CONSUMED_SLOT_BRANCH" \
  --arg id "$consumed_slot_fresh_id" --arg log "$CONSUMED_SLOT_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$CONSUMED_SLOT_SESSION" \
  "$CONSUMED_SLOT_COMMAND" "$consumed_slot_fresh_entries" >/dev/null
consumed_slot_fresh_context="$(ctx_session_at "$REPO" "$CONSUMED_SLOT_SESSION" \
  "$CONSUMED_SLOT_COMMAND" "")"
consumed_slot_fresh_command="$(printf '%s' "$consumed_slot_fresh_context" \
  | stream_command_from_context)"
if [[ "$consumed_slot_setup" == "yes" && -n "$consumed_slot_fresh_command" ]]; then
  pass=$((pass + 1)); printf '  PASS  consumed attachment claims are reusable without a 600-second wait\n'
else
  fail=$((fail + 1)); printf '  FAIL  consumed attachment claims are reusable without a 600-second wait (setup=%s fresh=%s)\n' \
    "$consumed_slot_setup" "$([[ -n "$consumed_slot_fresh_command" ]] && echo armed || echo exhausted)"
fi

LIVE_SLOT_SESSION="post-watch-live-slots"
LIVE_SLOT_COMMAND="git push origin refs/heads/local:refs/heads/live-slots"
LIVE_SLOT_BRANCH="live-slots"
LIVE_SLOT_KEY="$(pr_watch_branch_key "$LIVE_SLOT_BRANCH")"
LIVE_SLOT_LOG="$STATE_DIR/$LIVE_SLOT_KEY.jsonl"
live_slot_setup="yes"
live_slot_commands=()
live_slot_claims=()
for live_slot_index in 0 1 2 3; do
  live_slot_watch_id="watch-$(printf '%024x' "$((live_slot_index + 48))")"
  live_slot_entries="$(jq -nc --arg branch "$LIVE_SLOT_BRANCH" \
    --arg id "$live_slot_watch_id" --arg log "$LIVE_SLOT_LOG" \
    '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
  write_attachment_manifest "$REPO" "$LIVE_SLOT_SESSION" \
    "$LIVE_SLOT_COMMAND" "$live_slot_entries" >/dev/null
  live_slot_context="$(ctx_session_at "$REPO" "$LIVE_SLOT_SESSION" \
    "$LIVE_SLOT_COMMAND" "")"
  live_slot_command="$(printf '%s' "$live_slot_context" | stream_command_from_context)"
  live_slot_claim="$(attachment_claim_from_command "$live_slot_command" 2>/dev/null)"
  if [[ -z "$live_slot_command" || -z "$live_slot_claim" || ! -f "$live_slot_claim" ]]; then
    live_slot_setup="no"
    break
  fi
  live_slot_commands+=("$live_slot_command")
  live_slot_claims+=("$live_slot_claim")
done

# Advance the claim lease without sleeping. The JSON creation time remains recent,
# so only claim retirement — not stable-manifest expiry — can release a slot.
live_slot_expired_at=$(( $(date +%s) - 601 ))
if [[ "$live_slot_setup" == "yes" ]]; then
  perl -e 'my $time = shift; utime($time, $time, @ARGV) == @ARGV or exit 1' \
    "$live_slot_expired_at" "${live_slot_claims[@]}" || live_slot_setup="no"
fi

live_slot_fresh_id="watch-$(printf '%024x' 52)"
live_slot_fresh_entries="$(jq -nc --arg branch "$LIVE_SLOT_BRANCH" \
  --arg id "$live_slot_fresh_id" --arg log "$LIVE_SLOT_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$LIVE_SLOT_SESSION" \
  "$LIVE_SLOT_COMMAND" "$live_slot_fresh_entries" >/dev/null
live_slot_fresh_context="$(ctx_session_at "$REPO" "$LIVE_SLOT_SESSION" \
  "$LIVE_SLOT_COMMAND" "")"
live_slot_fresh_command="$(printf '%s' "$live_slot_fresh_context" \
  | stream_command_from_context)"
live_slot_fresh_claim="$(attachment_claim_from_command \
  "$live_slot_fresh_command" 2>/dev/null)"

live_slot_old_command="${live_slot_commands[0]-}"
live_slot_reused_path="no"
if [[ -n "$live_slot_fresh_claim" ]]; then
  for live_slot_index in 0 1 2 3; do
    if [[ "${live_slot_claims[$live_slot_index]-}" == "$live_slot_fresh_claim" ]]; then
      live_slot_old_command="${live_slot_commands[$live_slot_index]}"
      live_slot_reused_path="yes"
      break
    fi
  done
fi

jq -nc --arg id "$live_slot_fresh_id" '{kind:"watch_start",watch_id:$id}' \
  > "$LIVE_SLOT_LOG"
jq -nc --arg id "$live_slot_fresh_id" \
  '{kind:"watch_end",watch_id:$id,reason:"lease regression complete"}' \
  >> "$LIVE_SLOT_LOG"
live_slot_old_status=1
live_slot_fresh_status=1
if [[ "$live_slot_setup" == "yes" && -n "$live_slot_fresh_command" \
   && -n "$live_slot_old_command" ]]; then
  PR_WATCH_STREAM_WAIT=1 /bin/bash -c "$live_slot_old_command" \
    >"$TMP/live-slot-old.out" 2>"$TMP/live-slot-old.err"
  live_slot_old_status=$?
  PR_WATCH_STREAM_WAIT=1 /bin/bash -c "$live_slot_fresh_command" \
    >"$TMP/live-slot-fresh.out" 2>"$TMP/live-slot-fresh.err"
  live_slot_fresh_status=$?
fi
if [[ "$live_slot_setup" == "yes" && -n "$live_slot_fresh_command" \
   && "$live_slot_reused_path" == "yes" && "$live_slot_old_status" -ne 0 \
   && "$live_slot_fresh_status" -eq 0 ]]; then
  pass=$((pass + 1)); printf '  PASS  expired live claims recover without old-command ABA consumption\n'
else
  fail=$((fail + 1)); printf '  FAIL  expired live claims recover without old-command ABA consumption (setup=%s fresh=%s reused=%s old_status=%s fresh_status=%s)\n' \
    "$live_slot_setup" "$([[ -n "$live_slot_fresh_command" ]] && echo armed || echo exhausted)" \
    "$live_slot_reused_path" "$live_slot_old_status" "$live_slot_fresh_status"
fi

# Claim retirement must mutate only its already-opened inode. Hook that exact-fd
# mutation boundary, replace the checked name while the helper is paused, and
# prove retirement cannot remove or rewrite the replacement. PERL5OPT installs
# only this test's one-shot truncate wrapper; production code remains unchanged.
CLAIM_RETIRE_RACE_LIB="$TMP/claim-retire-lib"
CLAIM_RETIRE_RACE_ROOT="$TMP/claim-retire-race"
CLAIM_RETIRE_RACE_PATH="$STATE_DIR/claim-retire-race.json.claim.0"
mkdir -p "$CLAIM_RETIRE_RACE_LIB" "$CLAIM_RETIRE_RACE_ROOT"
cat > "$CLAIM_RETIRE_RACE_LIB/PrWatchRetireRace.pm" <<'CLAIM_RETIRE_MODULE_EOF'
package PrWatchRetireRace;
use strict;
use warnings;
BEGIN {
  my $armed = 1;
  *CORE::GLOBAL::truncate = sub (*$) {
    my @opened = @_ == 2 ? stat($_[0]) : ();
    my @named = defined($ENV{PR_WATCH_RETIRE_RACE_PATH})
      ? lstat($ENV{PR_WATCH_RETIRE_RACE_PATH}) : ();
    if ($armed && @_ == 2 && $_[1] == 0
        && @opened && @named
        && $opened[0] == $named[0] && $opened[1] == $named[1]) {
      $armed = 0;
      open(my $ready, ">", $ENV{PR_WATCH_RETIRE_RACE_READY}) or die $!;
      print {$ready} "ready\n";
      close($ready) or die $!;
      until (-e $ENV{PR_WATCH_RETIRE_RACE_RELEASE}) {
        select(undef, undef, undef, 0.01);
      }
    }
    return CORE::truncate($_[0], $_[1]);
  };
}
1;
CLAIM_RETIRE_MODULE_EOF
printf 'consumed:1:2:%064d\n' 0 > "$CLAIM_RETIRE_RACE_PATH"
(
  export PERL5LIB="$CLAIM_RETIRE_RACE_LIB"
  export PERL5OPT=-MPrWatchRetireRace
  export PR_WATCH_RETIRE_RACE_PATH="$CLAIM_RETIRE_RACE_PATH"
  export PR_WATCH_RETIRE_RACE_READY="$CLAIM_RETIRE_RACE_ROOT/ready"
  export PR_WATCH_RETIRE_RACE_RELEASE="$CLAIM_RETIRE_RACE_ROOT/release"
  pr_watch_retire_attachment_claim "$CLAIM_RETIRE_RACE_PATH" "$(date +%s)" 600
) > "$CLAIM_RETIRE_RACE_ROOT/out" 2> "$CLAIM_RETIRE_RACE_ROOT/err" \
  & CLAIM_RETIRE_RACE_JOB=$!
CLAIM_RETIRE_RACE_DEADLINE=$(( SECONDS + 5 ))
while (( SECONDS < CLAIM_RETIRE_RACE_DEADLINE )); do
  [[ -e "$CLAIM_RETIRE_RACE_ROOT/ready" ]] && break
  kill -0 "$CLAIM_RETIRE_RACE_JOB" 2>/dev/null || break
  sleep 0.02
done
CLAIM_RETIRE_RACE_BARRIER=missed
if [[ -e "$CLAIM_RETIRE_RACE_ROOT/ready" && -f "$CLAIM_RETIRE_RACE_PATH" ]]; then
  CLAIM_RETIRE_RACE_BARRIER=hit
  mv "$CLAIM_RETIRE_RACE_PATH" "$CLAIM_RETIRE_RACE_PATH.original"
  printf 'replacement\n' > "$CLAIM_RETIRE_RACE_PATH"
fi
touch "$CLAIM_RETIRE_RACE_ROOT/release"
( sleep 4; kill -KILL "$CLAIM_RETIRE_RACE_JOB" 2>/dev/null || true ) \
  & CLAIM_RETIRE_RACE_WATCHDOG=$!
wait "$CLAIM_RETIRE_RACE_JOB" 2>/dev/null; CLAIM_RETIRE_RACE_RC=$?
kill "$CLAIM_RETIRE_RACE_WATCHDOG" 2>/dev/null || true
wait "$CLAIM_RETIRE_RACE_WATCHDOG" 2>/dev/null || true
CLAIM_RETIRE_RACE_REPLACEMENT=gone
[[ -f "$CLAIM_RETIRE_RACE_PATH" \
   && "$(cat "$CLAIM_RETIRE_RACE_PATH" 2>/dev/null)" == replacement ]] \
  && CLAIM_RETIRE_RACE_REPLACEMENT=preserved
if [[ "$CLAIM_RETIRE_RACE_BARRIER/$CLAIM_RETIRE_RACE_REPLACEMENT" \
   == "hit/preserved" ]]; then
  pass=$((pass + 1)); printf '  PASS  claim retirement preserves a post-validation pathname replacement\n'
else
  fail=$((fail + 1)); printf '  FAIL  claim retirement removed a post-validation pathname replacement (barrier=%s rc=%s replacement=%s)\n' \
    "$CLAIM_RETIRE_RACE_BARRIER" "$CLAIM_RETIRE_RACE_RC" \
    "$CLAIM_RETIRE_RACE_REPLACEMENT"
fi

# Closing the hook during the optional PR lookup, before claim selection, must
# leave the original manifest retryable and reap the lookup in one bounded
# cancellation window. BASH_ENV scopes the blocker to this hook.
CANCEL_CLAIM_SESSION="post-watch-cancelled-claim"
CANCEL_CLAIM_COMMAND="git push origin refs/heads/local:refs/heads/cancelled-claim"
CANCEL_CLAIM_BRANCH="cancelled-claim"
CANCEL_CLAIM_ID="watch-999999999999999999999999"
CANCEL_CLAIM_KEY="$(pr_watch_branch_key "$CANCEL_CLAIM_BRANCH")"
CANCEL_CLAIM_LOG="$STATE_DIR/$CANCEL_CLAIM_KEY.jsonl"
CANCEL_CLAIM_ENTRIES="$(jq -nc --arg branch "$CANCEL_CLAIM_BRANCH" \
  --arg id "$CANCEL_CLAIM_ID" --arg log "$CANCEL_CLAIM_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
CANCEL_CLAIM_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$CANCEL_CLAIM_SESSION" "$CANCEL_CLAIM_COMMAND" "$CANCEL_CLAIM_ENTRIES")"
CANCEL_CLAIM_MANIFEST_BODY="$(cat "$CANCEL_CLAIM_MANIFEST")"
CANCEL_CLAIM_MANIFEST_IDENTITY="$(verdict_audit_path_identity \
  "$CANCEL_CLAIM_MANIFEST")"
CANCEL_CLAIM_MANIFEST_HASH="$(LC_ALL=C printf '%s' \
  "$CANCEL_CLAIM_MANIFEST_BODY" | shasum -a 256 | awk '{print $1}')"
CANCEL_CLAIM_ROOT="$TMP/cancelled-claim"
CANCEL_CLAIM_ENV="$CANCEL_CLAIM_ROOT/bash-env.sh"
CANCEL_CLAIM_BLOCKER="$CANCEL_CLAIM_ROOT/gh-blocker.sh"
mkdir -p "$CANCEL_CLAIM_ROOT"
cat > "$CANCEL_CLAIM_BLOCKER" <<'CANCEL_CLAIM_BLOCKER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$CANCEL_CLAIM_LOOKUP_PID_FILE"
: > "$CANCEL_CLAIM_LOOKUP_READY"
sleep 20
CANCEL_CLAIM_BLOCKER_EOF
chmod +x "$CANCEL_CLAIM_BLOCKER"
cat > "$CANCEL_CLAIM_ENV" <<'CANCEL_CLAIM_ENV_EOF'
if [[ -z "${CANCEL_CLAIM_HOOK_PID:-}" ]]; then
  export CANCEL_CLAIM_HOOK_PID="$$"
  printf '%s\n' "$$" > "$CANCEL_CLAIM_HOOK_PID_FILE"
fi
gh() {
  if [[ "${1-}" == pr && "${2-}" == list ]]; then
    "$CANCEL_CLAIM_GH_BLOCKER" "$@"
  else
    command gh "$@"
  fi
}
CANCEL_CLAIM_ENV_EOF
CANCEL_CLAIM_PAYLOAD="$(jq -nc --arg session "$CANCEL_CLAIM_SESSION" \
  --arg command "$CANCEL_CLAIM_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$CANCEL_CLAIM_ENV" \
    CANCEL_CLAIM_HOOK_PID_FILE="$CANCEL_CLAIM_ROOT/hook.pid" \
    CANCEL_CLAIM_LOOKUP_PID_FILE="$CANCEL_CLAIM_ROOT/lookup.pid" \
    CANCEL_CLAIM_LOOKUP_READY="$CANCEL_CLAIM_ROOT/lookup.ready" \
    CANCEL_CLAIM_GH_BLOCKER="$CANCEL_CLAIM_BLOCKER" \
    bash "$HOOK" <<< "$CANCEL_CLAIM_PAYLOAD"
) > "$CANCEL_CLAIM_ROOT/hook.out" 2> "$CANCEL_CLAIM_ROOT/hook.err" \
  & CANCEL_CLAIM_JOB=$!
CANCEL_CLAIM_READY_DEADLINE=$(( SECONDS + 3 ))
CANCEL_CLAIM_PATH=""
while (( SECONDS < CANCEL_CLAIM_READY_DEADLINE )); do
  [[ -e "$CANCEL_CLAIM_ROOT/lookup.ready" \
     && -s "$CANCEL_CLAIM_ROOT/hook.pid" \
     && -s "$CANCEL_CLAIM_ROOT/lookup.pid" ]] && break
  kill -0 "$CANCEL_CLAIM_JOB" 2>/dev/null || break
  sleep 0.02
done
CANCEL_CLAIM_HOOK_PID="$(cat "$CANCEL_CLAIM_ROOT/hook.pid" 2>/dev/null || true)"
CANCEL_CLAIM_LOOKUP_PID="$(cat "$CANCEL_CLAIM_ROOT/lookup.pid" 2>/dev/null || true)"
for CANCEL_CLAIM_CANDIDATE in \
    "${CANCEL_CLAIM_MANIFEST}.claim.0" \
    "${CANCEL_CLAIM_MANIFEST}.claim.1" \
    "${CANCEL_CLAIM_MANIFEST}.claim.2" \
    "${CANCEL_CLAIM_MANIFEST}.claim.3"; do
  if [[ -f "$CANCEL_CLAIM_CANDIDATE" \
     && "$(cat "$CANCEL_CLAIM_CANDIDATE" 2>/dev/null)" \
        == "$CANCEL_CLAIM_MANIFEST_BODY" ]]; then
    CANCEL_CLAIM_PATH="$CANCEL_CLAIM_CANDIDATE"
    break
  fi
done
CANCEL_CLAIM_BARRIER=missed
[[ -e "$CANCEL_CLAIM_ROOT/lookup.ready" \
   && "$CANCEL_CLAIM_HOOK_PID" =~ ^[1-9][0-9]*$ \
   && "$CANCEL_CLAIM_LOOKUP_PID" =~ ^[1-9][0-9]*$ ]] \
  && CANCEL_CLAIM_BARRIER=hit
CANCEL_CLAIM_TERM_STARTED=$SECONDS
if [[ "$CANCEL_CLAIM_HOOK_PID" =~ ^[1-9][0-9]*$ ]]; then
  kill -TERM "$CANCEL_CLAIM_HOOK_PID" 2>/dev/null || true
fi
CANCEL_CLAIM_TERM_DEADLINE=$(( CANCEL_CLAIM_TERM_STARTED + 3 ))
while (( SECONDS < CANCEL_CLAIM_TERM_DEADLINE )); do
  CANCEL_CLAIM_HOOK_LIVE=no
  CANCEL_CLAIM_LOOKUP_LIVE=no
  [[ "$CANCEL_CLAIM_HOOK_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$CANCEL_CLAIM_HOOK_PID" 2>/dev/null \
    && CANCEL_CLAIM_HOOK_LIVE=yes
  [[ "$CANCEL_CLAIM_LOOKUP_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$CANCEL_CLAIM_LOOKUP_PID" 2>/dev/null \
    && CANCEL_CLAIM_LOOKUP_LIVE=yes
  [[ "$CANCEL_CLAIM_HOOK_LIVE/$CANCEL_CLAIM_LOOKUP_LIVE" == no/no ]] \
    && break
  sleep 0.05
done
CANCEL_CLAIM_TERM_ELAPSED=$(( SECONDS - CANCEL_CLAIM_TERM_STARTED ))
CANCEL_CLAIM_HOOK_LIVE=no
CANCEL_CLAIM_LOOKUP_LIVE=no
[[ "$CANCEL_CLAIM_HOOK_PID" =~ ^[1-9][0-9]*$ ]] \
  && kill -0 "$CANCEL_CLAIM_HOOK_PID" 2>/dev/null \
  && CANCEL_CLAIM_HOOK_LIVE=yes
[[ "$CANCEL_CLAIM_LOOKUP_PID" =~ ^[1-9][0-9]*$ ]] \
  && kill -0 "$CANCEL_CLAIM_LOOKUP_PID" 2>/dev/null \
  && CANCEL_CLAIM_LOOKUP_LIVE=yes
CANCEL_CLAIM_STATE=missing
if [[ -n "$CANCEL_CLAIM_PATH" && -f "$CANCEL_CLAIM_PATH" ]]; then
  CANCEL_CLAIM_BODY="$(cat "$CANCEL_CLAIM_PATH" 2>/dev/null || true)"
  case "$CANCEL_CLAIM_BODY" in
    retired) CANCEL_CLAIM_STATE=retired ;;
    "$CANCEL_CLAIM_MANIFEST_BODY") CANCEL_CLAIM_STATE=authoritative ;;
    *) CANCEL_CLAIM_STATE=other ;;
  esac
fi
CANCEL_CLAIM_MANIFEST_STATE=other
if [[ -f "$CANCEL_CLAIM_MANIFEST" ]]; then
  CANCEL_CLAIM_STABLE_BODY="$(cat "$CANCEL_CLAIM_MANIFEST" 2>/dev/null || true)"
  if [[ "$CANCEL_CLAIM_STABLE_BODY" == "$CANCEL_CLAIM_MANIFEST_BODY" ]]; then
    CANCEL_CLAIM_MANIFEST_STATE=original
  elif [[ "$CANCEL_CLAIM_STABLE_BODY" \
     == "retry:${CANCEL_CLAIM_MANIFEST_IDENTITY}:${CANCEL_CLAIM_MANIFEST_HASH}" ]]; then
    CANCEL_CLAIM_MANIFEST_STATE=retry
  elif [[ "$CANCEL_CLAIM_STABLE_BODY" == consumed:* ]]; then
    CANCEL_CLAIM_MANIFEST_STATE=consumed
  fi
fi
for CANCEL_CLAIM_CLEANUP_PID in \
    "$CANCEL_CLAIM_HOOK_PID" "$CANCEL_CLAIM_LOOKUP_PID"; do
  if [[ "$CANCEL_CLAIM_CLEANUP_PID" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$CANCEL_CLAIM_CLEANUP_PID" 2>/dev/null || true
  fi
done
sleep 0.05
for CANCEL_CLAIM_CLEANUP_PID in \
    "$CANCEL_CLAIM_HOOK_PID" "$CANCEL_CLAIM_LOOKUP_PID"; do
  if [[ "$CANCEL_CLAIM_CLEANUP_PID" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$CANCEL_CLAIM_CLEANUP_PID" 2>/dev/null || true
  fi
done
wait "$CANCEL_CLAIM_JOB" 2>/dev/null; CANCEL_CLAIM_HOOK_RC=$?
CANCEL_CLAIM_RETRY_CONTEXT=""
if [[ "$CANCEL_CLAIM_MANIFEST_STATE" == original \
   || "$CANCEL_CLAIM_MANIFEST_STATE" == retry ]]; then
  CANCEL_CLAIM_RETRY_CONTEXT="$(ctx_session_at "$REPO" \
    "$CANCEL_CLAIM_SESSION" "$CANCEL_CLAIM_COMMAND" "")"
fi
CANCEL_CLAIM_RECOVERABLE=no
[[ -n "$CANCEL_CLAIM_RETRY_CONTEXT" ]] && CANCEL_CLAIM_RECOVERABLE=yes
if [[ "$CANCEL_CLAIM_BARRIER" == hit \
   && "$CANCEL_CLAIM_HOOK_LIVE/$CANCEL_CLAIM_LOOKUP_LIVE" == no/no \
   && "$CANCEL_CLAIM_TERM_ELAPSED" -le 3 \
   && ( "$CANCEL_CLAIM_STATE/$CANCEL_CLAIM_MANIFEST_STATE" \
        == missing/original \
        || "$CANCEL_CLAIM_STATE/$CANCEL_CLAIM_MANIFEST_STATE" \
        == authoritative/retry ) \
   && "$CANCEL_CLAIM_RECOVERABLE" == yes ]]; then
  pass=$((pass + 1)); printf '  PASS  TERM preserves bounded retry authority and context\n'
else
  fail=$((fail + 1)); printf '  FAIL  TERM stranded an unpublished attachment claim (barrier=%s hook_rc=%s elapsed=%ss hook_live=%s lookup_live=%s claim=%s manifest=%s recoverable=%s)\n' \
    "$CANCEL_CLAIM_BARRIER" "$CANCEL_CLAIM_HOOK_RC" \
    "$CANCEL_CLAIM_TERM_ELAPSED" "$CANCEL_CLAIM_HOOK_LIVE" \
    "$CANCEL_CLAIM_LOOKUP_LIVE" "$CANCEL_CLAIM_STATE" \
    "$CANCEL_CLAIM_MANIFEST_STATE" "$CANCEL_CLAIM_RECOVERABLE"
fi

echo
echo "## Interrupted attachment publication remains bounded and retryable"

# TERM must not disappear into the few instructions between starting the
# lookup process group and publishing its PID to cleanup. A DEBUG trap is the
# deterministic boundary here: the blocker is already live, but the assignment
# under test has not executed yet.
LOOKUP_FORK_COMMAND="git push origin refs/heads/local:refs/heads/lookup-fork-gap"
LOOKUP_FORK_ROOT="$TMP/lookup-fork-gap"
LOOKUP_FORK_ENV="$LOOKUP_FORK_ROOT/bash-env.sh"
LOOKUP_FORK_BLOCKER="$LOOKUP_FORK_ROOT/gh-blocker.sh"
mkdir -p "$LOOKUP_FORK_ROOT"
cat > "$LOOKUP_FORK_BLOCKER" <<'LOOKUP_FORK_BLOCKER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$LOOKUP_FORK_CHILD_PID_FILE"
ps -o pgid= -p "$$" | tr -d ' ' > "$LOOKUP_FORK_CHILD_PGID_FILE"
: > "$LOOKUP_FORK_CHILD_READY"
sleep 30
LOOKUP_FORK_BLOCKER_EOF
chmod +x "$LOOKUP_FORK_BLOCKER"
cat > "$LOOKUP_FORK_ENV" <<'LOOKUP_FORK_ENV_EOF'
if [[ -z "${LOOKUP_FORK_ROOT_PID:-}" ]]; then
  export LOOKUP_FORK_ROOT_PID="$$"
  set -T
  trap 'if [[ "$BASH_COMMAND" == *active_lookup_pid* ]]; then
    printf "%s\n" "$BASH_COMMAND" >> "$LOOKUP_FORK_COMMAND_LOG"
  fi
  if [[ "$BASH_COMMAND" == active_lookup_pid=* \
     && "$BASH_COMMAND" == *"\$!"* ]]; then
    trap - DEBUG
    printf "%s\n" "$$" > "$LOOKUP_FORK_HOOK_PID_FILE"
    printf "%s\n" "$!" > "$LOOKUP_FORK_LEADER_PID_FILE"
    lookup_fork_ready_deadline=$(( SECONDS + 2 ))
    while [[ ! -e "$LOOKUP_FORK_CHILD_READY" \
         && "$SECONDS" -lt "$lookup_fork_ready_deadline" ]]; do
      sleep 0.01
    done
    : > "$LOOKUP_FORK_GAP_READY"
    kill -TERM "$$"
  fi' DEBUG
  gh() {
    "$LOOKUP_FORK_BLOCKER" "$@"
  }
fi
LOOKUP_FORK_ENV_EOF
LOOKUP_FORK_PAYLOAD="$(jq -nc --arg command "$LOOKUP_FORK_COMMAND" \
  '{tool_input:{command:$command},
    tool_response:{stdout:"",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LOOKUP_FORK_ENV" \
    LOOKUP_FORK_BLOCKER="$LOOKUP_FORK_BLOCKER" \
    LOOKUP_FORK_HOOK_PID_FILE="$LOOKUP_FORK_ROOT/hook.pid" \
    LOOKUP_FORK_LEADER_PID_FILE="$LOOKUP_FORK_ROOT/leader.pid" \
    LOOKUP_FORK_CHILD_PID_FILE="$LOOKUP_FORK_ROOT/child.pid" \
    LOOKUP_FORK_CHILD_PGID_FILE="$LOOKUP_FORK_ROOT/child.pgid" \
    LOOKUP_FORK_CHILD_READY="$LOOKUP_FORK_ROOT/child.ready" \
    LOOKUP_FORK_GAP_READY="$LOOKUP_FORK_ROOT/gap.ready" \
    LOOKUP_FORK_COMMAND_LOG="$LOOKUP_FORK_ROOT/debug-commands" \
    bash "$HOOK" <<< "$LOOKUP_FORK_PAYLOAD"
) > "$LOOKUP_FORK_ROOT/hook.out" 2> "$LOOKUP_FORK_ROOT/hook.err" \
  & LOOKUP_FORK_JOB=$!
( sleep 8; kill -KILL "$LOOKUP_FORK_JOB" 2>/dev/null || true ) \
  & LOOKUP_FORK_WATCHDOG=$!
wait "$LOOKUP_FORK_JOB" 2>/dev/null; LOOKUP_FORK_RC=$?
kill "$LOOKUP_FORK_WATCHDOG" 2>/dev/null || true
wait "$LOOKUP_FORK_WATCHDOG" 2>/dev/null || true
LOOKUP_FORK_LEADER_PID="$(cat "$LOOKUP_FORK_ROOT/leader.pid" 2>/dev/null || true)"
LOOKUP_FORK_CHILD_PID="$(cat "$LOOKUP_FORK_ROOT/child.pid" 2>/dev/null || true)"
LOOKUP_FORK_CHILD_PGID="$(cat "$LOOKUP_FORK_ROOT/child.pgid" 2>/dev/null || true)"
LOOKUP_FORK_GROUP_LIVE=no
LOOKUP_FORK_CHILD_LIVE=no
if [[ "$LOOKUP_FORK_CHILD_PGID" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 -- "-$LOOKUP_FORK_CHILD_PGID" 2>/dev/null; then
  LOOKUP_FORK_GROUP_LIVE=yes
fi
if [[ "$LOOKUP_FORK_CHILD_PID" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$LOOKUP_FORK_CHILD_PID" 2>/dev/null; then
  LOOKUP_FORK_CHILD_LIVE=yes
fi
if [[ -e "$LOOKUP_FORK_ROOT/gap.ready" && "$LOOKUP_FORK_RC" -eq 143 \
   && "$LOOKUP_FORK_LEADER_PID" =~ ^[1-9][0-9]*$ \
   && "$LOOKUP_FORK_GROUP_LIVE/$LOOKUP_FORK_CHILD_LIVE" == no/no ]]; then
  pass=$((pass + 1)); printf '  PASS  TERM at lookup fork publication reaps the process group\n'
else
  fail=$((fail + 1)); printf '  FAIL  TERM at lookup fork publication leaked work (barrier=%s rc=%s leader=%s pgid=%s group_live=%s child=%s child_live=%s commands=%s)\n' \
    "$([[ -e "$LOOKUP_FORK_ROOT/gap.ready" ]] && echo hit || echo missed)" \
    "$LOOKUP_FORK_RC" "$LOOKUP_FORK_LEADER_PID" "$LOOKUP_FORK_CHILD_PGID" \
    "$LOOKUP_FORK_GROUP_LIVE" "$LOOKUP_FORK_CHILD_PID" \
    "$LOOKUP_FORK_CHILD_LIVE" \
    "$(tr '\n' '|' < "$LOOKUP_FORK_ROOT/debug-commands" 2>/dev/null || true)"
fi
if [[ "$LOOKUP_FORK_CHILD_PGID" =~ ^[1-9][0-9]*$ ]]; then
  kill -TERM -- "-$LOOKUP_FORK_CHILD_PGID" 2>/dev/null || true
  sleep 0.05
  kill -KILL -- "-$LOOKUP_FORK_CHILD_PGID" 2>/dev/null || true
fi

# Hook stdout is committed only by exit status. Interrupt after jq has rendered
# the JSON and the hook has marked it published, then prove that discarding the
# non-zero output does not consume the identical retry's attachment authority.
PUBLISH_EXIT_SESSION="post-watch-publish-exit-gap"
PUBLISH_EXIT_COMMAND="git push origin refs/heads/local:refs/heads/publish-exit-gap"
PUBLISH_EXIT_BRANCH="publish-exit-gap"
PUBLISH_EXIT_ID="watch-aaaaaaaaaaaaaaaaaaaaaaaa"
PUBLISH_EXIT_KEY="$(pr_watch_branch_key "$PUBLISH_EXIT_BRANCH")"
PUBLISH_EXIT_LOG="$STATE_DIR/$PUBLISH_EXIT_KEY.jsonl"
PUBLISH_EXIT_ENTRIES="$(jq -nc --arg branch "$PUBLISH_EXIT_BRANCH" \
  --arg id "$PUBLISH_EXIT_ID" --arg log "$PUBLISH_EXIT_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
PUBLISH_EXIT_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$PUBLISH_EXIT_SESSION" "$PUBLISH_EXIT_COMMAND" "$PUBLISH_EXIT_ENTRIES")"
PUBLISH_EXIT_ROOT="$TMP/publish-exit-gap"
PUBLISH_EXIT_ENV="$PUBLISH_EXIT_ROOT/bash-env.sh"
mkdir -p "$PUBLISH_EXIT_ROOT"
cat > "$PUBLISH_EXIT_ENV" <<'PUBLISH_EXIT_ENV_EOF'
if [[ -z "${PUBLISH_EXIT_ROOT_PID:-}" ]]; then
  export PUBLISH_EXIT_ROOT_PID="$$"
  set -T
  trap 'if [[ "${attachment_published:-false}" == true \
       && "$BASH_COMMAND" == "exit 0" ]]; then
    trap - DEBUG
    printf "%s\n" "$$" > "$PUBLISH_EXIT_HOOK_PID_FILE"
    : > "$PUBLISH_EXIT_GAP_READY"
    kill -TERM "$$"
  fi' DEBUG
fi
PUBLISH_EXIT_ENV_EOF
PUBLISH_EXIT_PAYLOAD="$(jq -nc --arg session "$PUBLISH_EXIT_SESSION" \
  --arg command "$PUBLISH_EXIT_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$PUBLISH_EXIT_ENV" \
    PUBLISH_EXIT_HOOK_PID_FILE="$PUBLISH_EXIT_ROOT/hook.pid" \
    PUBLISH_EXIT_GAP_READY="$PUBLISH_EXIT_ROOT/gap.ready" \
    bash "$HOOK" <<< "$PUBLISH_EXIT_PAYLOAD"
) > "$PUBLISH_EXIT_ROOT/hook.out" 2> "$PUBLISH_EXIT_ROOT/hook.err" \
  & PUBLISH_EXIT_JOB=$!
( sleep 6; kill -KILL "$PUBLISH_EXIT_JOB" 2>/dev/null || true ) \
  & PUBLISH_EXIT_WATCHDOG=$!
wait "$PUBLISH_EXIT_JOB" 2>/dev/null; PUBLISH_EXIT_RC=$?
kill "$PUBLISH_EXIT_WATCHDOG" 2>/dev/null || true
wait "$PUBLISH_EXIT_WATCHDOG" 2>/dev/null || true
PUBLISH_EXIT_RENDERED=no
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$PUBLISH_EXIT_ROOT/hook.out" >/dev/null 2>&1 \
  && PUBLISH_EXIT_RENDERED=yes
PUBLISH_EXIT_RETRY_CONTEXT="$(ctx_session_at "$REPO" \
  "$PUBLISH_EXIT_SESSION" "$PUBLISH_EXIT_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
PUBLISH_EXIT_RECOVERABLE=no
[[ -n "$PUBLISH_EXIT_RETRY_CONTEXT" ]] && PUBLISH_EXIT_RECOVERABLE=yes
if [[ -e "$PUBLISH_EXIT_ROOT/gap.ready" && "$PUBLISH_EXIT_RC" -eq 143 \
   && "$PUBLISH_EXIT_RENDERED/$PUBLISH_EXIT_RECOVERABLE" == yes/yes ]]; then
  pass=$((pass + 1)); printf '  PASS  non-zero exit after rendering preserves identical retry context\n'
else
  fail=$((fail + 1)); printf '  FAIL  non-zero exit after rendering consumed retry authority (barrier=%s rc=%s rendered=%s recoverable=%s manifest=%.40s)\n' \
    "$([[ -e "$PUBLISH_EXIT_ROOT/gap.ready" ]] && echo hit || echo missed)" \
    "$PUBLISH_EXIT_RC" "$PUBLISH_EXIT_RENDERED" "$PUBLISH_EXIT_RECOVERABLE" \
    "$(cat "$PUBLISH_EXIT_MANIFEST" 2>/dev/null || true)"
fi

# The accepted PR number is 128 bytes, so a producer must lose its output sink
# near that boundary rather than filling a regular file until the five-second
# deadline. The stub records acknowledged output progress and its process group.
LOOKUP_INGRESS_ROOT="$TMP/lookup-ingress-cap"
LOOKUP_INGRESS_BIN="$LOOKUP_INGRESS_ROOT/bin"
mkdir -p "$LOOKUP_INGRESS_BIN"
cat > "$LOOKUP_INGRESS_BIN/gh" <<'LOOKUP_INGRESS_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$LOOKUP_INGRESS_PID_FILE"
ps -o pgid= -p "$$" | tr -d ' ' > "$LOOKUP_INGRESS_PGID_FILE"
printf '0\n' > "$LOOKUP_INGRESS_PROGRESS_FILE"
chunk=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
index=0
while (( index < 8192 )); do
  printf '%s' "$chunk" || exit 0
  index=$((index + 1))
  if (( index % 16 == 0 )); then
    printf '%s\n' "$((index * 64))" > "$LOOKUP_INGRESS_PROGRESS_FILE"
  fi
done
sleep 20
LOOKUP_INGRESS_GH_EOF
chmod +x "$LOOKUP_INGRESS_BIN/gh"
LOOKUP_INGRESS_PAYLOAD="$(jq -nc \
  '{tool_input:{command:"git push"},tool_response:{stdout:"",stderr:""}}')"
LOOKUP_INGRESS_STARTED=$SECONDS
(
  cd "$REPO" || exit 1
  exec env PATH="$LOOKUP_INGRESS_BIN:$PATH" \
    LOOKUP_INGRESS_PID_FILE="$LOOKUP_INGRESS_ROOT/child.pid" \
    LOOKUP_INGRESS_PGID_FILE="$LOOKUP_INGRESS_ROOT/child.pgid" \
    LOOKUP_INGRESS_PROGRESS_FILE="$LOOKUP_INGRESS_ROOT/progress" \
    bash "$HOOK" <<< "$LOOKUP_INGRESS_PAYLOAD"
) > "$LOOKUP_INGRESS_ROOT/hook.out" 2> "$LOOKUP_INGRESS_ROOT/hook.err"
LOOKUP_INGRESS_RC=$?
LOOKUP_INGRESS_ELAPSED=$(( SECONDS - LOOKUP_INGRESS_STARTED ))
LOOKUP_INGRESS_PROGRESS="$(cat "$LOOKUP_INGRESS_ROOT/progress" 2>/dev/null || echo 0)"
LOOKUP_INGRESS_PID="$(cat "$LOOKUP_INGRESS_ROOT/child.pid" 2>/dev/null || true)"
LOOKUP_INGRESS_PGID="$(cat "$LOOKUP_INGRESS_ROOT/child.pgid" 2>/dev/null || true)"
LOOKUP_INGRESS_GROUP_LIVE=no
if [[ "$LOOKUP_INGRESS_PGID" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 -- "-$LOOKUP_INGRESS_PGID" 2>/dev/null; then
  LOOKUP_INGRESS_GROUP_LIVE=yes
fi
LOOKUP_INGRESS_RENDERED=no
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LOOKUP_INGRESS_ROOT/hook.out" >/dev/null 2>&1 \
  && LOOKUP_INGRESS_RENDERED=yes
if [[ "$LOOKUP_INGRESS_RC" -eq 0 \
   && "$LOOKUP_INGRESS_PROGRESS" =~ ^[0-9]+$ \
   && "$LOOKUP_INGRESS_PROGRESS" -le 4096 \
   && "$LOOKUP_INGRESS_ELAPSED" -le 3 \
   && "$LOOKUP_INGRESS_GROUP_LIVE/$LOOKUP_INGRESS_RENDERED" == no/yes ]]; then
  pass=$((pass + 1)); printf '  PASS  PR lookup caps ingress near 128 bytes and terminates immediately\n'
else
  fail=$((fail + 1)); printf '  FAIL  PR lookup exceeded its ingress budget (rc=%s progress=%sB elapsed=%ss pid=%s pgid=%s group_live=%s rendered=%s)\n' \
    "$LOOKUP_INGRESS_RC" "$LOOKUP_INGRESS_PROGRESS" \
    "$LOOKUP_INGRESS_ELAPSED" "$LOOKUP_INGRESS_PID" \
    "$LOOKUP_INGRESS_PGID" "$LOOKUP_INGRESS_GROUP_LIVE" \
    "$LOOKUP_INGRESS_RENDERED"
fi
if [[ "$LOOKUP_INGRESS_PGID" =~ ^[1-9][0-9]*$ ]]; then
  kill -KILL -- "-$LOOKUP_INGRESS_PGID" 2>/dev/null || true
fi

# Fault the first fsynced recovery mutation. At that exact durable boundary and
# after killing the recovery helper, at most one pathname may contain the
# original consumable JSON. PERL5OPT affects only this hook process tree.
RECOVERY_SYNC_SESSION="post-watch-recovery-sync"
RECOVERY_SYNC_COMMAND="git push origin refs/heads/local:refs/heads/recovery-sync"
RECOVERY_SYNC_BRANCH="recovery-sync"
RECOVERY_SYNC_ID="watch-cccccccccccccccccccccccc"
RECOVERY_SYNC_KEY="$(pr_watch_branch_key "$RECOVERY_SYNC_BRANCH")"
RECOVERY_SYNC_LOG="$STATE_DIR/$RECOVERY_SYNC_KEY.jsonl"
RECOVERY_SYNC_ENTRIES="$(jq -nc --arg branch "$RECOVERY_SYNC_BRANCH" \
  --arg id "$RECOVERY_SYNC_ID" --arg log "$RECOVERY_SYNC_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
RECOVERY_SYNC_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$RECOVERY_SYNC_SESSION" "$RECOVERY_SYNC_COMMAND" "$RECOVERY_SYNC_ENTRIES")"
RECOVERY_SYNC_BODY="$(cat "$RECOVERY_SYNC_MANIFEST")"
RECOVERY_SYNC_CLAIM="${RECOVERY_SYNC_MANIFEST}.claim.0"
RECOVERY_SYNC_ROOT="$TMP/recovery-sync"
RECOVERY_SYNC_LIB="$RECOVERY_SYNC_ROOT/lib"
RECOVERY_SYNC_ENV="$RECOVERY_SYNC_ROOT/bash-env.sh"
mkdir -p "$RECOVERY_SYNC_LIB"
cat > "$RECOVERY_SYNC_LIB/PrWatchRecoverySync.pm" <<'RECOVERY_SYNC_MODULE_EOF'
package PrWatchRecoverySync;
use strict;
use warnings;
use IO::Handle ();
BEGIN {
  my $original_sync = \&IO::Handle::sync;
  my $armed = 1;
  no warnings 'redefine';
  *IO::Handle::sync = sub {
    my ($opened_fh) = @_;
    my $result = $original_sync->($opened_fh);
    if ($armed && defined($ENV{RECOVERY_SYNC_STARTED})
        && -e $ENV{RECOVERY_SYNC_STARTED}) {
      my @opened = stat($opened_fh);
      for my $path ($ENV{RECOVERY_SYNC_MANIFEST}, $ENV{RECOVERY_SYNC_CLAIM},
                    $ENV{RECOVERY_SYNC_TEMP}) {
        my @named = defined($path) ? lstat($path) : ();
        next unless @opened && @named
          && $opened[0] == $named[0] && $opened[1] == $named[1];
        $armed = 0;
        open(my $pid_fh, ">", $ENV{RECOVERY_SYNC_PERL_PID}) or die $!;
        print {$pid_fh} "$$\n";
        close($pid_fh) or die $!;
        open(my $ready_fh, ">", $ENV{RECOVERY_SYNC_READY}) or die $!;
        print {$ready_fh} "$path\n";
        close($ready_fh) or die $!;
        until (-e $ENV{RECOVERY_SYNC_RELEASE}) {
          select(undef, undef, undef, 0.01);
        }
        last;
      }
    }
    return $result;
  };
}
1;
RECOVERY_SYNC_MODULE_EOF
cat > "$RECOVERY_SYNC_ENV" <<'RECOVERY_SYNC_ENV_EOF'
if [[ -z "${RECOVERY_SYNC_ROOT_PID:-}" ]]; then
  export RECOVERY_SYNC_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${attachment_claim:-}" \
       && "$BASH_COMMAND" == stream_script=* ]]; then
    trap - DEBUG
    : > "$RECOVERY_SYNC_STARTED"
    : > "$RECOVERY_SYNC_TERM_READY"
    kill -TERM "$$"
  fi' DEBUG
fi
RECOVERY_SYNC_ENV_EOF
RECOVERY_SYNC_PAYLOAD="$(jq -nc --arg session "$RECOVERY_SYNC_SESSION" \
  --arg command "$RECOVERY_SYNC_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_SYNC_ENV" \
    PERL5LIB="$RECOVERY_SYNC_LIB" PERL5OPT=-MPrWatchRecoverySync \
    RECOVERY_SYNC_STARTED="$RECOVERY_SYNC_ROOT/started" \
    RECOVERY_SYNC_TERM_READY="$RECOVERY_SYNC_ROOT/term.ready" \
    RECOVERY_SYNC_READY="$RECOVERY_SYNC_ROOT/sync.ready" \
    RECOVERY_SYNC_RELEASE="$RECOVERY_SYNC_ROOT/release" \
    RECOVERY_SYNC_PERL_PID="$RECOVERY_SYNC_ROOT/perl.pid" \
    RECOVERY_SYNC_MANIFEST="$RECOVERY_SYNC_MANIFEST" \
    RECOVERY_SYNC_CLAIM="$RECOVERY_SYNC_CLAIM" \
    RECOVERY_SYNC_TEMP="${RECOVERY_SYNC_MANIFEST}.state.tmp" \
    bash "$HOOK" <<< "$RECOVERY_SYNC_PAYLOAD"
) > "$RECOVERY_SYNC_ROOT/hook.out" 2> "$RECOVERY_SYNC_ROOT/hook.err" \
  & RECOVERY_SYNC_JOB=$!
RECOVERY_SYNC_DEADLINE=$(( SECONDS + 6 ))
while (( SECONDS < RECOVERY_SYNC_DEADLINE )); do
  [[ -e "$RECOVERY_SYNC_ROOT/sync.ready" ]] && break
  kill -0 "$RECOVERY_SYNC_JOB" 2>/dev/null || break
  sleep 0.02
done
RECOVERY_SYNC_BARRIER=missed
[[ -e "$RECOVERY_SYNC_ROOT/sync.ready" ]] && RECOVERY_SYNC_BARRIER=hit
RECOVERY_SYNC_AT_BARRIER=0
RECOVERY_SYNC_BARRIER_IDENTITIES=""
for RECOVERY_SYNC_AUTHORITY in \
    "$RECOVERY_SYNC_MANIFEST" "$RECOVERY_SYNC_CLAIM"; do
  if [[ -f "$RECOVERY_SYNC_AUTHORITY" \
     && "$(cat "$RECOVERY_SYNC_AUTHORITY" 2>/dev/null)" \
        == "$RECOVERY_SYNC_BODY" ]]; then
    RECOVERY_SYNC_AUTHORITY_ID="$(verdict_audit_path_identity \
      "$RECOVERY_SYNC_AUTHORITY" 2>/dev/null || true)"
    if [[ -n "$RECOVERY_SYNC_AUTHORITY_ID" \
       && "|$RECOVERY_SYNC_BARRIER_IDENTITIES|" \
          != *"|$RECOVERY_SYNC_AUTHORITY_ID|"* ]]; then
      RECOVERY_SYNC_BARRIER_IDENTITIES="${RECOVERY_SYNC_BARRIER_IDENTITIES:+$RECOVERY_SYNC_BARRIER_IDENTITIES|}$RECOVERY_SYNC_AUTHORITY_ID"
      RECOVERY_SYNC_AT_BARRIER=$((RECOVERY_SYNC_AT_BARRIER + 1))
    fi
  fi
done
RECOVERY_SYNC_PERL_PID="$(cat "$RECOVERY_SYNC_ROOT/perl.pid" 2>/dev/null || true)"
if [[ "$RECOVERY_SYNC_PERL_PID" =~ ^[1-9][0-9]*$ ]]; then
  kill -KILL "$RECOVERY_SYNC_PERL_PID" 2>/dev/null || true
fi
touch "$RECOVERY_SYNC_ROOT/release"
( sleep 5; kill -KILL "$RECOVERY_SYNC_JOB" 2>/dev/null || true ) \
  & RECOVERY_SYNC_WATCHDOG=$!
wait "$RECOVERY_SYNC_JOB" 2>/dev/null; RECOVERY_SYNC_RC=$?
kill "$RECOVERY_SYNC_WATCHDOG" 2>/dev/null || true
wait "$RECOVERY_SYNC_WATCHDOG" 2>/dev/null || true
RECOVERY_SYNC_AFTER_FAILURE=0
RECOVERY_SYNC_AFTER_IDENTITIES=""
for RECOVERY_SYNC_AUTHORITY in \
    "$RECOVERY_SYNC_MANIFEST" "$RECOVERY_SYNC_CLAIM"; do
  if [[ -f "$RECOVERY_SYNC_AUTHORITY" \
     && "$(cat "$RECOVERY_SYNC_AUTHORITY" 2>/dev/null)" \
        == "$RECOVERY_SYNC_BODY" ]]; then
    RECOVERY_SYNC_AUTHORITY_ID="$(verdict_audit_path_identity \
      "$RECOVERY_SYNC_AUTHORITY" 2>/dev/null || true)"
    if [[ -n "$RECOVERY_SYNC_AUTHORITY_ID" \
       && "|$RECOVERY_SYNC_AFTER_IDENTITIES|" \
          != *"|$RECOVERY_SYNC_AUTHORITY_ID|"* ]]; then
      RECOVERY_SYNC_AFTER_IDENTITIES="${RECOVERY_SYNC_AFTER_IDENTITIES:+$RECOVERY_SYNC_AFTER_IDENTITIES|}$RECOVERY_SYNC_AUTHORITY_ID"
      RECOVERY_SYNC_AFTER_FAILURE=$((RECOVERY_SYNC_AFTER_FAILURE + 1))
    fi
  fi
done
RECOVERY_SYNC_RETRY_CONTEXT="$(ctx_session_at "$REPO" \
  "$RECOVERY_SYNC_SESSION" "$RECOVERY_SYNC_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
RECOVERY_SYNC_RECOVERABLE=no
[[ -n "$RECOVERY_SYNC_RETRY_CONTEXT" ]] && RECOVERY_SYNC_RECOVERABLE=yes
if [[ -e "$RECOVERY_SYNC_ROOT/term.ready" \
   && "$RECOVERY_SYNC_BARRIER" == hit && "$RECOVERY_SYNC_RC" -eq 143 \
   && "$RECOVERY_SYNC_AT_BARRIER" -le 1 \
   && "$RECOVERY_SYNC_AFTER_FAILURE" -le 1 \
   && "$RECOVERY_SYNC_RECOVERABLE" == yes ]]; then
  pass=$((pass + 1)); printf '  PASS  every durable recovery transition has at most one authority\n'
else
  fail=$((fail + 1)); printf '  FAIL  recovery exposed duplicate or lost authority (term=%s sync=%s rc=%s perl=%s at_barrier=%s after_failure=%s recoverable=%s path=%s)\n' \
    "$([[ -e "$RECOVERY_SYNC_ROOT/term.ready" ]] && echo hit || echo missed)" \
    "$RECOVERY_SYNC_BARRIER" "$RECOVERY_SYNC_RC" \
    "$RECOVERY_SYNC_PERL_PID" "$RECOVERY_SYNC_AT_BARRIER" \
    "$RECOVERY_SYNC_AFTER_FAILURE" "$RECOVERY_SYNC_RECOVERABLE" \
    "$(cat "$RECOVERY_SYNC_ROOT/sync.ready" 2>/dev/null || true)"
fi

# Retry authority must be advertised once, not merely consumed once downstream.
# Prime one retry marker, synchronize two hook processes after both sampled it,
# then release them together. Exactly one may publish the claim command.
RECOVERY_RACE_SESSION="post-watch-concurrent-recovery"
RECOVERY_RACE_COMMAND="git push origin refs/heads/local:refs/heads/concurrent-recovery"
RECOVERY_RACE_BRANCH="concurrent-recovery"
RECOVERY_RACE_ID="watch-dddddddddddddddddddddddd"
RECOVERY_RACE_KEY="$(pr_watch_branch_key "$RECOVERY_RACE_BRANCH")"
RECOVERY_RACE_LOG="$STATE_DIR/$RECOVERY_RACE_KEY.jsonl"
RECOVERY_RACE_ENTRIES="$(jq -nc --arg branch "$RECOVERY_RACE_BRANCH" \
  --arg id "$RECOVERY_RACE_ID" --arg log "$RECOVERY_RACE_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
RECOVERY_RACE_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$RECOVERY_RACE_SESSION" "$RECOVERY_RACE_COMMAND" "$RECOVERY_RACE_ENTRIES")"
RECOVERY_RACE_ROOT="$TMP/concurrent-recovery"
RECOVERY_RACE_PRIME_ENV="$RECOVERY_RACE_ROOT/prime-env.sh"
RECOVERY_RACE_BARRIER_ENV="$RECOVERY_RACE_ROOT/barrier-env.sh"
mkdir -p "$RECOVERY_RACE_ROOT"
cat > "$RECOVERY_RACE_PRIME_ENV" <<'RECOVERY_RACE_PRIME_ENV_EOF'
if [[ -z "${RECOVERY_RACE_PRIME_ROOT_PID:-}" ]]; then
  export RECOVERY_RACE_PRIME_ROOT_PID="$$"
  set -T
  trap 'if [[ "${attachment_published:-false}" == true \
       && "$BASH_COMMAND" == "exit 0" ]]; then
    trap - DEBUG
    : > "$RECOVERY_RACE_PRIME_READY"
    kill -TERM "$$"
  fi' DEBUG
fi
RECOVERY_RACE_PRIME_ENV_EOF
cat > "$RECOVERY_RACE_BARRIER_ENV" <<'RECOVERY_RACE_BARRIER_ENV_EOF'
if [[ -z "${RECOVERY_RACE_HOOK_ROOT_PID:-}" ]]; then
  export RECOVERY_RACE_HOOK_ROOT_PID="$$"
  set -T
  trap 'if [[ "${body:-}" == retry:* \
       && "$BASH_COMMAND" == now=*date* ]]; then
    trap - DEBUG
    : > "$RECOVERY_RACE_READY_DIR/ready.$$"
    recovery_race_release_deadline=$(( SECONDS + 5 ))
    while [[ ! -e "$RECOVERY_RACE_RELEASE" \
         && "$SECONDS" -lt "$recovery_race_release_deadline" ]]; do
      sleep 0.01
    done
  fi' DEBUG
fi
RECOVERY_RACE_BARRIER_ENV_EOF
RECOVERY_RACE_PAYLOAD="$(jq -nc --arg session "$RECOVERY_RACE_SESSION" \
  --arg command "$RECOVERY_RACE_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_RACE_PRIME_ENV" \
    RECOVERY_RACE_PRIME_READY="$RECOVERY_RACE_ROOT/prime.ready" \
    bash "$HOOK" <<< "$RECOVERY_RACE_PAYLOAD"
) > "$RECOVERY_RACE_ROOT/prime.out" 2> "$RECOVERY_RACE_ROOT/prime.err"
RECOVERY_RACE_PRIME_RC=$?
mkdir -p "$RECOVERY_RACE_ROOT/ready"
for RECOVERY_RACE_INDEX in 1 2; do
  (
    cd "$REPO" || exit 1
    exec env BASH_ENV="$RECOVERY_RACE_BARRIER_ENV" \
      RECOVERY_RACE_READY_DIR="$RECOVERY_RACE_ROOT/ready" \
      RECOVERY_RACE_RELEASE="$RECOVERY_RACE_ROOT/release" \
      bash "$HOOK" <<< "$RECOVERY_RACE_PAYLOAD"
  ) > "$RECOVERY_RACE_ROOT/hook.$RECOVERY_RACE_INDEX.out" \
    2> "$RECOVERY_RACE_ROOT/hook.$RECOVERY_RACE_INDEX.err" &
  if [[ "$RECOVERY_RACE_INDEX" -eq 1 ]]; then
    RECOVERY_RACE_JOB_1=$!
  else
    RECOVERY_RACE_JOB_2=$!
  fi
done
RECOVERY_RACE_DEADLINE=$(( SECONDS + 5 ))
RECOVERY_RACE_READY_COUNT=0
while (( SECONDS < RECOVERY_RACE_DEADLINE )); do
  RECOVERY_RACE_READY_COUNT="$(
    set -- "$RECOVERY_RACE_ROOT"/ready/ready.*
    if [[ -e "$1" ]]; then printf '%s' "$#"; else printf '0'; fi
  )"
  [[ "$RECOVERY_RACE_READY_COUNT" -eq 2 ]] && break
  kill -0 "$RECOVERY_RACE_JOB_1" 2>/dev/null || break
  kill -0 "$RECOVERY_RACE_JOB_2" 2>/dev/null || break
  sleep 0.02
done
touch "$RECOVERY_RACE_ROOT/release"
( sleep 8
  kill -KILL "$RECOVERY_RACE_JOB_1" "$RECOVERY_RACE_JOB_2" \
    2>/dev/null || true
) & RECOVERY_RACE_WATCHDOG=$!
wait "$RECOVERY_RACE_JOB_1" 2>/dev/null; RECOVERY_RACE_RC_1=$?
wait "$RECOVERY_RACE_JOB_2" 2>/dev/null; RECOVERY_RACE_RC_2=$?
kill "$RECOVERY_RACE_WATCHDOG" 2>/dev/null || true
wait "$RECOVERY_RACE_WATCHDOG" 2>/dev/null || true
RECOVERY_RACE_PUBLICATIONS=0
for RECOVERY_RACE_INDEX in 1 2; do
  if jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
      "$RECOVERY_RACE_ROOT/hook.$RECOVERY_RACE_INDEX.out" \
      >/dev/null 2>&1; then
    RECOVERY_RACE_PUBLICATIONS=$((RECOVERY_RACE_PUBLICATIONS + 1))
  fi
done
if [[ -e "$RECOVERY_RACE_ROOT/prime.ready" \
   && "$RECOVERY_RACE_PRIME_RC" -eq 143 \
   && "$RECOVERY_RACE_READY_COUNT" -eq 2 \
   && "$RECOVERY_RACE_RC_1" -eq 0 && "$RECOVERY_RACE_RC_2" -eq 0 \
   && "$RECOVERY_RACE_PUBLICATIONS" -eq 1 ]]; then
  pass=$((pass + 1)); printf '  PASS  concurrent retry hooks publish one recovery capability\n'
else
  fail=$((fail + 1)); printf '  FAIL  concurrent retry hooks duplicated publication (prime=%s ready=%s rc=%s/%s publications=%s marker=%.100s)\n' \
    "$RECOVERY_RACE_PRIME_RC" "$RECOVERY_RACE_READY_COUNT" \
    "$RECOVERY_RACE_RC_1" "$RECOVERY_RACE_RC_2" \
    "$RECOVERY_RACE_PUBLICATIONS" \
    "$(cat "$RECOVERY_RACE_MANIFEST" 2>/dev/null || true)"
fi

# A flock protects an inode, not a pathname. Hold one recovery hook after it
# publishes its marker, rename the locked .lease inode away, then let a second
# hook lock the replacement and publish its own marker. The displaced owner
# must revalidate the exact lease inode and marker immediately before output;
# only the replacement owner may advertise the claim.
LEASE_REPLACE_SESSION="post-watch-lease-replacement"
LEASE_REPLACE_COMMAND="git push origin refs/heads/local:refs/heads/lease-replacement"
LEASE_REPLACE_BRANCH="lease-replacement"
LEASE_REPLACE_ID="watch-454545454545454545454545"
LEASE_REPLACE_KEY="$(pr_watch_branch_key "$LEASE_REPLACE_BRANCH")"
LEASE_REPLACE_LOG="$STATE_DIR/$LEASE_REPLACE_KEY.jsonl"
LEASE_REPLACE_ENTRIES="$(jq -nc --arg branch "$LEASE_REPLACE_BRANCH" \
  --arg id "$LEASE_REPLACE_ID" --arg log "$LEASE_REPLACE_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
LEASE_REPLACE_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$LEASE_REPLACE_SESSION" "$LEASE_REPLACE_COMMAND" "$LEASE_REPLACE_ENTRIES")"
LEASE_REPLACE_ROOT="$TMP/lease-replacement"
LEASE_REPLACE_BARRIER_ENV="$LEASE_REPLACE_ROOT/barrier-env.sh"
mkdir -p "$LEASE_REPLACE_ROOT"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_RACE_PRIME_ENV" \
    RECOVERY_RACE_PRIME_READY="$LEASE_REPLACE_ROOT/prime.ready" \
    bash "$HOOK" <<< "$(jq -nc --arg session "$LEASE_REPLACE_SESSION" \
      --arg command "$LEASE_REPLACE_COMMAND" \
      '{session_id:$session,tool_input:{command:$command},
        tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
) > "$LEASE_REPLACE_ROOT/prime.out" 2> "$LEASE_REPLACE_ROOT/prime.err"
LEASE_REPLACE_PRIME_RC=$?
cat > "$LEASE_REPLACE_BARRIER_ENV" <<'LEASE_REPLACE_BARRIER_ENV_EOF'
if [[ -z "${LEASE_REPLACE_HOOK_ROOT_PID:-}" ]]; then
  export LEASE_REPLACE_HOOK_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${attachment_recovery_marker:-}" \
       && "$BASH_COMMAND" == branch_count=1 ]]; then
    trap - DEBUG
    printf "%s\n" "$$" > "$LEASE_REPLACE_READY"
    lease_replace_deadline=$(( SECONDS + 5 ))
    while [[ ! -e "$LEASE_REPLACE_RELEASE" \
         && "$SECONDS" -lt "$lease_replace_deadline" ]]; do
      sleep 0.01
    done
  fi' DEBUG
fi
LEASE_REPLACE_BARRIER_ENV_EOF
LEASE_REPLACE_PAYLOAD="$(jq -nc --arg session "$LEASE_REPLACE_SESSION" \
  --arg command "$LEASE_REPLACE_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LEASE_REPLACE_BARRIER_ENV" \
    LEASE_REPLACE_READY="$LEASE_REPLACE_ROOT/ready.old" \
    LEASE_REPLACE_RELEASE="$LEASE_REPLACE_ROOT/release.old" \
    bash "$HOOK" <<< "$LEASE_REPLACE_PAYLOAD"
) > "$LEASE_REPLACE_ROOT/old.out" 2> "$LEASE_REPLACE_ROOT/old.err" \
  & LEASE_REPLACE_OLD_JOB=$!
LEASE_REPLACE_DEADLINE=$(( SECONDS + 5 ))
while [[ ! -e "$LEASE_REPLACE_ROOT/ready.old" \
     && "$SECONDS" -lt "$LEASE_REPLACE_DEADLINE" ]]; do
  kill -0 "$LEASE_REPLACE_OLD_JOB" 2>/dev/null || break
  sleep 0.02
done
LEASE_REPLACE_SWAPPED=false
if [[ -e "$LEASE_REPLACE_ROOT/ready.old" \
   && -f "${LEASE_REPLACE_MANIFEST}.lease" ]]; then
  mv "${LEASE_REPLACE_MANIFEST}.lease" \
    "${LEASE_REPLACE_MANIFEST}.lease.displaced" \
    && LEASE_REPLACE_SWAPPED=true
fi
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LEASE_REPLACE_BARRIER_ENV" \
    LEASE_REPLACE_READY="$LEASE_REPLACE_ROOT/ready.new" \
    LEASE_REPLACE_RELEASE="$LEASE_REPLACE_ROOT/release.new" \
    bash "$HOOK" <<< "$LEASE_REPLACE_PAYLOAD"
) > "$LEASE_REPLACE_ROOT/new.out" 2> "$LEASE_REPLACE_ROOT/new.err" \
  & LEASE_REPLACE_NEW_JOB=$!
LEASE_REPLACE_DEADLINE=$(( SECONDS + 5 ))
while [[ ! -e "$LEASE_REPLACE_ROOT/ready.new" \
     && "$SECONDS" -lt "$LEASE_REPLACE_DEADLINE" ]]; do
  kill -0 "$LEASE_REPLACE_NEW_JOB" 2>/dev/null || break
  sleep 0.02
done
touch "$LEASE_REPLACE_ROOT/release.old" "$LEASE_REPLACE_ROOT/release.new"
(
  sleep 8
  kill -KILL "$LEASE_REPLACE_OLD_JOB" "$LEASE_REPLACE_NEW_JOB" \
    2>/dev/null || true
) & LEASE_REPLACE_WATCHDOG=$!
wait "$LEASE_REPLACE_OLD_JOB" 2>/dev/null; LEASE_REPLACE_OLD_RC=$?
wait "$LEASE_REPLACE_NEW_JOB" 2>/dev/null; LEASE_REPLACE_NEW_RC=$?
kill "$LEASE_REPLACE_WATCHDOG" 2>/dev/null || true
wait "$LEASE_REPLACE_WATCHDOG" 2>/dev/null || true
LEASE_REPLACE_OLD_PUBLISHED=false
LEASE_REPLACE_NEW_PUBLISHED=false
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LEASE_REPLACE_ROOT/old.out" >/dev/null 2>&1 \
  && LEASE_REPLACE_OLD_PUBLISHED=true
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LEASE_REPLACE_ROOT/new.out" >/dev/null 2>&1 \
  && LEASE_REPLACE_NEW_PUBLISHED=true
if [[ "$LEASE_REPLACE_PRIME_RC" -eq 143 \
   && -e "$LEASE_REPLACE_ROOT/prime.ready" \
   && -e "$LEASE_REPLACE_ROOT/ready.old" \
   && -e "$LEASE_REPLACE_ROOT/ready.new" \
   && "$LEASE_REPLACE_SWAPPED" == true \
   && "$LEASE_REPLACE_OLD_PUBLISHED" == false \
   && "$LEASE_REPLACE_NEW_PUBLISHED" == true ]]; then
  pass=$((pass + 1)); printf '  PASS  lease replacement revokes the displaced recovery owner\n'
else
  fail=$((fail + 1)); printf '  FAIL  lease replacement left two publishers (prime=%s swapped=%s ready=%s/%s rc=%s/%s published=%s/%s marker=%.120s)\n' \
    "$LEASE_REPLACE_PRIME_RC" "$LEASE_REPLACE_SWAPPED" \
    "$([[ -e "$LEASE_REPLACE_ROOT/ready.old" ]] && echo yes || echo no)" \
    "$([[ -e "$LEASE_REPLACE_ROOT/ready.new" ]] && echo yes || echo no)" \
    "$LEASE_REPLACE_OLD_RC" "$LEASE_REPLACE_NEW_RC" \
    "$LEASE_REPLACE_OLD_PUBLISHED" "$LEASE_REPLACE_NEW_PUBLISHED" \
    "$(cat "$LEASE_REPLACE_MANIFEST" 2>/dev/null || true)"
fi

# The exclusive recovery lease is not a permanent lock. If its exact process
# dies before publication, the next identical hook may reclaim that same claim
# generation; PID reuse is rejected by the recorded process-start token.
RECOVERY_DEATH_SESSION="post-watch-recovery-owner-death"
RECOVERY_DEATH_COMMAND="git push origin refs/heads/local:refs/heads/recovery-owner-death"
RECOVERY_DEATH_BRANCH="recovery-owner-death"
RECOVERY_DEATH_ID="watch-eeeeeeeeeeeeeeeeeeeeeeee"
RECOVERY_DEATH_KEY="$(pr_watch_branch_key "$RECOVERY_DEATH_BRANCH")"
RECOVERY_DEATH_LOG="$STATE_DIR/$RECOVERY_DEATH_KEY.jsonl"
RECOVERY_DEATH_ENTRIES="$(jq -nc --arg branch "$RECOVERY_DEATH_BRANCH" \
  --arg id "$RECOVERY_DEATH_ID" --arg log "$RECOVERY_DEATH_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
RECOVERY_DEATH_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$RECOVERY_DEATH_SESSION" "$RECOVERY_DEATH_COMMAND" "$RECOVERY_DEATH_ENTRIES")"
RECOVERY_DEATH_ROOT="$TMP/recovery-owner-death"
RECOVERY_DEATH_BARRIER_ENV="$RECOVERY_DEATH_ROOT/barrier-env.sh"
mkdir -p "$RECOVERY_DEATH_ROOT"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_RACE_PRIME_ENV" \
    RECOVERY_RACE_PRIME_READY="$RECOVERY_DEATH_ROOT/prime.ready" \
    bash "$HOOK" <<< "$(jq -nc --arg session "$RECOVERY_DEATH_SESSION" \
      --arg command "$RECOVERY_DEATH_COMMAND" \
      '{session_id:$session,tool_input:{command:$command},
        tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
) > "$RECOVERY_DEATH_ROOT/prime.out" 2> "$RECOVERY_DEATH_ROOT/prime.err"
RECOVERY_DEATH_PRIME_RC=$?
cat > "$RECOVERY_DEATH_BARRIER_ENV" <<'RECOVERY_DEATH_BARRIER_ENV_EOF'
if [[ -z "${RECOVERY_DEATH_HOOK_ROOT_PID:-}" ]]; then
  export RECOVERY_DEATH_HOOK_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${attachment_recovery_marker:-}" \
       && "$BASH_COMMAND" == branch_count=1 ]]; then
    trap - DEBUG
    printf "%s\n" "$$" > "$RECOVERY_DEATH_READY"
    recovery_death_deadline=$(( SECONDS + 5 ))
    while [[ ! -e "$RECOVERY_DEATH_RELEASE" \
         && "$SECONDS" -lt "$recovery_death_deadline" ]]; do
      sleep 0.01
    done
  fi' DEBUG
fi
RECOVERY_DEATH_BARRIER_ENV_EOF
RECOVERY_DEATH_PAYLOAD="$(jq -nc --arg session "$RECOVERY_DEATH_SESSION" \
  --arg command "$RECOVERY_DEATH_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_DEATH_BARRIER_ENV" \
    RECOVERY_DEATH_READY="$RECOVERY_DEATH_ROOT/ready" \
    RECOVERY_DEATH_RELEASE="$RECOVERY_DEATH_ROOT/release" \
    bash "$HOOK" <<< "$RECOVERY_DEATH_PAYLOAD"
) > "$RECOVERY_DEATH_ROOT/hook.out" 2> "$RECOVERY_DEATH_ROOT/hook.err" \
  & RECOVERY_DEATH_JOB=$!
RECOVERY_DEATH_DEADLINE=$(( SECONDS + 5 ))
while (( SECONDS < RECOVERY_DEATH_DEADLINE )); do
  [[ -e "$RECOVERY_DEATH_ROOT/ready" ]] && break
  kill -0 "$RECOVERY_DEATH_JOB" 2>/dev/null || break
  sleep 0.02
done
RECOVERY_DEATH_PID="$(cat "$RECOVERY_DEATH_ROOT/ready" 2>/dev/null || true)"
RECOVERY_DEATH_MARKER="$(cat "$RECOVERY_DEATH_MANIFEST" 2>/dev/null || true)"
if [[ "$RECOVERY_DEATH_PID" =~ ^[1-9][0-9]*$ \
   && "$RECOVERY_DEATH_PID" == "$RECOVERY_DEATH_JOB" ]]; then
  kill -KILL "$RECOVERY_DEATH_PID" 2>/dev/null || true
else
  touch "$RECOVERY_DEATH_ROOT/release"
fi
wait "$RECOVERY_DEATH_JOB" 2>/dev/null; RECOVERY_DEATH_RC=$?
RECOVERY_DEATH_RETRY_CONTEXT="$(ctx_session_at "$REPO" \
  "$RECOVERY_DEATH_SESSION" "$RECOVERY_DEATH_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
if [[ -e "$RECOVERY_DEATH_ROOT/prime.ready" \
   && "$RECOVERY_DEATH_PRIME_RC" -eq 143 \
   && "$RECOVERY_DEATH_PID" == "$RECOVERY_DEATH_JOB" \
   && "$RECOVERY_DEATH_RC" -eq 137 \
   && "$RECOVERY_DEATH_MARKER" == recovering:* \
   && -n "$RECOVERY_DEATH_RETRY_CONTEXT" ]]; then
  pass=$((pass + 1)); printf '  PASS  dead recovery owner releases its exact generation\n'
else
  fail=$((fail + 1)); printf '  FAIL  dead recovery owner stranded its generation (prime=%s pid=%s/%s rc=%s marker=%.100s retry=%s)\n' \
    "$RECOVERY_DEATH_PRIME_RC" "$RECOVERY_DEATH_PID" \
    "$RECOVERY_DEATH_JOB" "$RECOVERY_DEATH_RC" \
    "$RECOVERY_DEATH_MARKER" \
    "$([[ -n "$RECOVERY_DEATH_RETRY_CONTEXT" ]] && echo yes || echo no)"
fi

# SIGKILL bypasses EXIT cleanup. Once the exact claim exists, a crash before the
# first output byte must leave a process-bound recovery record so one identical
# retry can publish that generation, and a second retry cannot replay it.
CLAIM_CRASH_SESSION="post-watch-claim-crash"
CLAIM_CRASH_COMMAND="git push origin refs/heads/local:refs/heads/claim-crash"
CLAIM_CRASH_BRANCH="claim-crash"
CLAIM_CRASH_ID="watch-ffffffffffffffffffffffff"
CLAIM_CRASH_KEY="$(pr_watch_branch_key "$CLAIM_CRASH_BRANCH")"
CLAIM_CRASH_LOG="$STATE_DIR/$CLAIM_CRASH_KEY.jsonl"
CLAIM_CRASH_ENTRIES="$(jq -nc --arg branch "$CLAIM_CRASH_BRANCH" \
  --arg id "$CLAIM_CRASH_ID" --arg log "$CLAIM_CRASH_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
CLAIM_CRASH_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$CLAIM_CRASH_SESSION" "$CLAIM_CRASH_COMMAND" "$CLAIM_CRASH_ENTRIES")"
CLAIM_CRASH_ROOT="$TMP/claim-crash"
CLAIM_CRASH_ENV="$CLAIM_CRASH_ROOT/bash-env.sh"
mkdir -p "$CLAIM_CRASH_ROOT"
cat > "$CLAIM_CRASH_ENV" <<'CLAIM_CRASH_ENV_EOF'
if [[ -z "${CLAIM_CRASH_ROOT_PID:-}" ]]; then
  export CLAIM_CRASH_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${attachment_claim:-}" \
       && "$BASH_COMMAND" == stream_script=* ]]; then
    trap - DEBUG
    printf "%s\n" "$$" > "$CLAIM_CRASH_READY"
    kill -KILL "$$"
  fi' DEBUG
fi
CLAIM_CRASH_ENV_EOF
CLAIM_CRASH_PAYLOAD="$(jq -nc --arg session "$CLAIM_CRASH_SESSION" \
  --arg command "$CLAIM_CRASH_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$CLAIM_CRASH_ENV" \
    CLAIM_CRASH_READY="$CLAIM_CRASH_ROOT/ready" \
    bash "$HOOK" <<< "$CLAIM_CRASH_PAYLOAD"
) > "$CLAIM_CRASH_ROOT/hook.out" 2> "$CLAIM_CRASH_ROOT/hook.err" \
  & CLAIM_CRASH_JOB=$!
( sleep 6; kill -KILL "$CLAIM_CRASH_JOB" 2>/dev/null || true ) \
  & CLAIM_CRASH_WATCHDOG=$!
wait "$CLAIM_CRASH_JOB" 2>/dev/null; CLAIM_CRASH_RC=$?
kill "$CLAIM_CRASH_WATCHDOG" 2>/dev/null || true
wait "$CLAIM_CRASH_WATCHDOG" 2>/dev/null || true
CLAIM_CRASH_OUTPUT_BYTES="$(wc -c < "$CLAIM_CRASH_ROOT/hook.out" | tr -d ' ')"
CLAIM_CRASH_RETRY_CONTEXT="$(ctx_session_at "$REPO" \
  "$CLAIM_CRASH_SESSION" "$CLAIM_CRASH_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
CLAIM_CRASH_RETRY_COMMAND="$(printf '%s' "$CLAIM_CRASH_RETRY_CONTEXT" \
  | stream_command_from_context)"
CLAIM_CRASH_RETRY_CLAIM="$(attachment_claim_from_command \
  "$CLAIM_CRASH_RETRY_COMMAND" 2>/dev/null || true)"
CLAIM_CRASH_ACK=no
if [[ -n "$CLAIM_CRASH_RETRY_CLAIM" ]] \
   && consume_attachment_claim "$CLAIM_CRASH_RETRY_CLAIM"; then
  CLAIM_CRASH_ACK=yes
fi
CLAIM_CRASH_REPLAY_CONTEXT="$(ctx_session_at "$REPO" \
  "$CLAIM_CRASH_SESSION" "$CLAIM_CRASH_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
if [[ -e "$CLAIM_CRASH_ROOT/ready" && "$CLAIM_CRASH_RC" -eq 137 \
   && "$CLAIM_CRASH_OUTPUT_BYTES" -eq 0 \
   && -n "$CLAIM_CRASH_RETRY_CONTEXT" \
   && "$CLAIM_CRASH_ACK" == yes \
   && -z "$CLAIM_CRASH_REPLAY_CONTEXT" ]]; then
  pass=$((pass + 1)); printf '  PASS  SIGKILL after claim acquisition remains exactly-once retryable\n'
else
  fail=$((fail + 1)); printf '  FAIL  SIGKILL stranded an acquired claim (barrier=%s rc=%s bytes=%s retry=%s replay=%s manifest=%.100s)\n' \
    "$([[ -e "$CLAIM_CRASH_ROOT/ready" ]] && echo hit || echo missed)" \
    "$CLAIM_CRASH_RC" "$CLAIM_CRASH_OUTPUT_BYTES" \
    "$([[ -n "$CLAIM_CRASH_RETRY_CONTEXT" ]] && echo yes || echo no)" \
    "$([[ -n "$CLAIM_CRASH_REPLAY_CONTEXT" ]] && echo yes || echo no)" \
    "$(cat "$CLAIM_CRASH_MANIFEST" 2>/dev/null || true)"
fi

# A marker transition must never destroy the last recoverable record in place.
# Current code is stopped immediately after truncating the stable manifest; an
# atomic replacement implementation is stopped at its first temp-file fsync.
TRANSITION_CRASH_SESSION="post-watch-transition-crash"
TRANSITION_CRASH_COMMAND="git push origin refs/heads/local:refs/heads/transition-crash"
TRANSITION_CRASH_BRANCH="transition-crash"
TRANSITION_CRASH_ID="watch-101010101010101010101010"
TRANSITION_CRASH_KEY="$(pr_watch_branch_key "$TRANSITION_CRASH_BRANCH")"
TRANSITION_CRASH_LOG="$STATE_DIR/$TRANSITION_CRASH_KEY.jsonl"
TRANSITION_CRASH_ENTRIES="$(jq -nc --arg branch "$TRANSITION_CRASH_BRANCH" \
  --arg id "$TRANSITION_CRASH_ID" --arg log "$TRANSITION_CRASH_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
TRANSITION_CRASH_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$TRANSITION_CRASH_SESSION" "$TRANSITION_CRASH_COMMAND" \
  "$TRANSITION_CRASH_ENTRIES")"
TRANSITION_CRASH_ROOT="$TMP/transition-crash"
TRANSITION_CRASH_LIB="$TRANSITION_CRASH_ROOT/lib"
TRANSITION_CRASH_ENV="$TRANSITION_CRASH_ROOT/bash-env.sh"
mkdir -p "$TRANSITION_CRASH_LIB"
cat > "$TRANSITION_CRASH_LIB/PrWatchTransitionCrash.pm" <<'TRANSITION_CRASH_MODULE_EOF'
package PrWatchTransitionCrash;
use strict;
use warnings;
use IO::Handle ();
BEGIN {
  my $original_sync = \&IO::Handle::sync;
  my $armed = 1;
  my $barrier = sub {
    return unless $armed && -e $ENV{TRANSITION_CRASH_STARTED};
    $armed = 0;
    open(my $pid_fh, ">", $ENV{TRANSITION_CRASH_HELPER_PID}) or die $!;
    print {$pid_fh} "$$\n";
    close($pid_fh) or die $!;
    open(my $ready_fh, ">", $ENV{TRANSITION_CRASH_READY}) or die $!;
    print {$ready_fh} "ready\n";
    close($ready_fh) or die $!;
    until (-e $ENV{TRANSITION_CRASH_RELEASE}) {
      select(undef, undef, undef, 0.01);
    }
  };
  no warnings 'redefine';
  *CORE::GLOBAL::truncate = sub (*$) {
    my $result = CORE::truncate($_[0], $_[1]);
    $barrier->() if @_ == 2 && $_[1] == 0;
    return $result;
  };
  *IO::Handle::sync = sub {
    my ($opened_fh) = @_;
    my $result = $original_sync->($opened_fh);
    $barrier->();
    return $result;
  };
}
1;
TRANSITION_CRASH_MODULE_EOF
cat > "$TRANSITION_CRASH_ENV" <<'TRANSITION_CRASH_ENV_EOF'
if [[ -z "${TRANSITION_CRASH_ROOT_PID:-}" ]]; then
  export TRANSITION_CRASH_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${attachment_claim:-}" \
       && "$BASH_COMMAND" == stream_script=* ]]; then
    trap - DEBUG
    : > "$TRANSITION_CRASH_STARTED"
    kill -TERM "$$"
  fi' DEBUG
fi
TRANSITION_CRASH_ENV_EOF
TRANSITION_CRASH_PAYLOAD="$(jq -nc --arg session "$TRANSITION_CRASH_SESSION" \
  --arg command "$TRANSITION_CRASH_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$TRANSITION_CRASH_ENV" \
    PERL5LIB="$TRANSITION_CRASH_LIB" PERL5OPT=-MPrWatchTransitionCrash \
    TRANSITION_CRASH_STARTED="$TRANSITION_CRASH_ROOT/started" \
    TRANSITION_CRASH_HELPER_PID="$TRANSITION_CRASH_ROOT/helper.pid" \
    TRANSITION_CRASH_READY="$TRANSITION_CRASH_ROOT/ready" \
    TRANSITION_CRASH_RELEASE="$TRANSITION_CRASH_ROOT/release" \
    bash "$HOOK" <<< "$TRANSITION_CRASH_PAYLOAD"
) > "$TRANSITION_CRASH_ROOT/hook.out" 2> "$TRANSITION_CRASH_ROOT/hook.err" \
  & TRANSITION_CRASH_JOB=$!
TRANSITION_CRASH_DEADLINE=$(( SECONDS + 6 ))
while (( SECONDS < TRANSITION_CRASH_DEADLINE )); do
  [[ -e "$TRANSITION_CRASH_ROOT/ready" ]] && break
  kill -0 "$TRANSITION_CRASH_JOB" 2>/dev/null || break
  sleep 0.02
done
TRANSITION_CRASH_HELPER_PID="$(cat "$TRANSITION_CRASH_ROOT/helper.pid" 2>/dev/null || true)"
if [[ "$TRANSITION_CRASH_HELPER_PID" =~ ^[1-9][0-9]*$ ]]; then
  kill -KILL "$TRANSITION_CRASH_HELPER_PID" 2>/dev/null || true
fi
touch "$TRANSITION_CRASH_ROOT/release"
wait "$TRANSITION_CRASH_JOB" 2>/dev/null; TRANSITION_CRASH_RC=$?
TRANSITION_CRASH_SIZE="$(wc -c < "$TRANSITION_CRASH_MANIFEST" 2>/dev/null \
  | tr -d ' ' || printf '0')"
TRANSITION_CRASH_RETRY="$(ctx_session_at "$REPO" \
  "$TRANSITION_CRASH_SESSION" "$TRANSITION_CRASH_COMMAND" \
  "https://github.com/acme/widget/pull/42")"
if [[ -e "$TRANSITION_CRASH_ROOT/ready" \
   && "$TRANSITION_CRASH_RC" -eq 143 \
   && "$TRANSITION_CRASH_SIZE" =~ ^[1-9][0-9]*$ \
   && -n "$TRANSITION_CRASH_RETRY" ]]; then
  pass=$((pass + 1)); printf '  PASS  transition crash preserves an atomic recoverable marker\n'
else
  fail=$((fail + 1)); printf '  FAIL  transition crash destroyed stable recovery (barrier=%s rc=%s size=%s retry=%s)\n' \
    "$([[ -e "$TRANSITION_CRASH_ROOT/ready" ]] && echo hit || echo missed)" \
    "$TRANSITION_CRASH_RC" "$TRANSITION_CRASH_SIZE" \
    "$([[ -n "$TRANSITION_CRASH_RETRY" ]] && echo yes || echo no)"
fi

# A successful-looking stdout record is not acknowledged until the consumer
# claims it. Kill after cleanup seals its publication state but before exit 0;
# the discarded output must be re-advertised, then stop after claim consumption.
DELIVERY_CRASH_SESSION="post-watch-delivery-crash"
DELIVERY_CRASH_COMMAND="git push origin refs/heads/local:refs/heads/delivery-crash"
DELIVERY_CRASH_BRANCH="delivery-crash"
DELIVERY_CRASH_ID="watch-202020202020202020202020"
DELIVERY_CRASH_KEY="$(pr_watch_branch_key "$DELIVERY_CRASH_BRANCH")"
DELIVERY_CRASH_LOG="$STATE_DIR/$DELIVERY_CRASH_KEY.jsonl"
DELIVERY_CRASH_ENTRIES="$(jq -nc --arg branch "$DELIVERY_CRASH_BRANCH" \
  --arg id "$DELIVERY_CRASH_ID" --arg log "$DELIVERY_CRASH_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
write_attachment_manifest "$REPO" "$DELIVERY_CRASH_SESSION" \
  "$DELIVERY_CRASH_COMMAND" "$DELIVERY_CRASH_ENTRIES" >/dev/null
DELIVERY_CRASH_ROOT="$TMP/delivery-crash"
DELIVERY_CRASH_ENV="$DELIVERY_CRASH_ROOT/bash-env.sh"
mkdir -p "$DELIVERY_CRASH_ROOT"
cat > "$DELIVERY_CRASH_ENV" <<'DELIVERY_CRASH_ENV_EOF'
if [[ -z "${DELIVERY_CRASH_ROOT_PID:-}" ]]; then
  export DELIVERY_CRASH_ROOT_PID="$$"
  set -T
  trap 'if [[ "${attachment_published:-false}" == true \
       && -n "${attachment_claim:-}" \
       && "$BASH_COMMAND" == clear_attachment_claim_state ]]; then
    trap - DEBUG
    : > "$DELIVERY_CRASH_READY"
    kill -KILL "$$"
  fi' DEBUG
fi
DELIVERY_CRASH_ENV_EOF
DELIVERY_CRASH_PAYLOAD="$(jq -nc --arg session "$DELIVERY_CRASH_SESSION" \
  --arg command "$DELIVERY_CRASH_COMMAND" \
  '{session_id:$session,tool_input:{command:$command},
    tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$DELIVERY_CRASH_ENV" \
    DELIVERY_CRASH_READY="$DELIVERY_CRASH_ROOT/ready" \
    bash "$HOOK" <<< "$DELIVERY_CRASH_PAYLOAD"
) > "$DELIVERY_CRASH_ROOT/hook.out" 2> "$DELIVERY_CRASH_ROOT/hook.err" \
  & DELIVERY_CRASH_JOB=$!
( sleep 6; kill -KILL "$DELIVERY_CRASH_JOB" 2>/dev/null || true ) \
  & DELIVERY_CRASH_WATCHDOG=$!
wait "$DELIVERY_CRASH_JOB" 2>/dev/null; DELIVERY_CRASH_RC=$?
kill "$DELIVERY_CRASH_WATCHDOG" 2>/dev/null || true
wait "$DELIVERY_CRASH_WATCHDOG" 2>/dev/null || true
DELIVERY_CRASH_RETRY="$(ctx_session_at "$REPO" "$DELIVERY_CRASH_SESSION" \
  "$DELIVERY_CRASH_COMMAND" "https://github.com/acme/widget/pull/42")"
DELIVERY_CRASH_COMMAND_TEXT="$(printf '%s' "$DELIVERY_CRASH_RETRY" \
  | stream_command_from_context)"
DELIVERY_CRASH_CLAIM="$(attachment_claim_from_command \
  "$DELIVERY_CRASH_COMMAND_TEXT" 2>/dev/null || true)"
DELIVERY_CRASH_ACK=no
if [[ -n "$DELIVERY_CRASH_CLAIM" ]] \
   && consume_attachment_claim "$DELIVERY_CRASH_CLAIM"; then
  DELIVERY_CRASH_ACK=yes
fi
DELIVERY_CRASH_REPLAY="$(ctx_session_at "$REPO" "$DELIVERY_CRASH_SESSION" \
  "$DELIVERY_CRASH_COMMAND" "https://github.com/acme/widget/pull/42")"
if [[ -e "$DELIVERY_CRASH_ROOT/ready" && "$DELIVERY_CRASH_RC" -eq 137 \
   && -n "$DELIVERY_CRASH_RETRY" && "$DELIVERY_CRASH_ACK" == yes \
   && -z "$DELIVERY_CRASH_REPLAY" ]]; then
  pass=$((pass + 1)); printf '  PASS  claim consumption acknowledges final hook delivery\n'
else
  fail=$((fail + 1)); printf '  FAIL  final delivery gap lost or replayed context (barrier=%s rc=%s retry=%s ack=%s replay=%s)\n' \
    "$([[ -e "$DELIVERY_CRASH_ROOT/ready" ]] && echo hit || echo missed)" \
    "$DELIVERY_CRASH_RC" \
    "$([[ -n "$DELIVERY_CRASH_RETRY" ]] && echo yes || echo no)" \
    "$DELIVERY_CRASH_ACK" \
    "$([[ -n "$DELIVERY_CRASH_REPLAY" ]] && echo yes || echo no)"
fi

# The lookup command must not inherit the completion channel. A hostile gh that
# writes fd 7 and then sleeps used to make the parent enter an unbounded wait.
LOOKUP_FORGE_ROOT="$TMP/lookup-completion-forge"
LOOKUP_FORGE_BIN="$LOOKUP_FORGE_ROOT/bin"
mkdir -p "$LOOKUP_FORGE_BIN"
cat > "$LOOKUP_FORGE_BIN/gh" <<'LOOKUP_FORGE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$LOOKUP_FORGE_PID_FILE"
ps -o pgid= -p "$$" | tr -d ' ' > "$LOOKUP_FORGE_PGID_FILE"
if printf 'forged\n' >&7 2>/dev/null; then
  : > "$LOOKUP_FORGE_WRITABLE"
fi
: > "$LOOKUP_FORGE_READY"
sleep 30
LOOKUP_FORGE_GH_EOF
chmod +x "$LOOKUP_FORGE_BIN/gh"
LOOKUP_FORGE_PAYLOAD="$(jq -nc \
  '{tool_input:{command:"git push"},tool_response:{stdout:"",stderr:""}}')"
LOOKUP_FORGE_STARTED=$SECONDS
(
  cd "$REPO" || exit 1
  exec env PATH="$LOOKUP_FORGE_BIN:$PATH" \
    LOOKUP_FORGE_PID_FILE="$LOOKUP_FORGE_ROOT/child.pid" \
    LOOKUP_FORGE_PGID_FILE="$LOOKUP_FORGE_ROOT/child.pgid" \
    LOOKUP_FORGE_WRITABLE="$LOOKUP_FORGE_ROOT/writable" \
    LOOKUP_FORGE_READY="$LOOKUP_FORGE_ROOT/ready" \
    bash "$HOOK" <<< "$LOOKUP_FORGE_PAYLOAD"
) > "$LOOKUP_FORGE_ROOT/hook.out" 2> "$LOOKUP_FORGE_ROOT/hook.err" \
  & LOOKUP_FORGE_JOB=$!
LOOKUP_FORGE_DEADLINE=$(( SECONDS + 7 ))
while (( SECONDS < LOOKUP_FORGE_DEADLINE )); do
  kill -0 "$LOOKUP_FORGE_JOB" 2>/dev/null || break
  sleep 0.05
done
LOOKUP_FORGE_BLOCKED=no
if kill -0 "$LOOKUP_FORGE_JOB" 2>/dev/null; then
  LOOKUP_FORGE_BLOCKED=yes
  LOOKUP_FORGE_PGID="$(cat "$LOOKUP_FORGE_ROOT/child.pgid" 2>/dev/null || true)"
  if [[ "$LOOKUP_FORGE_PGID" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL -- "-$LOOKUP_FORGE_PGID" 2>/dev/null || true
  fi
  kill -KILL "$LOOKUP_FORGE_JOB" 2>/dev/null || true
fi
wait "$LOOKUP_FORGE_JOB" 2>/dev/null; LOOKUP_FORGE_RC=$?
LOOKUP_FORGE_ELAPSED=$(( SECONDS - LOOKUP_FORGE_STARTED ))
LOOKUP_FORGE_RENDERED=no
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LOOKUP_FORGE_ROOT/hook.out" >/dev/null 2>&1 \
  && LOOKUP_FORGE_RENDERED=yes
if [[ -e "$LOOKUP_FORGE_ROOT/ready" && ! -e "$LOOKUP_FORGE_ROOT/writable" \
   && "$LOOKUP_FORGE_BLOCKED/$LOOKUP_FORGE_RENDERED" == no/yes \
   && "$LOOKUP_FORGE_ELAPSED" -le 7 ]]; then
  pass=$((pass + 1)); printf '  PASS  gh cannot forge completion or bypass the lookup deadline\n'
else
  fail=$((fail + 1)); printf '  FAIL  gh forged completion into an unbounded wait (ready=%s writable=%s blocked=%s elapsed=%ss rc=%s rendered=%s)\n' \
    "$([[ -e "$LOOKUP_FORGE_ROOT/ready" ]] && echo yes || echo no)" \
    "$([[ -e "$LOOKUP_FORGE_ROOT/writable" ]] && echo yes || echo no)" \
    "$LOOKUP_FORGE_BLOCKED" "$LOOKUP_FORGE_ELAPSED" \
    "$LOOKUP_FORGE_RC" "$LOOKUP_FORGE_RENDERED"
fi

# Swapping mktemp's public name before fd 9 is authenticated must not make the
# hook adopt and clean an attacker directory. Descriptor-only lookup has no
# mktemp boundary, so the trap is deliberately absent after that redesign.
LOOKUP_START_ROOT="$TMP/lookup-start-swap"
LOOKUP_START_ENV="$LOOKUP_START_ROOT/bash-env.sh"
LOOKUP_START_TARGET="$LOOKUP_START_ROOT/attacker-target"
LOOKUP_START_ORIGINAL="$LOOKUP_START_ROOT/original"
mkdir -p "$LOOKUP_START_TARGET"
printf 'keep-output\n' > "$LOOKUP_START_TARGET/output"
printf 'keep-done\n' > "$LOOKUP_START_TARGET/leader.done"
cat > "$LOOKUP_START_ENV" <<'LOOKUP_START_ENV_EOF'
if [[ -z "${LOOKUP_START_ROOT_PID:-}" ]]; then
  export LOOKUP_START_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${active_lookup_dir:-}" \
       && "$BASH_COMMAND" == exec\ 9*active_lookup_dir* ]]; then
    trap - DEBUG
    mv "$active_lookup_dir" "$LOOKUP_START_ORIGINAL"
    ln -s "$LOOKUP_START_TARGET" "$active_lookup_dir"
    : > "$LOOKUP_START_READY"
  fi' DEBUG
fi
LOOKUP_START_ENV_EOF
LOOKUP_START_PAYLOAD="$(jq -nc \
  '{tool_input:{command:"git push"},tool_response:{stdout:"",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LOOKUP_START_ENV" \
    LOOKUP_START_ORIGINAL="$LOOKUP_START_ORIGINAL" \
    LOOKUP_START_TARGET="$LOOKUP_START_TARGET" \
    LOOKUP_START_READY="$LOOKUP_START_ROOT/ready" \
    bash "$HOOK" <<< "$LOOKUP_START_PAYLOAD"
) > "$LOOKUP_START_ROOT/hook.out" 2> "$LOOKUP_START_ROOT/hook.err"
LOOKUP_START_RC=$?
LOOKUP_START_OUTPUT="$(cat "$LOOKUP_START_TARGET/output" 2>/dev/null || true)"
LOOKUP_START_DONE="$(cat "$LOOKUP_START_TARGET/leader.done" 2>/dev/null || true)"
if [[ ! -e "$LOOKUP_START_ROOT/ready" && "$LOOKUP_START_RC" -eq 0 \
   && "$LOOKUP_START_OUTPUT/$LOOKUP_START_DONE" \
      == keep-output/keep-done ]]; then
  pass=$((pass + 1)); printf '  PASS  lookup startup has no unauthenticated temp-directory window\n'
else
  fail=$((fail + 1)); printf '  FAIL  lookup authenticated a swapped temp directory (barrier=%s rc=%s output=%s done=%s)\n' \
    "$([[ -e "$LOOKUP_START_ROOT/ready" ]] && echo hit || echo absent)" \
    "$LOOKUP_START_RC" "$LOOKUP_START_OUTPUT" "$LOOKUP_START_DONE"
fi

# A one-second lstart token cannot prove recovery ownership after PID reuse.
# Make an unrelated live PID appear to have the persisted weak start instant;
# the hook must treat that unverifiable legacy lease as reclaimable.
TOKEN_COLLISION_SESSION="post-watch-token-collision"
TOKEN_COLLISION_COMMAND="git push origin refs/heads/local:refs/heads/token-collision"
TOKEN_COLLISION_BRANCH="token-collision"
TOKEN_COLLISION_ID="watch-303030303030303030303030"
TOKEN_COLLISION_KEY="$(pr_watch_branch_key "$TOKEN_COLLISION_BRANCH")"
TOKEN_COLLISION_LOG="$STATE_DIR/$TOKEN_COLLISION_KEY.jsonl"
TOKEN_COLLISION_ENTRIES="$(jq -nc --arg branch "$TOKEN_COLLISION_BRANCH" \
  --arg id "$TOKEN_COLLISION_ID" --arg log "$TOKEN_COLLISION_LOG" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,watch_id:$id,event_log:$log}]')"
TOKEN_COLLISION_MANIFEST="$(write_attachment_manifest "$REPO" \
  "$TOKEN_COLLISION_SESSION" "$TOKEN_COLLISION_COMMAND" \
  "$TOKEN_COLLISION_ENTRIES")"
TOKEN_COLLISION_ROOT="$TMP/token-collision"
mkdir -p "$TOKEN_COLLISION_ROOT/bin"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$RECOVERY_RACE_PRIME_ENV" \
    RECOVERY_RACE_PRIME_READY="$TOKEN_COLLISION_ROOT/prime.ready" \
    bash "$HOOK" <<< "$(jq -nc --arg session "$TOKEN_COLLISION_SESSION" \
      --arg command "$TOKEN_COLLISION_COMMAND" \
      '{session_id:$session,tool_input:{command:$command},
        tool_response:{stdout:"https://github.com/acme/widget/pull/42",stderr:""}}')"
) > "$TOKEN_COLLISION_ROOT/prime.out" 2> "$TOKEN_COLLISION_ROOT/prime.err"
TOKEN_COLLISION_PRIME_RC=$?
sleep 30 & TOKEN_COLLISION_PID=$!
TOKEN_COLLISION_REAL_PS="$(command -v ps)"
cat > "$TOKEN_COLLISION_ROOT/bin/ps" <<'TOKEN_COLLISION_PS_EOF'
#!/usr/bin/env bash
if [[ " $* " == *" -p $TOKEN_COLLISION_PID "* \
   && " $* " == *" -o lstart= "* ]]; then
  printf 'Mon Aug 31 00:00:00 2026\n'
  exit 0
fi
exec "$TOKEN_COLLISION_REAL_PS" "$@"
TOKEN_COLLISION_PS_EOF
chmod +x "$TOKEN_COLLISION_ROOT/bin/ps"
export TOKEN_COLLISION_PID TOKEN_COLLISION_REAL_PS
TOKEN_COLLISION_WEAK_TOKEN="$(PATH="$TOKEN_COLLISION_ROOT/bin:$PATH" \
  verdict_audit_process_start_token "$TOKEN_COLLISION_PID")"
TOKEN_COLLISION_RETRY="$(cat "$TOKEN_COLLISION_MANIFEST" 2>/dev/null || true)"
if [[ "$TOKEN_COLLISION_RETRY" =~ ^retry:([0-9]+):([0-9]+):([0-9a-f]{64})$ ]]; then
  printf 'recovering:%s:%s:%s:%s:%s\n' \
    "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    "$TOKEN_COLLISION_PID" "$TOKEN_COLLISION_WEAK_TOKEN" \
    > "$TOKEN_COLLISION_MANIFEST"
fi
TOKEN_COLLISION_CONTEXT="$(PATH="$TOKEN_COLLISION_ROOT/bin:$PATH" \
  ctx_session_at "$REPO" "$TOKEN_COLLISION_SESSION" \
    "$TOKEN_COLLISION_COMMAND" "https://github.com/acme/widget/pull/42")"
kill "$TOKEN_COLLISION_PID" 2>/dev/null || true
wait "$TOKEN_COLLISION_PID" 2>/dev/null || true
if [[ "$TOKEN_COLLISION_PRIME_RC" -eq 143 \
   && "$TOKEN_COLLISION_WEAK_TOKEN" =~ ^cksum-[0-9]+-[0-9]+$ \
   && -n "$TOKEN_COLLISION_CONTEXT" ]]; then
  pass=$((pass + 1)); printf '  PASS  weak same-second PID token cannot retain a recovery lease\n'
else
  fail=$((fail + 1)); printf '  FAIL  weak PID token trusted a same-second collision (prime=%s token=%s retry=%s)\n' \
    "$TOKEN_COLLISION_PRIME_RC" "$TOKEN_COLLISION_WEAK_TOKEN" \
    "$([[ -n "$TOKEN_COLLISION_CONTEXT" ]] && echo yes || echo no)"
fi

# Replacing the checked output name with a FIFO at the read boundary must fail
# without opening that pathname. The alternate command pattern keeps the same
# public reproducer after the hook switches from wc(1) to its descriptor reader.
LOOKUP_FIFO_ROOT="$TMP/lookup-fifo-swap"
LOOKUP_FIFO_ENV="$LOOKUP_FIFO_ROOT/bash-env.sh"
mkdir -p "$LOOKUP_FIFO_ROOT"
cat > "$LOOKUP_FIFO_ENV" <<'LOOKUP_FIFO_ENV_EOF'
if [[ -z "${LOOKUP_FIFO_ROOT_PID:-}" ]]; then
  export LOOKUP_FIFO_ROOT_PID="$$"
  set -T
  trap 'if [[ "$BASH_COMMAND" == output_bytes=*wc* \
       || "$BASH_COMMAND" == lookup_output_snapshot=* ]]; then
    trap - DEBUG
    rm -f "$output_path"
    mkfifo "$output_path"
    printf "%s\n" "$output_path" > "$LOOKUP_FIFO_READY"
  fi' DEBUG
fi
LOOKUP_FIFO_ENV_EOF
LOOKUP_FIFO_PAYLOAD="$(jq -nc \
  '{tool_input:{command:"git push"},tool_response:{stdout:"",stderr:""}}')"
LOOKUP_FIFO_STARTED=$SECONDS
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LOOKUP_FIFO_ENV" \
    LOOKUP_FIFO_READY="$LOOKUP_FIFO_ROOT/ready" \
    bash "$HOOK" <<< "$LOOKUP_FIFO_PAYLOAD"
) > "$LOOKUP_FIFO_ROOT/hook.out" 2> "$LOOKUP_FIFO_ROOT/hook.err" \
  & LOOKUP_FIFO_JOB=$!
LOOKUP_FIFO_READY_DEADLINE=$(( SECONDS + 4 ))
while (( SECONDS < LOOKUP_FIFO_READY_DEADLINE )); do
  [[ -s "$LOOKUP_FIFO_ROOT/ready" ]] && break
  kill -0 "$LOOKUP_FIFO_JOB" 2>/dev/null || break
  sleep 0.02
done
sleep 1
LOOKUP_FIFO_BLOCKED=no
if kill -0 "$LOOKUP_FIFO_JOB" 2>/dev/null; then
  LOOKUP_FIFO_BLOCKED=yes
  LOOKUP_FIFO_PATH="$(cat "$LOOKUP_FIFO_ROOT/ready" 2>/dev/null || true)"
  if [[ -p "$LOOKUP_FIFO_PATH" ]]; then
    ( printf '7' > "$LOOKUP_FIFO_PATH" ) & LOOKUP_FIFO_WRITER=$!
  else
    LOOKUP_FIFO_WRITER=""
  fi
else
  LOOKUP_FIFO_WRITER=""
fi
( sleep 6; kill -KILL "$LOOKUP_FIFO_JOB" 2>/dev/null || true ) \
  & LOOKUP_FIFO_WATCHDOG=$!
wait "$LOOKUP_FIFO_JOB" 2>/dev/null; LOOKUP_FIFO_RC=$?
kill "$LOOKUP_FIFO_WATCHDOG" 2>/dev/null || true
wait "$LOOKUP_FIFO_WATCHDOG" 2>/dev/null || true
if [[ "$LOOKUP_FIFO_WRITER" =~ ^[1-9][0-9]*$ ]]; then
  wait "$LOOKUP_FIFO_WRITER" 2>/dev/null || true
fi
LOOKUP_FIFO_ELAPSED=$(( SECONDS - LOOKUP_FIFO_STARTED ))
LOOKUP_FIFO_RENDERED=no
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LOOKUP_FIFO_ROOT/hook.out" >/dev/null 2>&1 \
  && LOOKUP_FIFO_RENDERED=yes
if [[ ! -s "$LOOKUP_FIFO_ROOT/ready" && "$LOOKUP_FIFO_RC" -eq 0 \
   && "$LOOKUP_FIFO_BLOCKED/$LOOKUP_FIFO_RENDERED" == no/yes ]]; then
  pass=$((pass + 1)); printf '  PASS  descriptor-only lookup has no pathname FIFO boundary\n'
else
  fail=$((fail + 1)); printf '  FAIL  lookup opened a replaced FIFO (barrier=%s rc=%s blocked=%s elapsed=%ss rendered=%s)\n' \
    "$([[ -s "$LOOKUP_FIFO_ROOT/ready" ]] && echo hit || echo missed)" \
    "$LOOKUP_FIFO_RC" "$LOOKUP_FIFO_BLOCKED" \
    "$LOOKUP_FIFO_ELAPSED" "$LOOKUP_FIFO_RENDERED"
fi

# Cleanup must act through the retained temporary-directory inode. Swapping its
# public name for a symlink immediately before cleanup must not delete children
# selected through the replacement directory.
LOOKUP_PARENT_ROOT="$TMP/lookup-parent-swap"
LOOKUP_PARENT_ENV="$LOOKUP_PARENT_ROOT/bash-env.sh"
LOOKUP_PARENT_TARGET="$LOOKUP_PARENT_ROOT/attacker-target"
LOOKUP_PARENT_ORIGINAL="$LOOKUP_PARENT_ROOT/original-dir"
mkdir -p "$LOOKUP_PARENT_TARGET"
printf 'keep-output\n' > "$LOOKUP_PARENT_TARGET/output"
printf 'keep-done\n' > "$LOOKUP_PARENT_TARGET/leader.done"
cat > "$LOOKUP_PARENT_ENV" <<'LOOKUP_PARENT_ENV_EOF'
if [[ -z "${LOOKUP_PARENT_ROOT_PID:-}" ]]; then
  export LOOKUP_PARENT_ROOT_PID="$$"
  set -T
  trap 'if [[ -n "${active_lookup_dir:-}" \
       && "$BASH_COMMAND" == cleanup_lookup_dir ]]; then
    trap - DEBUG
    mv "$active_lookup_dir" "$LOOKUP_PARENT_ORIGINAL"
    ln -s "$LOOKUP_PARENT_TARGET" "$active_lookup_dir"
    : > "$LOOKUP_PARENT_READY"
  fi' DEBUG
fi
LOOKUP_PARENT_ENV_EOF
LOOKUP_PARENT_PAYLOAD="$(jq -nc \
  '{tool_input:{command:"git push"},tool_response:{stdout:"",stderr:""}}')"
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LOOKUP_PARENT_ENV" \
    LOOKUP_PARENT_ORIGINAL="$LOOKUP_PARENT_ORIGINAL" \
    LOOKUP_PARENT_TARGET="$LOOKUP_PARENT_TARGET" \
    LOOKUP_PARENT_READY="$LOOKUP_PARENT_ROOT/ready" \
    bash "$HOOK" <<< "$LOOKUP_PARENT_PAYLOAD"
) > "$LOOKUP_PARENT_ROOT/hook.out" 2> "$LOOKUP_PARENT_ROOT/hook.err"
LOOKUP_PARENT_RC=$?
LOOKUP_PARENT_RENDERED=no
jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' \
  "$LOOKUP_PARENT_ROOT/hook.out" >/dev/null 2>&1 \
  && LOOKUP_PARENT_RENDERED=yes
LOOKUP_PARENT_OUTPUT="$(cat "$LOOKUP_PARENT_TARGET/output" 2>/dev/null || true)"
LOOKUP_PARENT_DONE="$(cat "$LOOKUP_PARENT_TARGET/leader.done" 2>/dev/null || true)"
if [[ ! -e "$LOOKUP_PARENT_ROOT/ready" && "$LOOKUP_PARENT_RC" -eq 0 \
   && "$LOOKUP_PARENT_RENDERED" == yes \
   && "$LOOKUP_PARENT_OUTPUT/$LOOKUP_PARENT_DONE" \
      == keep-output/keep-done ]]; then
  pass=$((pass + 1)); printf '  PASS  descriptor-only lookup has no pathname cleanup boundary\n'
else
  fail=$((fail + 1)); printf '  FAIL  lookup cleanup deleted through a replaced parent (barrier=%s rc=%s rendered=%s output=%s done=%s)\n' \
    "$([[ -e "$LOOKUP_PARENT_ROOT/ready" ]] && echo hit || echo missed)" \
    "$LOOKUP_PARENT_RC" "$LOOKUP_PARENT_RENDERED" \
    "$LOOKUP_PARENT_OUTPUT" "$LOOKUP_PARENT_DONE"
fi

OMITTED_SESSION="post-watch-omitted-session"
OMITTED_COMMAND="git push origin refs/heads/a:refs/heads/a refs/heads/b:refs/heads/b refs/heads/c:refs/heads/c refs/heads/d:refs/heads/d refs/heads/e:refs/heads/e refs/heads/f:refs/heads/f"
OMITTED_ENTRIES='[]'
for omitted_index in 0 1 2 3; do
  omitted_branch="branch-$omitted_index"
  omitted_key="$(pr_watch_branch_key "$omitted_branch")"
  omitted_entry="$(jq -nc --arg branch "$omitted_branch" \
    --arg watch_id "watch-$(printf '%024d' "$((omitted_index + 5))")" \
    --arg event_log "$STATE_DIR/$omitted_key.jsonl" \
    '{remote_ref:("refs/heads/" + $branch),branch:$branch,
      watch_id:$watch_id,event_log:$event_log}')"
  OMITTED_ENTRIES="$(jq -nc --argjson entries "$OMITTED_ENTRIES" \
    --argjson entry "$omitted_entry" '$entries + [$entry]')"
done
write_attachment_manifest \
  "$REPO" "$OMITTED_SESSION" "$OMITTED_COMMAND" "$OMITTED_ENTRIES" 2 >/dev/null
omitted_context="$(ctx_session_at "$REPO" "$OMITTED_SESSION" "$OMITTED_COMMAND" "")"
omitted_context_bytes="$(LC_ALL=C printf '%s' "$omitted_context" | wc -c | tr -d ' ')"
if [[ "$omitted_context" == *"Remote write succeeded for 6 pushed branches; 4 exact watcher generations attached, 2 omitted."* \
   && "$omitted_context" != *"all exact generations are attached"* \
   && "$omitted_context_bytes" -le 1400 ]]; then
  pass=$((pass + 1)); printf '  PASS  omitted pushed refs remain explicit in bounded context\n'
else
  fail=$((fail + 1)); printf '  FAIL  omitted pushed refs remain explicit in bounded context (bytes=%s context=%.160s)\n' \
    "$omitted_context_bytes" "$omitted_context"
fi

OVERSIZED_BRANCH_SESSION="post-watch-oversized-branch"
OVERSIZED_BRANCH_COMMAND="git push"
oversized_branch_component="$(printf '%0220d' 0 | tr 0 b)"
oversized_branch="$oversized_branch_component"
for ((oversized_branch_index = 0; oversized_branch_index < 6; oversized_branch_index++)); do
  oversized_branch="$oversized_branch/$oversized_branch_component"
done
oversized_branch_key="$(pr_watch_branch_key "$oversized_branch")"
OVERSIZED_BRANCH_ENTRIES="$(jq -nc \
  --arg branch "$oversized_branch" \
  --arg log "$STATE_DIR/$oversized_branch_key.jsonl" \
  '[{remote_ref:("refs/heads/" + $branch),branch:$branch,
     watch_id:"watch-777777777777777777777777",event_log:$log}]')"
write_attachment_manifest \
  "$REPO" "$OVERSIZED_BRANCH_SESSION" "$OVERSIZED_BRANCH_COMMAND" \
  "$OVERSIZED_BRANCH_ENTRIES" >/dev/null
oversized_branch_context="$(ctx_session_at \
  "$REPO" "$OVERSIZED_BRANCH_SESSION" "$OVERSIZED_BRANCH_COMMAND" "")"
oversized_branch_context_bytes="$(LC_ALL=C printf '%s' "$oversized_branch_context" | wc -c | tr -d ' ')"
oversized_branch_command="$(printf '%s' "$oversized_branch_context" | stream_command_from_context)"
if git check-ref-format "refs/heads/$oversized_branch" >/dev/null 2>&1 \
   && (( oversized_branch_context_bytes <= 1400 )) \
   && [[ -z "$oversized_branch_command" \
      && "$oversized_branch_context" == *"No safe fallback was attached"* ]]; then
  pass=$((pass + 1)); printf '  PASS  final overflow fallback is bounded independently of branch length\n'
else
  fail=$((fail + 1)); printf '  FAIL  final overflow fallback is bounded independently of branch length (bytes=%s cmd=%.80s)\n' \
    "$oversized_branch_context_bytes" "$oversized_branch_command"
fi

got="$(ctx "gh pr create -t x" "https://github.com/boxlite-ai/boxlite/pull/1234")"
if [[ "$got" == *"PR #1234"* ]]; then
  pass=$((pass + 1)); printf '  PASS  PR number read from the create URL\n'
else
  fail=$((fail + 1)); printf '  FAIL  PR number read from the create URL\n'
fi

got="$(ctx "git push" "")"
if [[ "$got" == *"PR #42"* ]]; then
  pass=$((pass + 1)); printf '  PASS  falls back to the branch'"'"'s open PR\n'
else
  fail=$((fail + 1)); printf '  FAIL  falls back to the branch'"'"'s open PR (got: %.60s)\n' "$got"
fi

# Prefix form, not a bare assignment: `VAR="" got="$(…)"` is TWO assignments, so
# the empty value would persist and silently re-point every later case at the
# no-PR branch. `ctx` is a function, so the prefix scopes it to this call.
got="$(STUB_PR_NUMBER="" ctx "git push" "")"
if [[ "$got" == *"No open PR"* ]]; then
  pass=$((pass + 1)); printf '  PASS  no PR yet still arms, noting the watcher polls\n'
else
  fail=$((fail + 1)); printf '  FAIL  no PR yet still arms, noting the watcher polls\n'
fi

got="$(ctx "git push" "")"
if [[ "$got" == *"escalation-policy.md"* && "$got" == *"pr-watch-stream.sh"* ]]; then
  pass=$((pass + 1)); printf '  PASS  context names the stream script and the policy\n'
else
  fail=$((fail + 1)); printf '  FAIL  context names the stream script and the policy\n'
fi

if [[ "$got" == *"kind 'conflict'"* && "$got" == *"confirmed merge conflict"* ]]; then
  pass=$((pass + 1)); printf '  PASS  context tells consumers how to handle conflicts\n'
else
  fail=$((fail + 1)); printf '  FAIL  context tells consumers how to handle conflicts\n'
fi

# An unknown host still gets every attach route. Guards the Codex-consumer
# regression: a context that names only Monitor() reads as Claude-only wiring the
# moment another host registers this hook, and a runtime this hook has not been
# taught about must degrade to the menu rather than to a guess.
if [[ "$got" == *"Monitor({"* && "$got" == *"Codex"* ]]; then
  pass=$((pass + 1)); printf '  PASS  context names an attach route for every host\n'
else
  fail=$((fail + 1)); printf '  FAIL  context names an attach route for every host\n'
fi

# ...and a KNOWN host is named its own route and no other. An agent that cannot run
# Monitor should not be reading about it, and the narrower text also buys headroom
# against the 1400-byte ceiling this hook enforces.
# Invokes the hook directly rather than through ctx(), which strips both roots to pin
# its own unknown-host default — routing this through it would erase the very host
# being set up here.
ctx_as_host() {  # host, command, response
  local host="$1" cmd="$2" response="$3" payload
  payload="$(jq -nc --arg c "$cmd" --arg r "$response" \
    '{tool_input:{command:$c}, tool_response:{stdout:$r, stderr:""}}')"
  case "$host" in
    claude)
      printf '%s' "$payload" | env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
        "$HOOK" 2>/dev/null ;;
    codex)
      printf '%s' "$payload" | env -u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT="$REPO_ROOT" \
        "$HOOK" 2>/dev/null ;;
  esac | jq -r '.hookSpecificOutput.additionalContext // ""'
}
claude_ctx="$(ctx_as_host claude "gh pr create -t x" "https://github.com/boxlite-ai/boxlite/pull/1234")"
if [[ "$claude_ctx" == *"Monitor({"* && "$claude_ctx" != *"Codex"* ]]; then
  pass=$((pass + 1)); printf '  PASS  a Claude host is named only the Monitor route\n'
else
  fail=$((fail + 1)); printf '  FAIL  a Claude host is named only the Monitor route (got: %.160s)\n' "$claude_ctx"
fi
codex_ctx="$(ctx_as_host codex "gh pr create -t x" "https://github.com/boxlite-ai/boxlite/pull/1234")"
if [[ "$codex_ctx" == *"background shell"* && "$codex_ctx" != *"Monitor({"* ]]; then
  pass=$((pass + 1)); printf '  PASS  a Codex host is named only the background-shell route\n'
else
  fail=$((fail + 1)); printf '  FAIL  a Codex host is named only the background-shell route (got: %.160s)\n' "$codex_ctx"
fi

# The stream script must be addressed in the TOOLING tree (the hook's own
# plugin), not at the consumer repo root: an installed consumer has no .agents/
# checkout, and this suite's scratch repo root is not $REPO_ROOT. Asserting the
# full path is what the bare-filename checks above cannot do.
if [[ "$got" == *"bash $REPO_ROOT/.agents/watch/pr-watch-stream.sh"* ]]; then
  pass=$((pass + 1)); printf '  PASS  stream script addressed at the tooling root\n'
else
  fail=$((fail + 1)); printf '  FAIL  stream script addressed at the tooling root (got: %.120s)\n' "$got"
fi

context_bytes="$(LC_ALL=C printf '%s' "$got" | wc -c | tr -d ' ')"
if (( context_bytes <= 1400 )); then
  pass=$((pass + 1)); printf '  PASS  watch context stays within 1400 bytes (%s)\n' "$context_bytes"
else
  fail=$((fail + 1)); printf '  FAIL  watch context stays within 1400 bytes (%s)\n' "$context_bytes"
fi

if [[ "$got" == *"exactly ONE"* && "$got" == *"fail/cancel"* \
   && "$got" == *"confirmed conflict"* && "$got" == *"including bots"* \
   && "$got" == *"passing checks stay silent"* ]]; then
  pass=$((pass + 1)); printf '  PASS  compact context preserves attach and alert contracts\n'
else
  fail=$((fail + 1)); printf '  FAIL  compact context preserves attach and alert contracts\n'
fi

echo
echo "## Bounded fallback refuses generation-unsafe replay"
LONG_PARENT="$TMP"
for n in 1 2 3 4 5 6 7; do
  long_component="$(printf '%096d' "$n" | tr 0 p)"
  LONG_PARENT="$LONG_PARENT/$long_component"
  mkdir -p "$LONG_PARENT"
done
LONG_REPO="$LONG_PARENT/repo"
git init -q -b harness-branch "$LONG_REPO"
git -C "$LONG_REPO" remote add origin git@github.com:acme/long-widget.git
git -C "$LONG_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
long_context="$(ctx_at "$LONG_REPO" "git push" "")"
long_command="$(printf '%s' "$long_context" | stream_command_from_context)"
if [[ -z "$long_command" \
   && "$long_context" == *"No safe fallback was attached"* \
   && "$long_context" != *"tail -n +1 -F"* ]]; then
  pass=$((pass + 1)); printf '  PASS  oversized paths do not downgrade to raw branch-log replay\n'
else
  fail=$((fail + 1)); printf '  FAIL  oversized paths do not downgrade to raw branch-log replay (cmd=%.120s context=%.160s)\n' \
    "$long_command" "$long_context"
fi
long_context_bytes="$(LC_ALL=C printf '%s' "$long_context" | wc -c | tr -d ' ')"
if (( long_context_bytes <= 1400 )); then
  pass=$((pass + 1)); printf '  PASS  fallback context stays within 1400 bytes (%s)\n' "$long_context_bytes"
else
  fail=$((fail + 1)); printf '  FAIL  fallback context stays within 1400 bytes (%s)\n' "$long_context_bytes"
fi

echo
echo "## Valid branch metacharacters remain command data"
malicious_branch="topic/';touch\${IFS}WATCH_INJECTED;#"
git -C "$REPO" checkout -q -b "$malicious_branch"
malicious_context="$(ctx_at "$REPO" "git push" "")"
malicious_command="$(printf '%s' "$malicious_context" | stream_command_from_context)"
malicious_git_path="$(git -C "$REPO" rev-parse --git-path pr-watch)"
repo_physical="$(cd "$REPO" && pwd -P)"
[[ "$malicious_git_path" == /* ]] || malicious_git_path="$repo_physical/$malicious_git_path"
malicious_branch_key="$(pr_watch_branch_key "$malicious_branch")"
malicious_event_log="$malicious_git_path/$malicious_branch_key.jsonl"
malicious_args_file="$TMP/malicious-watch-args"
WATCH_ARGS_FILE="$malicious_args_file" PATH="$EXEC_STUB:$PATH" \
  /bin/bash -c "$malicious_command" >/dev/null 2>"$TMP/malicious-watch.err"
malicious_status=$?
if [[ "$malicious_status" -eq 0 && ! -e "$REPO/WATCH_INJECTED" \
   && "$(sed -n '1p' "$malicious_args_file" 2>/dev/null)" == 2 \
   && "$(sed -n '3p' "$malicious_args_file" 2>/dev/null)" == "$malicious_event_log" ]]; then
  pass=$((pass + 1)); printf '  PASS  quoted branch cannot add a shell command\n'
else
  fail=$((fail + 1)); printf '  FAIL  quoted branch cannot add a shell command (status=%s injected=%s args=%s expected_event=%s cmd=%.120s)\n' \
    "$malicious_status" "$([[ -e "$REPO/WATCH_INJECTED" ]] && echo yes || echo no)" \
    "$(tr '\n' '|' < "$malicious_args_file" 2>/dev/null)" \
    "$malicious_event_log" "$malicious_command"
fi

echo
echo "## Branch event-log identity"
git -C "$REPO" checkout -q -b foo/bar
slash_context="$(ctx_at "$REPO" "git push" "")"
slash_command="$(printf '%s' "$slash_context" | stream_command_from_context)"
slash_args_file="$TMP/slash-watch-args"
WATCH_ARGS_FILE="$slash_args_file" PATH="$EXEC_STUB:$PATH" \
  /bin/bash -c "$slash_command" >/dev/null 2>"$TMP/slash-watch.err"
slash_status=$?
slash_event_log="$(tail -n 1 "$slash_args_file" 2>/dev/null)"

git -C "$REPO" checkout -q -b foo-bar
dash_context="$(ctx_at "$REPO" "git push" "")"
dash_command="$(printf '%s' "$dash_context" | stream_command_from_context)"
dash_args_file="$TMP/dash-watch-args"
WATCH_ARGS_FILE="$dash_args_file" PATH="$EXEC_STUB:$PATH" \
  /bin/bash -c "$dash_command" >/dev/null 2>"$TMP/dash-watch.err"
dash_status=$?
dash_event_log="$(tail -n 1 "$dash_args_file" 2>/dev/null)"

if [[ "$slash_status" -eq 0 && "$dash_status" -eq 0 \
   && -n "$slash_event_log" && -n "$dash_event_log" \
   && "$slash_event_log" != "$dash_event_log" ]]; then
  pass=$((pass + 1)); printf '  PASS  foo/bar and foo-bar consumer paths cannot alias\n'
else
  fail=$((fail + 1)); printf '  FAIL  foo/bar and foo-bar consumer paths cannot alias (slash=%s dash=%s)\n' \
    "$slash_event_log" "$dash_event_log"
fi

(cd "$REPO" && bash "$WATCHER" --branch foo-bar --pr 42 --once >/dev/null)
git -C "$REPO" checkout -q foo/bar
(cd "$REPO" && bash "$WATCHER" --branch foo/bar --pr 42 --once >/dev/null)
if [[ -f "$slash_event_log" && -f "$dash_event_log" \
   && "$(jq -r 'select(.kind == "watch_start") | .branch' "$slash_event_log" | tail -1)" == "foo/bar" \
   && "$(jq -r 'select(.kind == "watch_start") | .branch' "$dash_event_log" | tail -1)" == "foo-bar" ]]; then
  pass=$((pass + 1)); printf '  PASS  consumer paths exactly match producer event logs\n'
else
  fail=$((fail + 1)); printf '  FAIL  consumer paths exactly match producer event logs\n'
fi

policy_bytes="$(LC_ALL=C wc -c < "$POLICY" | tr -d ' ')"
if (( policy_bytes <= 1800 )); then
  pass=$((pass + 1)); printf '  PASS  escalation policy stays within 1800 bytes (%s)\n' "$policy_bytes"
else
  fail=$((fail + 1)); printf '  FAIL  escalation policy stays within 1800 bytes (%s)\n' "$policy_bytes"
fi

policy="$(cat "$POLICY")"
if [[ "$policy" == *"2 auto-fix attempts"* && "$policy" == *"Never weaken"* \
   && "$policy" == *"not already in this PR's diff"* && "$policy" == *"e2e-local"* \
   && "$policy" == *"product intent"* && "$policy" == *"different error"* \
   && "$policy" == *"pre-existing"* ]]; then
  pass=$((pass + 1)); printf '  PASS  compact policy preserves escalation boundaries\n'
else
  fail=$((fail + 1)); printf '  FAIL  compact policy preserves escalation boundaries\n'
fi

echo
printf 'post-remote-write-watch: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
