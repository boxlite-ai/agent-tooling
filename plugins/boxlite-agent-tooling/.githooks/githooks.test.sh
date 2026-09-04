#!/usr/bin/env bash
# Tests for the agent-agnostic git-hook gate layer (.githooks/pre-commit,
# .githooks/pre-push) and the PreToolUse delegation guard in
# .agents/hooks/preflight-commit-push.sh.
#
# Contract under test:
#   - agent marker present (CLAUDECODE / CODEX_SANDBOX / AGENT_GATED) + no audit -> commit/push rejected
#   - agent marker + fresh matching PASS audit                              -> allowed, audit consumed
#   - no agent marker (human)                                              -> allowed, ungated
#   - framework hook in .git/hooks is chained after the gate (prek keeps running)
#   - PreToolUse script defers when core.hooksPath -> .githooks (single consumer),
#     EXCEPT when called BY the git-level gate (GITHOOK_DELEGATED)
#
# Run with:  bash .githooks/githooks.test.sh
set -uo pipefail

# The harness markers and the gate's own handshake, cleared for the whole suite.
#
# The leak is not in the cases — it is in the FIXTURES. setup() points core.hooksPath
# at the fixture's own .githooks, and every plain `git -C "$R" commit -qm` after that
# point runs without `env -i`. An ambient marker therefore makes the fixture's own
# setup commit look like an unaudited agent, the gate under test correctly rejects
# it, the commit never lands, and each later case grades a repo that was never
# built. Measured on its own, each marker cost: CLAUDECODE 7 of 63 — and every
# Claude Code session exports it — AGENT_GATED 7, CODEX_SANDBOX 8,
# GITHOOK_DELEGATED 4.
#
# So: any fixture commit added here runs under `env -i`, or the marker stays clear.
# Cases that mean to exercise an agent set the marker on their own invocation, and
# that coverage is untouched by this.
unset CODEX_SANDBOX CLAUDECODE AGENT_GATED GITHOOK_DELEGATED GITHOOK_KEEP_AUDIT \
      CODEX_COMMIT_PUSH_AUDIT_MODE

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whichever checkout the shell sits in, so running this
# suite from another worktree silently tests THAT checkout's copy instead of the
# one shipped beside these tests, and a two-side check reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_LIB="$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$STATE_LIB"

pass=0
fail=0

check_eq() {  # desc  got  want
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (got=%s want=%s)\n' "$desc" "$got" "$want"
  fi
}

hash_stdin() {
  shasum -a 256 | awk '{print $1}'
}

diff_hash_for() {
  local repo="$1" kind="$2"
  case "$kind" in
    commit) git -C "$repo" diff --cached --no-ext-diff | hash_stdin ;;
    push)
      {
        git -C "$repo" diff --no-ext-diff origin/main...HEAD 2>/dev/null ||
          git -C "$repo" diff --no-ext-diff HEAD~1...HEAD 2>/dev/null ||
          true
      } | hash_stdin
      ;;
    *) printf 'unknown' | hash_stdin ;;
  esac
}

command_hash_for() {
  printf '%s' "$1" | hash_stdin
}

subject_hash_for() {
  local subject="$1"
  if [[ -n "$subject" ]]; then
    printf '%s' "$subject" | hash_stdin
  fi
}

zero_sha() {
  printf '%040d' 0
}

current_branch_ref() {
  local repo="$1"
  printf 'refs/heads/%s' "$(git -C "$repo" branch --show-current)"
}

write_ref_updates_file() {  # repo remote local_ref remote_ref output_file
  local repo="$1" remote="$2" local_ref="$3" remote_ref="$4" output_file="$5"
  local local_sha remote_sha
  local_sha="$(git -C "$repo" rev-parse "$local_ref")"
  remote_sha="$(git -C "$repo" ls-remote "$remote" "$remote_ref" | awk 'NR == 1 {print $1}')"
  [[ -n "$remote_sha" ]] || remote_sha="$(zero_sha)"
  printf '%s %s %s %s\n' "$local_ref" "$local_sha" "$remote_ref" "$remote_sha" > "$output_file"
}

# Extracted from the real pre-push, not hand-duplicated: a second copy of this
# selection algorithm is exactly how it went stale before (see new_ref_base_sha's
# own history) — a fix applied to only one copy leaves the other asserting
# against a base the real hook no longer picks.
# shellcheck disable=SC2016  # sed scripts are literal; expansion must not happen here.
eval "$(sed -n '/^new_ref_base_sha() {/,/^}/p' "$REPO_ROOT/.githooks/pre-push" | \
  sed -e 's|\${repo_root}|${repo}|g' -e 's|\$repo_root|\$repo|g' \
      -e 's|\${remote_name}|${remote}|g' -e 's|\$remote_name|\$remote|g')"
declare -F new_ref_base_sha >/dev/null || {
  printf 'FATAL: could not extract new_ref_base_sha from .githooks/pre-push\n' >&2
  exit 1
}

pushed_diff_hash_for() {  # repo remote ref_updates_file
  local repo="$1" remote="$2" ref_updates_file="$3"
  local empty_tree local_ref local_sha remote_ref remote_sha base_sha
  empty_tree="$(git -C "$repo" hash-object -t tree /dev/null)"
  while read -r local_ref local_sha remote_ref remote_sha; do
    [[ -n "${local_ref:-}" ]] || continue
    printf '## ref-update %s %s %s %s\n' "$local_ref" "$local_sha" "$remote_ref" "$remote_sha"
    if [[ "$local_sha" =~ ^0+$ ]]; then
      printf 'deleted %s at %s\n' "$remote_ref" "$remote_sha"
    elif [[ "$remote_sha" =~ ^0+$ ]]; then
      base_sha="$(new_ref_base_sha "$local_sha" || true)"
      if [[ -n "$base_sha" ]]; then
        git -C "$repo" log --format='commit-subject %H %s' "$base_sha..$local_sha" 2>/dev/null || true
        git -C "$repo" diff --no-ext-diff "$base_sha" "$local_sha" 2>/dev/null || true
      else
        git -C "$repo" log --format='commit-subject %H %s' "$local_sha" || true
        git -C "$repo" diff --no-ext-diff "$empty_tree" "$local_sha" || true
      fi
    else
      git -C "$repo" log --format='commit-subject %H %s' "$remote_sha..$local_sha" 2>/dev/null || true
      git -C "$repo" diff --no-ext-diff "$remote_sha" "$local_sha" 2>/dev/null || true
    fi
  done < "$ref_updates_file" | hash_stdin
}

pre_push_command_for() {  # repo remote local_ref remote_ref
  local repo="$1" remote="$2" local_ref="$3" remote_ref="$4"
  local remote_url remote_url_hash ref_updates_file ref_updates_hash pushed_diff_hash
  remote_url="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || printf '')"
  remote_url_hash="$(printf '%s' "$remote_url" | hash_stdin)"
  ref_updates_file="$(mktemp)"
  write_ref_updates_file "$repo" "$remote" "$local_ref" "$remote_ref" "$ref_updates_file"
  ref_updates_hash="$(shasum -a 256 "$ref_updates_file" | awk '{print $1}')"
  pushed_diff_hash="$(pushed_diff_hash_for "$repo" "$remote" "$ref_updates_file")"
  rm -f "$ref_updates_file"
  printf 'git push --pre-push-hook remote=%s remote_url_sha256=%s ref_updates_sha256=%s pushed_diff_sha256=%s' \
    "$remote" "$remote_url_hash" "$ref_updates_hash" "$pushed_diff_hash"
}

# Fixture repo with the real gate scripts installed at the same pinned-cache
# path used by consumers. A symlink keeps older assertions that address
# $R/.githooks directly focused on that installed copy.
setup() {
  local d head plugin scratch checkout
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  mkdir -p "$d/.agents/hooks" "$d/.agents/state" "$d/.agents/lib" "$d/.agents/prompts"
  cp "$REPO_ROOT/.agents/hooks/preflight-commit-push.sh" \
     "$REPO_ROOT/.agents/hooks/run-commit-push-audit.sh" \
     "$REPO_ROOT/.agents/hooks/auditor-control.sh" \
     "$REPO_ROOT/.agents/hooks/commit-push-audit.schema.json" \
     "$d/.agents/hooks/"
  # The gate resolves its shared library and prompt documents from its own location,
  # and refuses to gate without them rather than waving the commit through. A fake
  # repo running a COPY of the hook therefore needs both staged beside it.
  cp "$REPO_ROOT/.agents/lib/subagent.sh" \
     "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
     "$REPO_ROOT/.agents/lib/auditor-override-state.sh" \
     "$REPO_ROOT/.agents/lib/auditor-control-state.sh" \
     "$REPO_ROOT/.agents/lib/hook-interactive-prompt.sh" "$d/.agents/lib/"
  cp "$REPO_ROOT/.agents/prompts/"*.md "$d/.agents/prompts/"
  printf 'x\n' > "$d/f"

  scratch="$(mktemp -d)"
  plugin="$scratch/plugins/boxlite-agent-tooling"
  mkdir -p "$plugin"
  cp -R "$REPO_ROOT/.githooks" "$REPO_ROOT/scripts" "$REPO_ROOT/guidance" "$plugin/"
  mkdir -p "$plugin/.agents/lib"
  cp "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
     "$REPO_ROOT/.agents/lib/auditor-override-state.sh" \
     "$REPO_ROOT/.agents/lib/auditor-control-state.sh" \
     "$REPO_ROOT/.agents/lib/hook-interactive-prompt.sh" "$plugin/.agents/lib/"
  git -C "$scratch" init -q
  git -C "$scratch" config user.email t@t.test
  git -C "$scratch" config user.name tester
  git -C "$scratch" add -A
  git -C "$scratch" commit -qm tooling
  head="$(git -C "$scratch" rev-parse HEAD)"

  # A real installed consumer carries the guidance block (setup.sh splices it on
  # adoption), so the fixture must too, or the gate under test rejects every
  # commit for the missing block instead of the property each case pins. Spliced
  # BEFORE the ungated base commit, so the files ride every branch: left
  # untracked, a later `git add -A` would commit them on one branch and the next
  # backward checkout would drop them from the worktree, tripping the gate
  # mid-fixture.
  env -u AGENT_TOOLING_SYNC_ACTIVE -u AGENT_TOOLING_GUIDANCE_FORCE \
    bash "$plugin/scripts/sync-guidance.sh" "$d" >/dev/null 2>&1
  git -C "$d" add -A
  git -C "$d" commit -qm base

  checkout="$d/.git/agent-tooling/$head"
  mkdir -p "$(dirname "$checkout")"
  mv "$scratch" "$checkout"
  plugin="$checkout/plugins/boxlite-agent-tooling"
  ln -s "$plugin/.githooks" "$d/.githooks"
  mkdir -p "$d/.agent-tooling"
  printf '{"tooling":{"repository":"boxlite-ai/agent-tooling","ref":"main"}}\n' > "$d/.agent-tooling/profile.json"
  printf '%s\n' "$head" > "$d/.git/agent-tooling/current"
  printf '/.agent-tooling/\n' >> "$d/.git/info/exclude"
  git -C "$d" config extensions.worktreeConfig true
  git -C "$d" config --worktree core.hooksPath "$plugin/.githooks"
  printf '%s' "$d"
}

# Fresh PASS audit bound to the fixture's current state.
write_audit() {  # repo kind [push_local_ref push_remote_ref]
  local repo="$1" kind="$2" br hd command subject local_ref remote_ref diff_hash
  br="$(git -C "$repo" branch --show-current)"; hd="$(git -C "$repo" rev-parse HEAD)"
  diff_hash="$(diff_hash_for "$repo" "$kind")"
  case "$kind" in
    commit) command="git commit -m change"; subject="change" ;;
    push)
      local_ref="${3:-$(current_branch_ref "$repo")}"
      remote_ref="${4:-$local_ref}"
      command="$(pre_push_command_for "$repo" origin "$local_ref" "$remote_ref")"
      diff_hash="${command##* pushed_diff_sha256=}"
      subject=""
      ;;
    *) command="git ${kind}"; subject="" ;;
  esac
  jq -nc --arg b "$br" --arg h "$hd" --arg k "$kind" \
    --arg dh "$diff_hash" \
    --arg ch "$(command_hash_for "$command")" \
    --arg csh "$(subject_hash_for "$subject")" \
    '{branch:$b, head:$h, command_kind:$k, diff_hash:$dh, command_hash:$ch, commit_subject_hash:$csh, verdict:"PASS", findings:[]}' \
    > "$repo/.agents/state/last-audit.json"
}

# Separate from write_audit() on purpose: every existing case must keep exercising the
# dossier shape with no `advisories` key, which is what a pre-split producer writes.
add_advisories() {  # repo  advisory-text
  local repo="$1" text="$2" f
  f="$repo/.agents/state/last-audit.json"
  jq --arg a "$text" '. + {advisories:[$a]}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

write_handoff_audit() {  # repo kind command
  local repo="$1" kind="$2" command="$3" br hd dh ch
  br="$(git -C "$repo" branch --show-current)"; hd="$(git -C "$repo" rev-parse HEAD)"
  dh="$(diff_hash_for "$repo" "$kind")"
  ch="$(command_hash_for "$command")"
  jq -nc --arg b "$br" --arg h "$hd" --arg k "$kind" \
    --arg dh "$dh" --arg ch "$ch" \
    '{branch:$b, head:$h, command_kind:$k, diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
    > "$repo/.agents/state/last-audit.json"
  jq -nc --arg b "$br" --arg h "$hd" --arg k "$kind" \
    --arg dh "$dh" --arg ch "$ch" \
    '{branch:$b, head:$h, command_kind:$k, diff_hash:$dh, command_hash:$ch}' \
    > "$repo/.agents/state/last-audit-handoff.json"
}

stage_change() {
  local repo="$1"
  printf 'y\n' >> "$repo/f"; git -C "$repo" add -A
}

activate_override_handoff() {  # repo session kind command
  local repo="$1" session="$2" kind="$3" command="$4" scope epoch now repo_hash
  scope="git-$(printf '%s' "$session" | git -C "$repo" hash-object --stdin)"
  epoch="701-702-3"
  now="$(date +%s)"
  printf '%s\n' "$epoch" > "$repo/.agents/state/verdict-prompt-epoch.$scope"
  repo_hash="$(printf '%s' "$(cd "$repo" && pwd -P)" | git -C "$repo" hash-object --stdin)"
  mkdir -p "$repo/.agents/state/auditor-control"
  jq -nc --arg repo_hash "$repo_hash" --arg scope "$scope" --arg epoch "$epoch" \
    --arg nonce_hash "$(printf nonce | shasum -a 256 | awk '{print $1}')" \
    --arg reason_hash "$(printf reason | shasum -a 256 | awk '{print $1}')" \
    --argjson created "$now" --argjson expires "$((now + 3600))" \
    '{repo_hash:$repo_hash,session_scope:$scope,prompt_epoch:$epoch,created_at:$created,
      expires_at:$expires,nonce_hash:$nonce_hash,reason_hash:$reason_hash}' \
    > "$repo/.agents/state/auditor-control/grant.$scope.json"
  printf '%s' "$(jq -nc --arg command "$command" --arg session "$session" \
    '{session_id:$session,tool_input:{command:$command}}')" \
    | (cd "$repo" && CLAUDE_PROJECT_DIR="$repo" \
        bash "$repo/.agents/hooks/preflight-commit-push.sh") >/dev/null
}

# Run `git commit` in the fixture as agent or human; echo the exit code.
# env -i gives a hermetic environment: the ambient session's own harness markers
# (CLAUDECODE, CLAUDE_PROJECT_DIR, plugin CODEX_COMPANION_*) must not leak into
# the fixture's gate decision.
run_commit() {  # repo  agent|human [message]
  local repo="$1" who="$2" message="${3:-change}"
  if [[ "$who" == "agent" ]]; then
    ( cd "$repo" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git commit -qm "$message" >/dev/null 2>"$repo/err.txt" )
  else
    ( cd "$repo" && env -i PATH="$PATH" HOME="$HOME" git commit -qm "$message" >/dev/null 2>"$repo/err.txt" )
  fi
  echo $?
}

write_broken_preflight() {  # repo exit|invalid|decisionless|allow-empty|capture-allow
  local repo="$1" mode="$2"
  case "$mode" in
    exit)
      cat > "$repo/.agents/hooks/preflight-commit-push.sh" <<'BROKEN_PREFLIGHT'
#!/usr/bin/env bash
printf 'boom from delegated preflight\n' >&2
exit 7
BROKEN_PREFLIGHT
      ;;
    invalid)
      cat > "$repo/.agents/hooks/preflight-commit-push.sh" <<'BROKEN_PREFLIGHT'
#!/usr/bin/env bash
printf 'not-json\n'
BROKEN_PREFLIGHT
      ;;
    # Valid JSON, no permissionDecision, no additionalContext. `not-json` cannot reach
    # the advisory arm — jq exits 5 on it, tripping the parse guard above — so only this
    # shape exercises the branch that decides whether the advisory split opened a hole.
    decisionless)
      cat > "$repo/.agents/hooks/preflight-commit-push.sh" <<'BROKEN_PREFLIGHT'
#!/usr/bin/env bash
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}\n'
BROKEN_PREFLIGHT
      ;;
    allow-empty)
      cat > "$repo/.agents/hooks/preflight-commit-push.sh" <<'BROKEN_PREFLIGHT'
#!/usr/bin/env bash
exit 0
BROKEN_PREFLIGHT
      ;;
    capture-allow)
      cat > "$repo/.agents/hooks/preflight-commit-push.sh" <<'BROKEN_PREFLIGHT'
#!/usr/bin/env bash
repo="$(git rev-parse --show-toplevel)"
context="$(git rev-parse --git-path codex-audit/last-push-audit-context.diff)"
[[ "$context" == /* ]] || context="$repo/$context"
cp "$context" "$repo/captured-push-evidence.diff"
exit 0
BROKEN_PREFLIGHT
      ;;
  esac
  chmod +x "$repo/.agents/hooks/preflight-commit-push.sh"
}

try_commit() {  # repo  agent|human
  local repo="$1" who="$2"
  stage_change "$repo"
  run_commit "$repo" "$who"
}

if grep -q 'last-push-audit-context.json' "$REPO_ROOT/.claude/agents/commit-push-auditor.md" \
    && grep -q '\.diff.*companion' "$REPO_ROOT/.claude/agents/commit-push-auditor.md" \
    && grep -q "context diff file's SHA-256" "$REPO_ROOT/.claude/agents/commit-push-auditor.md"; then
  auditor_exact=yes
else
  auditor_exact=no
fi
check_eq "commit-push auditor prompt uses exact push context" "$auditor_exact" "yes"
grep -q 'git log origin/main..HEAD' "$REPO_ROOT/.claude/agents/commit-push-auditor.md" && auditor_broad=yes || auditor_broad=no
check_eq "commit-push auditor prompt omits broad push subject range" "$auditor_broad" "no"

echo "## pre-commit: agent gated, human exempt"
R="$(setup)"
check_eq "agent + no audit → commit rejected"       "$(try_commit "$R" agent)" 1
grep -q 'commit-push-auditor' "$R/err.txt" && names=yes || names=no
check_eq "rejection names commit-push-auditor"      "$names" "yes"
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
check_eq "agent + PASS audit → commit allowed"      "$(run_commit "$R" agent)" 0
[[ -e "$R/.agents/state/last-audit.json" ]] && consumed=no || consumed=yes
check_eq "audit consumed by the git-level gate"     "$consumed" "yes"
rm -rf "$R"

R="$(setup)"; stage_change "$R"
activate_override_handoff "$R" session-override commit "git commit"
check_eq "prompt-scoped override allows an editor-style commit without an audit dossier" \
  "$(run_commit "$R" agent 'test: overridden commit')" 0
override_scope="git-$(printf '%s' session-override | git -C "$R" hash-object --stdin)"
override_log="$R/.agents/state/auditor-control/uses.$override_scope.log"
override_commit_state="grant=$([[ -e "$R/.agents/state/auditor-control/grant.$override_scope.json" ]] && echo kept || echo gone) audit=$([[ -e "$R/.agents/state/last-audit.json" ]] && echo yes || echo no) preflight=$(grep -c 'boundary=commit-preflight' "$override_log" 2>/dev/null) commitmsg=$(grep -c 'boundary=commit-msg' "$override_log" 2>/dev/null)"
check_eq "commit override keeps the grant and logs pre-commit plus actual-subject use" \
  "$override_commit_state" "grant=kept audit=no preflight=1 commitmsg=1"
rm -rf "$R"

R="$(setup)"; stage_change "$R"
activate_override_handoff "$R" session-foreign-owner commit "git commit"
perl -e 'select(undef,undef,undef,10)' & foreign_owner_pid=$!
foreign_owner_token="$(verdict_audit_process_start_token "$foreign_owner_pid")"
jq --argjson pid "$foreign_owner_pid" --arg token "$foreign_owner_token" \
  '.owner={pid:$pid,start_token:$token}' \
  "$R/.agents/state/last-audit-handoff.json" > "$R/.agents/state/foreign-owner.json" \
  && mv "$R/.agents/state/foreign-owner.json" "$R/.agents/state/last-audit-handoff.json"
foreign_owner_rc="$(run_commit "$R" agent 'test: foreign override rejected')"
kill "$foreign_owner_pid" 2>/dev/null || true
wait "$foreign_owner_pid" 2>/dev/null || true
check_eq "a concurrent agent process cannot consume another session override handoff" \
  "$foreign_owner_rc" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"
activate_override_handoff "$R" session-override-log-fail commit "git commit"
override_scope="git-$(printf '%s' session-override-log-fail | git -C "$R" hash-object --stdin)"
override_log="$R/.agents/state/auditor-control/uses.$override_scope.log"
rm -f "$override_log"
printf 'outside\n' > "$R/outside-use-log"
ln -s "$R/outside-use-log" "$override_log"
check_eq "commit override fails closed when pre-commit use evidence cannot be written" \
  "$(run_commit "$R" agent 'test: rejected override evidence')" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"
activate_override_handoff "$R" session-override-msg-log-fail commit "git commit"
override_scope="git-$(printf '%s' session-override-msg-log-fail | git -C "$R" hash-object --stdin)"
override_log="$R/.agents/state/auditor-control/uses.$override_scope.log"
printf '{"tool_input":{"command":"git commit"}}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" GITHOOK_DELEGATED=1 \
      GITHOOK_KEEP_AUDIT=1 bash "$R/.agents/hooks/preflight-commit-push.sh") >/dev/null
rm -f "$override_log"
printf 'outside\n' > "$R/outside-use-log"
ln -s "$R/outside-use-log" "$override_log"
printf 'test: rejected commit-msg evidence\n' > "$R/msg.txt"
(cd "$R" && CLAUDECODE=1 "$R/.githooks/commit-msg" "$R/msg.txt" \
  >/dev/null 2>"$R/err.txt")
check_eq "commit-msg override fails closed when actual-subject use evidence cannot be written" \
  "$?" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
check_eq "agent + audited subject mismatch → commit rejected" "$(run_commit "$R" agent other)" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
jq '.commit_subject_hash=""' "$R/.agents/state/last-audit.json" > "$R/.agents/state/x.json" \
  && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit.json"
check_eq "agent + unaudited bad subject → commit rejected" "$(run_commit "$R" agent bad)" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
jq '.commit_subject_hash=""' "$R/.agents/state/last-audit.json" > "$R/.agents/state/x.json" \
  && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit.json"
check_eq "agent + missing audited subject → commit rejected" "$(run_commit "$R" agent "test: good")" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
hooks_dir="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
mkdir -p "$hooks_dir"
printf '#!/bin/sh\nprintf "bad: rewritten by chained hook\\n" > "$1"\n' > "$hooks_dir/commit-msg"
chmod +x "$hooks_dir/commit-msg"
check_eq "agent + message rewrite after audit → commit rejected" "$(run_commit "$R" agent)" 1
grep -q 'Commit message does not match' "$R/err.txt" && guarded=yes || guarded=no
check_eq "message rewrite rejection names subject mismatch" "$guarded" "yes"
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_audit "$R" commit
hooks_dir="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
mkdir -p "$hooks_dir"
printf '#!/bin/sh\nprintf staged-after-audit >> "%s/f"\ngit -C "%s" add f\n' "$R" "$R" > "$hooks_dir/pre-commit"
chmod +x "$hooks_dir/pre-commit"
check_eq "agent + staged content after audit → commit rejected" "$(run_commit "$R" agent)" 1
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_broken_preflight "$R" exit
check_eq "agent + delegated preflight nonzero → commit rejected" "$(run_commit "$R" agent)" 1
grep -q 'delegated preflight failed' "$R/err.txt" && fail_closed=yes || fail_closed=no
check_eq "commit nonzero rejection names delegated preflight" "$fail_closed" "yes"
rm -rf "$R"

R="$(setup)"; stage_change "$R"; write_broken_preflight "$R" invalid
check_eq "agent + delegated preflight invalid JSON → commit rejected" "$(run_commit "$R" agent)" 1
grep -q 'invalid output' "$R/err.txt" && fail_closed=yes || fail_closed=no
check_eq "commit invalid-output rejection names invalid output" "$fail_closed" "yes"
rm -rf "$R"

R="$(setup)"
check_eq "human (no marker) → commit allowed"       "$(try_commit "$R" human)" 0
rm -rf "$R"

echo
echo "## chaining: the framework hook in .git/hooks still runs"
R="$(setup)"
# --git-common-dir: --git-path hooks would resolve through core.hooksPath and
# point back at the adapter itself (the exact recursion the adapters guard).
# Absolutize from inside the fixture — the raw output is cwd-relative (".git").
hooks_dir="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
mkdir -p "$hooks_dir"
printf '#!/bin/sh\ntouch "%s/chained.ran"\n' "$R" > "$hooks_dir/pre-commit"
chmod +x "$hooks_dir/pre-commit"
try_commit "$R" human >/dev/null
[[ -e "$R/chained.ran" ]] && chained=yes || chained=no
check_eq "chained .git/hooks/pre-commit executed"   "$chained" "yes"
rm -rf "$R"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
hooks_dir="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd)/hooks"
mkdir -p "$hooks_dir"
printf '#!/bin/sh\ncat > "%s/pre-push.stdin"\n' "$R" > "$hooks_dir/pre-push"
chmod +x "$hooks_dir/pre-push"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
grep -q "$branch_ref" "$R/pre-push.stdin" && replayed=yes || replayed=no
check_eq "chained .git/hooks/pre-push receives stdin" "$replayed" "yes"
rm -rf "$R" "$B"

echo
echo "## Advisories cross the git-level boundary without blocking"
# The PreToolUse suite pins core.hooksPath='' and cannot see this layer, but in an
# installed clone THIS is the only consumer of the gate's stdout. It used to reject any
# non-deny payload, making an advisory MORE blocking than a finding — a finding at least
# yields an actionable reason.
R="$(setup)"; stage_change "$R"; write_audit "$R" commit
add_advisories "$R" "Implement: comment wraps awkwardly"
check_eq "agent + PASS with advisories → commit allowed" "$(run_commit "$R" agent)" 0
grep -q 'comment wraps awkwardly' "$R/err.txt" && adv_shown=yes || adv_shown=no
check_eq "advisory text reaches the author"              "$adv_shown" "yes"
grep -q 'invalid output' "$R/err.txt" && adv_invalid=yes || adv_invalid=no
check_eq "advisory is not treated as invalid output"     "$adv_invalid" "no"
rm -rf "$R"

# The arm that decides whether the split opened a hole. Drop or invert the emptiness
# test on `advisory` and the gate fails OPEN. Both boundaries, because the two parses
# are duplicated. A valid PASS audit is written first: without one, commit-msg rejects
# on its own and the case passes no matter what pre-commit decides.
R="$(setup)"; stage_change "$R"; write_audit "$R" commit
write_broken_preflight "$R" decisionless
check_eq "decision-less payload with no advisory → commit rejected" "$(run_commit "$R" agent)" 1
rm -rf "$R"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
write_audit "$R" push
add_advisories "$R" "Implement: comment wraps awkwardly"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + PASS with advisories → push allowed"   "$?" 0
grep -q 'comment wraps awkwardly' "$R/err.txt" && adv_push=yes || adv_push=no
check_eq "advisory text reaches the author on push"      "$adv_push" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
write_audit "$R" push; write_broken_preflight "$R" decisionless
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "decision-less payload with no advisory → push rejected" "$?" 1
rm -rf "$R" "$B"

echo
echo "## pre-push: same contract at the push boundary"

# The real Git protocol is a stream. The hook must cap that stream before it
# expands each update into logs/diffs; the runner's later 16 MiB read cap cannot
# reclaim time or disk already spent by this producer.
R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
same_sha="$(git -C "$R" rev-parse HEAD)"
large_ref_component="$(perl -e 'print "r" x 180')"
many_refs="$R/many-ref-updates.in"
installed_pre_push="$(git -C "$R" config --worktree --get core.hooksPath)/pre-push"
: > "$many_refs"
for many_ref_index in $(seq 1 1000); do
  printf 'refs/heads/%s-%04d %s refs/heads/%s-%04d %s\n' \
    "$large_ref_component" "$many_ref_index" "$same_sha" \
    "$large_ref_component" "$many_ref_index" "$same_sha" >> "$many_refs"
done
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 \
    BOXLITE_PR_WATCH=0 bash "$installed_pre_push" origin "$B" \
    < "$many_refs" >/dev/null 2>"$R/err.txt" )
many_refs_rc=$?
check_eq "oversized ref-update ingress fails closed before diff expansion" \
  "$many_refs_rc" 1
grep -q 'ref-update input exceeds the 262144-byte ingress limit' "$R/err.txt" \
  && many_refs_named=yes || many_refs_named=no
check_eq "oversized ref-update rejection names its hard ingress limit" \
  "$many_refs_named" yes
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
perl -e 'print "large pushed diff line: ", "x" x (17 * 1024 * 1024)' > "$R/large-diff.txt"
git -C "$R" add large-diff.txt
env -i PATH="$PATH" HOME="$HOME" git -C "$R" \
  -c user.email=t@t.test -c user.name=tester commit -qm 'test(hooks): large push ingress'
large_sha="$(git -C "$R" rev-parse HEAD)"
installed_pre_push="$(git -C "$R" config --worktree --get core.hooksPath)/pre-push"
printf 'refs/heads/large %s refs/heads/large %s\n' \
  "$large_sha" "$(zero_sha)" > "$R/large-ref-update.in"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 \
    BOXLITE_PR_WATCH=0 bash "$installed_pre_push" origin "$B" \
    < "$R/large-ref-update.in" >/dev/null 2>"$R/err.txt" )
large_diff_rc=$?
check_eq "oversized expanded push diff fails closed at the producer" \
  "$large_diff_rc" 1
grep -q 'expanded push context exceeds the 16777216-byte ingress limit' "$R/err.txt" \
  && large_diff_named=yes || large_diff_named=no
check_eq "expanded-context rejection names its producer-side limit" \
  "$large_diff_named" yes
rm -rf "$R" "$B"

# The remote-advertised old object may be absent from a shallow/stale local
# object database. An empty header is not review evidence, and pre-push may not
# fetch, so this boundary must reject before calling the delegated auditor.
R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
write_broken_preflight "$R" allow-empty
installed_pre_push="$(git -C "$R" config --worktree --get core.hooksPath)/pre-push"
local_sha="$(git -C "$R" rev-parse HEAD)"
missing_old_sha="1111111111111111111111111111111111111111"
printf 'refs/heads/main %s refs/heads/main %s\n' \
  "$local_sha" "$missing_old_sha" > "$R/missing-old-ref-update.in"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 \
    BOXLITE_PR_WATCH=0 bash "$installed_pre_push" origin "$B" \
    < "$R/missing-old-ref-update.in" >/dev/null 2>"$R/err.txt" )
missing_old_rc=$?
check_eq "missing remote old object rejects evidence-free push audit" \
  "$missing_old_rc" 1
grep -q 'advertised old object .* is unavailable locally; fetch before pushing' \
  "$R/err.txt" && missing_old_named=yes || missing_old_named=no
check_eq "missing-old-object rejection explains the local evidence requirement" \
  "$missing_old_named" yes
rm -rf "$R" "$B"

# Replace refs alter ordinary revision traversal, but Git pushes the raw object
# named by the ref. The audit context must therefore ignore replacements too.
# This drives a real push and inspects both sides of the boundary: the evidence
# captured by the delegated gate and the raw file stored by the bare remote.
R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
base_sha="$(git -C "$R" rev-parse HEAD)"
printf 'bad raw payload\n' > "$R/f"
git -C "$R" add f
env -i PATH="$PATH" HOME="$HOME" git -C "$R" \
  -c user.email=t@t.test -c user.name=tester \
  commit -qm 'test(hooks): raw replacement payload'
raw_bad_sha="$(git -C "$R" rev-parse HEAD)"
base_tree="$(git -C "$R" rev-parse "${base_sha}^{tree}")"
clean_replacement_sha="$(printf 'test(hooks): clean replacement view\n' \
  | git -C "$R" -c user.email=t@t.test -c user.name=tester \
      commit-tree "$base_tree" -p "$base_sha")"
git -C "$R" replace "$raw_bad_sha" "$clean_replacement_sha"
write_broken_preflight "$R" capture-allow
replace_remote_ref="refs/heads/replace-evidence"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 \
    BOXLITE_PR_WATCH=0 git push -q origin \
    "HEAD:$replace_remote_ref" >/dev/null 2>"$R/err.txt" )
replace_push_rc=$?
replace_remote_sha="$(git --git-dir="$B" rev-parse "$replace_remote_ref" 2>/dev/null || true)"
replace_remote_body="$(git --git-dir="$B" show "$replace_remote_ref:f" 2>/dev/null || true)"
grep -q '^+bad raw payload$' "$R/captured-push-evidence.diff" 2>/dev/null \
  && replace_evidence=raw || replace_evidence=sanitized
check_eq "push evidence ignores replace objects and matches the raw remote commit" \
  "$replace_push_rc:$replace_remote_sha:$replace_remote_body:$replace_evidence" \
  "0:$raw_bad_sha:bad raw payload:raw"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + no audit → push rejected"         "$?" 1
grep -q 'pushed_diff_sha256=' "$R/err.txt" && synthetic_named=yes || synthetic_named=no
check_eq "push rejection names synthetic audit command" "$synthetic_named" "yes"
context_path="$(git -C "$R" rev-parse --git-path codex-audit/last-push-audit-context.diff)"
[[ "$context_path" != /* ]] && context_path="$R/$context_path"
[[ -e "$context_path" && "$context_path" != "$R/.agents/state/"* ]] && context_retained=yes || context_retained=no
check_eq "rejected push keeps git-private diff context" "$context_retained" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
context_dir="$(git -C "$R" rev-parse --git-path codex-audit)"
[[ "$context_dir" != /* ]] && context_dir="$R/$context_dir"
mkdir -p "$context_dir"
printf 'outside diff sentinel\n' > "$R/outside-context.diff"
printf 'outside metadata sentinel\n' > "$R/outside-context.json"
ln -s "$R/outside-context.diff" "$context_dir/last-push-audit-context.diff"
ln -s "$R/outside-context.json" "$context_dir/last-push-audit-context.json"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 BOXLITE_PR_WATCH=0 \
    git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
unsafe_publish_rc=$?
if [[ "$unsafe_publish_rc" == 1 \
   && "$(cat "$R/outside-context.diff")" == "outside diff sentinel" \
   && "$(cat "$R/outside-context.json")" == "outside metadata sentinel" \
   && -f "$context_dir/last-push-audit-context.diff" \
   && ! -L "$context_dir/last-push-audit-context.diff" \
   && -f "$context_dir/last-push-audit-context.json" \
   && ! -L "$context_dir/last-push-audit-context.json" ]]; then
  unsafe_publish=atomic
else
  unsafe_publish=followed
fi
check_eq "pre-push context publication never follows destination symlinks" \
  "$unsafe_publish" atomic
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
write_audit "$R" push
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + PASS audit → push allowed"        "$?" 0
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
activate_override_handoff "$R" session-push-override push "git push origin $branch_ref:$branch_ref"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 BOXLITE_PR_WATCH=0 \
    git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "prompt-scoped override allows the exact pre-push ref update without an audit dossier" "$?" 0
push_override_scope="git-$(printf '%s' session-push-override | git -C "$R" hash-object --stdin)"
push_override_log="$R/.agents/state/auditor-control/uses.$push_override_scope.log"
push_override_state="grant=$([[ -e "$R/.agents/state/auditor-control/grant.$push_override_scope.json" ]] && echo kept || echo gone) audit=$([[ -e "$R/.agents/state/last-audit.json" ]] && echo yes || echo no) exact=$(grep -c 'boundary=push-preflight' "$push_override_log" 2>/dev/null) remote=$(git -C "$R" ls-remote origin "$branch_ref" | wc -l | tr -d ' ')"
check_eq "push override keeps downstream push behavior and logs exact-diff use" \
  "$push_override_state" "grant=kept audit=no exact=1 remote=1"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
printf 'codex push\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): codex delegated push audit'
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'PUSH_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/push-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/push-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
if [[ -n "${CODEX_FAKE_DELAY:-}" ]]; then
  perl -e 'select(undef,undef,undef,$ARGV[0])' "$CODEX_FAKE_DELAY"
fi
PUSH_FAKE_CODEX
chmod +x "$R/bin/codex"
push_lifecycle_session="session-codex-push"
push_lifecycle_scope="git-$(printf '%s' "$push_lifecycle_session" | git -C "$R" hash-object --stdin)"
push_lifecycle_epoch=1201-1202-12
printf '%s\n' "$push_lifecycle_epoch" \
  > "$R/.agents/state/verdict-prompt-epoch.$push_lifecycle_scope"
push_command="git push origin $branch_ref:$branch_ref"
printf '%s' "$(jq -nc --arg command "$push_command" --arg session "$push_lifecycle_session" \
  '{session_id:$session,tool_input:{command:$command}}')" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" \
      bash "$R/.agents/hooks/preflight-commit-push.sh") >/dev/null
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt \
    CODEX_BIN="$R/bin/codex" CODEX_FAKE_DELAY=0.2 AUDITOR_PROMPT_AFTER_SECONDS=0 \
    git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "Codex delegated pre-push self-audits exact ref update" "$?" 0
push_lifecycle_escalation="$(find "$R/.agents/state/auditor-control" -type f \
  -name "escalation.$push_lifecycle_scope.commit-push-auditor.*.json" -print -quit 2>/dev/null)"
push_lifecycle_state="$(jq -r '.state + ":" + .terminal' "$push_lifecycle_escalation" 2>/dev/null)"
check_eq "automatic pre-push carries session lifecycle into the real headless audit" \
  "$push_lifecycle_state" "closed:PASS"
grep -Eq '^Evidence path JSON: ".*"$' "$R/push-prompt.txt" \
  && grep -Eq '^Evidence SHA-256: [0-9a-f]{64}$' "$R/push-prompt.txt" \
  && evidence_binding=yes || evidence_binding=no
check_eq "Codex push prompt binds readable private evidence by path and hash" "$evidence_binding" "yes"
grep -q 'Sanitized pre-push ref-update diff' "$R/push-evidence.txt" && exact_prompt=yes || exact_prompt=no
check_eq "Codex push audit evidence uses pre-push diff context" "$exact_prompt" "yes"
grep -q 'Commit subjects in the exact pre-push ref-update context' "$R/push-evidence.txt" && exact_subjects=yes || exact_subjects=no
check_eq "Codex push audit evidence uses exact ref-update subjects" "$exact_subjects" "yes"
grep -q '"test(hooks): codex delegated push audit"' "$R/push-evidence.txt" && pushed_subject=yes || pushed_subject=no
check_eq "Codex push audit evidence includes pushed subject JSON" "$pushed_subject" "yes"
grep -q '"base"' "$R/push-evidence.txt" && base_subject=yes || base_subject=no
check_eq "Codex push audit evidence excludes already-pushed subject JSON" "$base_subject" "no"
grep -q 'Commit subjects on origin/main..HEAD' "$R/push-evidence.txt" && broad_subjects=yes || broad_subjects=no
check_eq "Codex push audit evidence omits broad branch subjects" "$broad_subjects" "no"
if grep -q 'Sanitized pre-push ref-update diff' "$R/push-prompt.txt" \
    || grep -q '"test(hooks): codex delegated push audit"' "$R/push-prompt.txt"; then
  eager_context=yes
else
  eager_context=no
fi
check_eq "Codex push prompt keeps full diff and subjects lazy" "$eager_context" "no"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
git -C "$R" fetch -q origin
git -C "$R" checkout -qb new-ref-test
printf 'new ref\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): new ref audit'
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'NEW_REF_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/new-ref-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/new-ref-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
NEW_REF_FAKE_CODEX
chmod +x "$R/bin/codex"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" git push -q origin "refs/heads/new-ref-test:refs/heads/new-ref-test" >/dev/null 2>"$R/err.txt" )
check_eq "Codex delegated new-ref push self-audits from remote base" "$?" 0
grep -q '+new ref' "$R/new-ref-evidence.txt" && grep -q 'commit-subject .*test(hooks): new ref audit' "$R/new-ref-evidence.txt" && ! grep -q 'commit-subject .*base' "$R/new-ref-evidence.txt" && new_ref_context=yes || new_ref_context=no
check_eq "new-ref audit excludes unchanged base history" "$new_ref_context" "yes"
rm -rf "$R" "$B"

# new_ref_base_sha must pick the CLOSEST ancestor among remote-tracking refs,
# not the first one for-each-ref happens to list. "aaa-early" sorts before
# "zzz-late" alphabetically and IS also an ancestor of the new branch (it's
# zzz-late's own ancestor) — a scan that stops at the first match would pick
# aaa-early's far older commit as the base and drag its whole history into
# the audited diff. Neither branch is named main/master, so this exercises
# the fallback scan specifically, not the default-branch fast path.
R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
# Outside $R, not "$R/err.txt": the checkouts below cross branches after a
# `git add -A`, which would otherwise sweep a same-named file into history
# and then dirty the working tree on the next redirect — the exact hazard
# the "moved_on_err" test below documents.
aaa_zzz_err="$(mktemp)"
git -C "$R" checkout -qb aaa-early
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin aaa-early:aaa-early >/dev/null 2>"$aaa_zzz_err" )
git -C "$R" checkout -qb zzz-late
printf 'late 1\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): zzz-late c1'
printf 'late 2\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): zzz-late c2'
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin zzz-late:zzz-late >/dev/null 2>"$aaa_zzz_err" )
git -C "$R" fetch -q origin
git -C "$R" checkout -qb closest-base-test zzz-late
printf 'newest\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): closest base new commit'
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'CLOSEST_BASE_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/closest-base-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/closest-base-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
CLOSEST_BASE_FAKE_CODEX
chmod +x "$R/bin/codex"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" git push -q origin "refs/heads/closest-base-test:refs/heads/closest-base-test" >/dev/null 2>"$R/err.txt" )
check_eq "Codex delegated closest-base push self-audits" "$?" 0
grep -q 'commit-subject .*closest base new commit' "$R/closest-base-evidence.txt" \
  && ! grep -q 'commit-subject .*zzz-late c1' "$R/closest-base-evidence.txt" \
  && ! grep -q 'commit-subject .*zzz-late c2' "$R/closest-base-evidence.txt" \
  && closest_base_context=yes || closest_base_context=no
check_eq "new-ref base picks closest ancestor, not first in ref order" "$closest_base_context" "yes"
rm -rf "$R" "$B" "$aaa_zzz_err"

# new_ref_base_sha must use merge-base, not is-ancestor: by the time a branch
# is pushed, the default branch has often moved on with unrelated commits, so
# its current tip is no longer a strict ancestor of the pushed commit at all
# (is-ancestor returns false) even though the real fork point is easy to find.
# A candidate-selection fix that still gates on is-ancestor would exclude
# main entirely here and fall through to whatever unrelated ref the scan
# finds first — reproducing the same wrong-base bug from a different angle.
# Stderr from every push in this test goes to a file OUTSIDE the repo: this
# test (unlike its siblings) checks out backward to a PREVIOUS branch after
# committing forward, and a redirect target inside $R gets caught by the next
# `git add -A`, tracked with whatever content it held at that moment, then
# silently rewritten (dirtied) by a later push's redirect without a matching
# commit — so the following checkout to a branch with a DIFFERENT committed
# version of that same path fails with "would be overwritten by checkout".
moved_on_err="$(mktemp)"
R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$moved_on_err" )
git -C "$R" checkout -qb moved-on-feature
printf 'feature 1\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): feature before main moves on'
git -C "$R" checkout -q "${branch_ref#refs/heads/}"
printf 'main moved on 1\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): main moved on c1'
printf 'main moved on 2\n' >> "$R/f2"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): main moved on c2'
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$moved_on_err" )
git -C "$R" fetch -q origin
git -C "$R" checkout -q moved-on-feature
printf 'feature 2\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): feature after main moved on'
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'MOVED_ON_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/moved-on-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/moved-on-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
MOVED_ON_FAKE_CODEX
chmod +x "$R/bin/codex"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" git push -q origin "refs/heads/moved-on-feature:refs/heads/moved-on-feature" >/dev/null 2>"$moved_on_err" )
check_eq "Codex delegated moved-on-base push self-audits" "$?" 0
grep -q 'commit-subject .*feature before main moves on' "$R/moved-on-evidence.txt" \
  && grep -q 'commit-subject .*feature after main moved on' "$R/moved-on-evidence.txt" \
  && ! grep -q 'commit-subject .*main moved on c1' "$R/moved-on-evidence.txt" \
  && ! grep -q 'commit-subject .*main moved on c2' "$R/moved-on-evidence.txt" \
  && moved_on_context=yes || moved_on_context=no
check_eq "new-ref base finds real fork point after default branch moves on" "$moved_on_context" "yes"
rm -rf "$R" "$B" "$moved_on_err"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
printf 'force base\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): force base'
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
base_sha="$(git -C "$R" rev-parse HEAD)"
printf 'force rewind\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): force rewind'
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
git -C "$R" reset -q --hard "$base_sha"
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'REWIND_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/rewind-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/rewind-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
REWIND_FAKE_CODEX
chmod +x "$R/bin/codex"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" git push -q --force origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "Codex delegated force-push rewind self-audits" "$?" 0
grep -q '^-force rewind' "$R/rewind-evidence.txt" && rewind_diff=yes || rewind_diff=no
check_eq "force-push rewind audit includes reverse diff" "$rewind_diff" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
delete_ref="refs/heads/delete-me"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$delete_ref" >/dev/null 2>"$R/err.txt" )
mkdir -p "$R/bin"
cat > "$R/bin/codex" <<'DELETE_FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" > "$cd_arg/delete-prompt.txt"
evidence_path_json="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence path JSON: //p' | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")')"
evidence_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Evidence SHA-256: //p' | head -1)"
[[ -r "$evidence_path" ]]
[[ "$(shasum -a 256 < "$evidence_path" | awk '{print $1}')" == "$evidence_hash" ]]
cp "$evidence_path" "$cd_arg/delete-evidence.txt"
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
diff_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected diff hash: //p')"
command_hash="$(printf '%s\n' "$prompt" | sed -n 's/^Expected command hash: //p')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" \
  '{branch:$b, head:$h, command_kind:"push", diff_hash:$dh, command_hash:$ch, commit_subject_hash:"", verdict:"PASS", findings:[]}' \
  > "$output"
DELETE_FAKE_CODEX
chmod +x "$R/bin/codex"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" git push -q origin ":$delete_ref" >/dev/null 2>"$R/err.txt" )
check_eq "Codex delegated delete-ref push self-audits" "$?" 0
grep -q "deleted $delete_ref" "$R/delete-evidence.txt" && delete_diff=yes || delete_diff=no
check_eq "delete-ref audit includes deletion context" "$delete_diff" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
write_audit "$R" push
jq --arg ch "$(command_hash_for "git push --different-command")" '.command_hash=$ch' \
  "$R/.agents/state/last-audit.json" > "$R/.agents/state/x.json" \
  && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit.json"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + push command hash mismatch → push rejected" "$?" 1
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
base_branch="$(git -C "$R" branch --show-current)"
branch_ref="$(current_branch_ref "$R")"
git -C "$R" checkout -qb audit-escape
printf 'evil\n' >> "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm 'test(hooks): alternate ref'
evil_ref="$(current_branch_ref "$R")"
git -C "$R" checkout -q "$base_branch"
write_audit "$R" push "$branch_ref" "$branch_ref"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$evil_ref:$evil_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + audited push of different ref → push rejected" "$?" 1
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; M="$(mktemp -d)"
git init -q --bare "$B"; git init -q --bare "$M"
git -C "$R" remote add origin "$B"; git -C "$R" remote add mirror "$M"
branch_ref="$(current_branch_ref "$R")"
write_handoff_audit "$R" push "git push mirror $branch_ref"
handoff_diff_hash="$(pre_push_command_for "$R" origin "$branch_ref" "$branch_ref")"
handoff_diff_hash="${handoff_diff_hash##* pushed_diff_sha256=}"
jq --arg dh "$handoff_diff_hash" '.diff_hash=$dh' "$R/.agents/state/last-audit.json" > "$R/.agents/state/x.json" \
  && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit.json"
jq --arg dh "$handoff_diff_hash" '.diff_hash=$dh' "$R/.agents/state/last-audit-handoff.json" > "$R/.agents/state/x.json" \
  && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit-handoff.json"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + push audit bound only to handoff → push rejected" "$?" 1
rm -rf "$R" "$B" "$M"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
write_broken_preflight "$R" exit
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + delegated preflight nonzero → push rejected" "$?" 1
grep -q 'delegated preflight failed' "$R/err.txt" && fail_closed=yes || fail_closed=no
check_eq "push nonzero rejection names delegated preflight" "$fail_closed" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
write_broken_preflight "$R" invalid
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" CLAUDECODE=1 git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "agent + delegated preflight invalid JSON → push rejected" "$?" 1
grep -q 'invalid output' "$R/err.txt" && fail_closed=yes || fail_closed=no
check_eq "push invalid-output rejection names invalid output" "$fail_closed" "yes"
rm -rf "$R" "$B"

R="$(setup)"
B="$(mktemp -d)"; git init -q --bare "$B"; git -C "$R" remote add origin "$B"
branch_ref="$(current_branch_ref "$R")"
( cd "$R" && env -i PATH="$PATH" HOME="$HOME" git push -q origin "$branch_ref:$branch_ref" >/dev/null 2>"$R/err.txt" )
check_eq "human → push allowed, ungated"            "$?" 0
rm -rf "$R" "$B"

echo
echo "## delegation guard: exactly one consumer of the audit artifact"
# With hooksPath installed, the PreToolUse layer must step aside (exit 0,
# no deny) even when a commit would otherwise be rejected...
R="$(setup)"
out="$(printf '{"tool_input":{"command":"git commit -m x"}}' \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
check_eq "PreToolUse defers when .githooks installed"  "${out:-EMPTY}" "EMPTY"
rm -rf "$R"

# Codex is different from Claude here: its PreToolUse hook must produce the
# audit artifact before deferring, then the git-level delegate consumes it.
R="$(setup)"
mkdir -p "$R/bin"
printf 'z\n' >> "$R/f"; git -C "$R" add -A
cat > "$R/bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli fake\n'
  exit 0
fi
cd_arg=""; output=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd) cd_arg="$2"; shift 2 ;;
    --output-last-message|-o) output="$2"; shift 2 ;;
    -) prompt="$(cat)"; shift ;;
    --ask-for-approval|--disable|--sandbox|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    *) shift ;;
  esac
done
branch="$(git -C "$cd_arg" branch --show-current)"
head="$(git -C "$cd_arg" rev-parse HEAD)"
command="$(printf '%s' "$prompt" | sed -n '/^{"target_command":/p' | jq -r '.target_command')"
diff_hash="$(git -C "$cd_arg" diff --cached --no-ext-diff | shasum -a 256 | awk '{print $1}')"
command_hash="$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')"
commit_subject="$(printf '%s' "$command" | sed -n "s/.* -m '\([^']*\)'.*/\1/p" | head -1)"
commit_subject_hash="$(printf '%s' "$commit_subject" | shasum -a 256 | awk '{print $1}')"
jq -nc --arg b "$branch" --arg h "$head" --arg dh "$diff_hash" --arg ch "$command_hash" --arg csh "$commit_subject_hash" \
  '{branch:$b, head:$h, command_kind:"commit", diff_hash:$dh, command_hash:$ch, commit_subject_hash:$csh, verdict:"PASS", findings:[]}' \
  > "$output"
FAKE_CODEX
chmod +x "$R/bin/codex"
# The contract is that the audit SURVIVES for commit-msg, not that it sits at a
# particular path: the gate copies it to the legacy location so a commit-msg
# from before the move can read it too. Reachable at either location counts;
# absent from both means commit-msg will block a commit that was audited.
audit_reachable() {
  local root="$1"
  if [[ -e "$root/.agents/state/last-audit.json" || -e "$root/.claude/.last-audit.json" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}
handoff_reachable() {
  local root="$1" n=0
  [[ -e "$root/.agents/state/last-audit-handoff.json" ]] && n=$((n+1))
  [[ -e "$root/.claude/.last-audit-handoff.json" ]] && n=$((n+1))
  case "$n" in 0) printf 'no' ;; *) printf 'yes' ;; esac
}

# The gate does not manufacture the audit. It denies, names every route to an auditor,
# and whichever one the agent spawns writes the artifact — so this chain starts from an
# artifact a producer wrote, exactly as a real session would reach it.
KEEP_CMD="git commit -m 'test(hooks): codex keep audit'"

out="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$KEEP_CMD" | jq -Rs .)" \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
# With .githooks installed this layer defers rather than denying — the git-level gate
# is the single consumer. What matters here is that deferring manufactures NOTHING:
# the artifact only ever comes from an auditor the agent spawned.
check_eq "PreToolUse defers without manufacturing an audit" \
  "${out:-EMPTY}:$(audit_reachable "$R"):$(handoff_reachable "$R")" "EMPTY:no:yes"

# Stand in for the subagent the agent would spawn.
( cd "$R" && CLAUDE_PROJECT_DIR="$R" CODEX_BIN="$R/bin/codex" \
    bash "$R/.agents/hooks/run-commit-push-audit.sh" commit "$KEEP_CMD" ) >/dev/null 2>&1 || true

out="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$KEEP_CMD" | jq -Rs .)" \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" CODEX_SANDBOX=seatbelt CODEX_BIN="$R/bin/codex" bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
kept="$(audit_reachable "$R")"
handoff="$(handoff_reachable "$R")"
check_eq "PreToolUse defers and keeps the audit for .githooks" "${out:-EMPTY}:$kept:$handoff" "EMPTY:yes:yes"
out="$(printf '{"tool_input":{"command":"git commit"}}' \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" GITHOOK_DELEGATED=1 GITHOOK_KEEP_AUDIT=1 bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
kept_after_precommit="$(audit_reachable "$R")"
handoff_after_precommit="$(handoff_reachable "$R")"
check_eq "delegated pre-commit keeps Codex audit for commit-msg" "${out:-EMPTY}:$kept_after_precommit:$handoff_after_precommit" "EMPTY:yes:yes"
printf 'test(hooks): codex keep audit\n' > "$R/msg.txt"
( cd "$R" && CLAUDECODE=1 "$R/.githooks/commit-msg" "$R/msg.txt" >/dev/null 2>"$R/err.txt" )
commit_msg_rc=$?
[[ -e "$R/.agents/state/last-audit.json" ]] && consumed=no || consumed=yes
[[ -e "$R/.agents/state/last-audit-handoff.json" ]] && handoff_consumed=no || handoff_consumed=yes
check_eq "delegated commit-msg consumes Codex audit" "$commit_msg_rc:$consumed:$handoff_consumed" "0:yes:yes"
rm -rf "$R"

R="$(setup)"
# ...but the call coming FROM the git-level gate must still be judged.
out="$(printf '{"tool_input":{"command":"git commit -m x"}}' \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" GITHOOK_DELEGATED=1 bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && denied=yes || denied=no
check_eq "GITHOOK_DELEGATED call still judged (deny)"  "$denied" "yes"
rm -rf "$R"

# hooksPath configured but the delegate hook ABSENT (old ref, broken install):
# git silently skips missing hooks, so deferring here would stand BOTH layers
# down — the PreToolUse layer must gate itself (fail closed).
R="$(setup)"; rm "$R/.githooks/pre-commit"
out="$(printf '{"tool_input":{"command":"git commit -m x"}}' \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && denied=yes || denied=no
check_eq "hooksPath set, delegate missing → fail closed (deny)" "$denied" "yes"
rm -rf "$R"

# Without hooksPath, the PreToolUse layer gates as before (no regression).
R="$(setup)"; git -C "$R" config --worktree --unset core.hooksPath
out="$(printf '{"tool_input":{"command":"git commit -m x"}}' \
      | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$R/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && denied=yes || denied=no
check_eq "no hooksPath → PreToolUse still gates"       "$denied" "yes"
rm -rf "$R"

echo
echo "## delegated pre-commit names the command the agent actually ran"
# git hands pre-commit no argv, so the delegated payload is the placeholder
# `git commit`. The re-audit instruction must still name the real command — the
# one the PreToolUse layer saw — or the auditor binds sha256("git commit") with no
# subject and commit-msg rejects even a PASS.
deny_target_command() {  # deny-json -> target_command named in the Claude route
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | sed -n 's/^ *prompt=\(".*"\))$/\1/p' | head -1 | jq -r . \
    | sed -n '/^{"operation_kind"/p' | jq -r '.target_command'
}
deny_has_placeholder_note() {  # deny-json -> yes|no
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | grep -q 'target_command above is the placeholder' && printf 'yes' || printf 'no'
}
delegated_gate() {  # repo -> deny json (stdout) for the placeholder payload
  printf '{"tool_input":{"command":"git commit"}}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" GITHOOK_DELEGATED=1 GITHOOK_KEEP_AUDIT=1 \
        bash "$1/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null
}
pretooluse_gate() {  # repo command -> runs the PreToolUse layer (defers, writes handoff)
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$2" | jq -Rs .)" \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$1/.agents/hooks/preflight-commit-push.sh" ) >/dev/null 2>&1
}
REAL_CMD="git commit -m 'test(hooks): bind the real command'"

R="$(setup)"; stage_change "$R"
pretooluse_gate "$R" "$REAL_CMD"
check_eq "PreToolUse handoff records the commit command" \
  "$(jq -r '.command' "$R/.agents/state/last-audit-handoff.json")" "$REAL_CMD"
out="$(delegated_gate "$R")"
check_eq "delegated deny names the PreToolUse command, not the placeholder" \
  "$(deny_target_command "$out")" "$REAL_CMD"
check_eq "delegated deny carries no placeholder note when the command was recovered" \
  "$(deny_has_placeholder_note "$out")" "no"

# Same tool call, index staged AFTER the handoff (`git add && git commit`): the
# command is still recoverable — only the dossier is bound to the staged diff.
printf 'late\n' >> "$R/f"; git -C "$R" add -A
out="$(delegated_gate "$R")"
check_eq "command recovered even when staging happened after the handoff" \
  "$(deny_target_command "$out")" "$REAL_CMD"

# Full chain as a Claude session reaches it: the auditor audits the REAL command,
# the PreToolUse layer defers again on retry, pre-commit binds through the handoff
# hash, commit-msg verifies the audited subject and consumes both markers.
br="$(git -C "$R" branch --show-current)"; hd="$(git -C "$R" rev-parse HEAD)"
jq -nc --arg b "$br" --arg h "$hd" --arg dh "$(diff_hash_for "$R" commit)" \
  --arg ch "$(command_hash_for "$REAL_CMD")" \
  --arg csh "$(subject_hash_for 'test(hooks): bind the real command')" \
  '{branch:$b, head:$h, command_kind:"commit", diff_hash:$dh, command_hash:$ch, commit_subject_hash:$csh, verdict:"PASS", findings:[]}' \
  > "$R/.agents/state/last-audit.json"
pretooluse_gate "$R" "$REAL_CMD"
check_eq "agent + audit of the real command → commit allowed" \
  "$(run_commit "$R" agent 'test(hooks): bind the real command')" 0
[[ -e "$R/.agents/state/last-audit.json" || -e "$R/.agents/state/last-audit-handoff.json" ]] && consumed=no || consumed=yes
check_eq "real-command audit and handoff consumed" "$consumed" "yes"
rm -rf "$R"

# Closed over open: a handoff whose text does not hash to command_hash is ignored.
R="$(setup)"; stage_change "$R"
pretooluse_gate "$R" "$REAL_CMD"
jq '.command="git commit -m '"'"'feat: something else'"'"'"' "$R/.agents/state/last-audit-handoff.json" \
  > "$R/.agents/state/x.json" && mv "$R/.agents/state/x.json" "$R/.agents/state/last-audit-handoff.json"
out="$(delegated_gate "$R")"
check_eq "tampered handoff text falls back to the placeholder" \
  "$(deny_target_command "$out")" "git commit"
check_eq "placeholder fallback tells the agent to substitute the real command" \
  "$(deny_has_placeholder_note "$out")" "yes"
rm -rf "$R"

# No PreToolUse layer at all (AGENT_GATED agents): placeholder plus the note.
R="$(setup)"; stage_change "$R"
out="$(delegated_gate "$R")"
check_eq "no handoff → placeholder with substitution note" \
  "$(deny_target_command "$out"):$(deny_has_placeholder_note "$out")" "git commit:yes"
rm -rf "$R"

# The push handoff never carries a command: pre-push rebuilds its own exact one.
R="$(setup)"
printf '{"tool_input":{"command":"git push origin HEAD"}}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$R/.agents/hooks/preflight-commit-push.sh" ) >/dev/null 2>&1
check_eq "push handoff records no command text" \
  "$(jq -r '.command' "$R/.agents/state/last-audit-handoff.json")" "null"
rm -rf "$R"

echo
echo "## transition compat: hooks and trees on either side of the .agents move"
# Where core.hooksPath is configured absolute rather than the relative value
# `make setup` sets, ONE installed hook runs for every worktree whatever commit it
# sits on. Both directions must keep working,
# and neither may ever run unguarded.
COMPAT="$(mktemp -d)"
# Used by the resolve_* bodies eval'd below, which reference $compat_root.
# shellcheck disable=SC2034
compat_root="$COMPAT"
# The extracted function also checks the installed plugin before consumer-local
# compatibility paths. Point that location at an absent fixture so these cases
# continue to isolate the transition fallbacks.
# shellcheck disable=SC2034 # Referenced by the function body loaded through eval below.
tooling_root="$COMPAT/nonexistent-plugin"
# shellcheck disable=SC1090
eval "$(sed -n '/^resolve_gate() {/,/^}/p' "$REPO_ROOT/.githooks/pre-push" | sed 's|\$repo_root|\$compat_root|g')"
eval "$(sed -n '/^  resolve_marker() {/,/^  }/p' "$REPO_ROOT/.githooks/commit-msg" | sed 's/^  //; s|\$repo_root|\$compat_root|g')"

mkdir -p "$COMPAT/.claude/hooks"; : > "$COMPAT/.claude/hooks/preflight-commit-push.sh"
case "$(resolve_gate || echo NONE)" in *"/.claude/hooks/"*) r=legacy ;; *) r=other ;; esac
check_eq "gate resolves in a pre-move tree" "$r" "legacy"

mkdir -p "$COMPAT/.agents/hooks"; : > "$COMPAT/.agents/hooks/preflight-commit-push.sh"
case "$(resolve_gate || echo NONE)" in *"/.agents/hooks/"*) r=current ;; *) r=other ;; esac
check_eq "gate prefers .agents when both exist" "$r" "current"

rm -rf "$COMPAT/.claude/hooks" "$COMPAT/.agents/hooks"
check_eq "gate is unresolvable when absent from both (fails closed)" "$(resolve_gate || echo NONE)" "NONE"

mkdir -p "$COMPAT/.claude" "$COMPAT/.agents/state"
: > "$COMPAT/.claude/.last-audit.json"
case "$(resolve_marker last-audit.json)" in *"/.claude/.last-audit.json") r=legacy ;; *) r=other ;; esac
check_eq "marker resolves in a pre-move tree" "$r" "legacy"

: > "$COMPAT/.agents/state/last-audit.json"
case "$(resolve_marker last-audit.json)" in *"/.agents/state/last-audit.json") r=current ;; *) r=other ;; esac
check_eq "marker prefers .agents/state when both exist" "$r" "current"

# BEHAVIOUR, not a grep for the helper's name: a name-presence check survives
# deleting every call site. Drive the gate on the KEEP path (what a delegated
# git hook takes) with an audit at the new location only, then look at where the
# marker actually ended up.
M="$(setup)"
write_audit "$M" commit
( cd "$M" && printf '%s' 'git commit -m x' | jq -Rs '{tool_input:{command:.}}' \
  | CLAUDE_PROJECT_DIR="$M" CLAUDECODE=1 GITHOOK_DELEGATED=1 GITHOOK_KEEP_AUDIT=1 \
    bash "$M/.agents/hooks/preflight-commit-push.sh" >/dev/null 2>&1 )
[[ -r "$M/.claude/.last-audit.json" ]] && r=yes || r=no
check_eq "kept audit reaches the legacy path a pre-move commit-msg reads" "$r" "yes"
# The new location must survive too: more than one stage takes the keep path,
# and handing the marker over would leave the second with nothing.
[[ -r "$M/.agents/state/last-audit.json" ]] && r=yes || r=no
check_eq "kept audit also stays where a later keep-stage looks" "$r" "yes"
rm -rf "$M"

# Every legacy marker location, not just the two the gate mirrors: a checkout
# from before the move still writes the other four, and an unignored marker
# perturbs the tree hash the verdict dossier is keyed to.
for legacy in .claude/.last-audit.json .claude/.last-audit-handoff.json \
              .claude/.last-verdict.json .claude/.pr-reviewed.json \
              .claude/.verdict-last-uuid .claude/.verdict-decisions.log; do
  git -C "$REPO_ROOT" check-ignore -q "$legacy" && r=yes || r=no
  check_eq "legacy mirror $legacy stays gitignored (tree hash must not move)" "$r" "yes"
done
rm -rf "$COMPAT"

echo
echo "## installer: plugin setup points git at the shared hook layer"

install_probe() {  # dir -> the configured value, or empty
  local dir="$1"
  [ -n "$dir" ] || { printf 'install_probe: empty target refused\n' >&2; return 1; }
  "$REPO_ROOT/scripts/setup.sh" "$dir" >/dev/null 2>&1
  git -C "$dir" config --worktree --get core.hooksPath
}

INST="$(mktemp -d)"
# Assert the fixture before anything can use it, because an empty INST is not
# inert: `git -C ""` is a NO-OP -C, not an error, so every git call below silently
# targets the shell's cwd — the developer's clone. Measured consequences of that,
# not hypothesised: local user.name/user.email written into the shared .git/config,
# a real commit landed on their current branch, and core.hooksPath unset, all while
# the suite printed green. The PROJECT_ROOT="" -> $SCRIPT_DIR/.. fallback inside the
# installer is a second route to the same clone.
# At the fixture, not at each call site: the git calls immediately below run before
# any installer call, and two cases invoke the installer directly.
case "$INST" in
  /tmp/*|/private/var/folders/*|/var/folders/*) ;;
  *) printf 'installer fixture refused: INST=[%s]\n' "$INST" >&2; exit 1 ;;
esac
git -C "$INST" init -q
git -C "$INST" config user.email t@t.test
git -C "$INST" config user.name tester
mkdir -p "$INST/.githooks" "$INST/.agent-tooling" "$INST/.agents/plugins" \
  "$INST/.claude" "$INST/.github/copilot"
jq -n '{
  schemaVersion: 1,
  profile: "boxlite",
  repository: "boxlite-ai/boxlite",
  tooling: {repository: "boxlite-ai/agent-tooling", ref: "main"},
  checks: [{name: "test", command: "make test"}]
}' > "$INST/.agent-tooling/profile.json"
jq -n '{
  extraKnownMarketplaces: {
    "boxlite-agent-tooling": {
      source: {source: "github", repo: "boxlite-ai/agent-tooling", ref: "main"}
    }
  },
  enabledPlugins: {"boxlite-agent-tooling@boxlite-agent-tooling": true}
}' > "$INST/.claude/settings.json"
cp "$INST/.claude/settings.json" "$INST/.github/copilot/settings.json"
jq -n '{
  name: "fixture",
  interface: {displayName: "Fixture"},
  plugins: [{
    name: "boxlite-agent-tooling",
    source: {
      source: "git-subdir",
      url: "https://github.com/boxlite-ai/agent-tooling.git",
      path: "./plugins/boxlite-agent-tooling",
      ref: "main"
    },
    policy: {installation: "INSTALLED_BY_DEFAULT", authentication: "ON_INSTALL"},
    category: "Developer Tools"
  }]
}' > "$INST/.agents/plugins/marketplace.json"
printf '%s\n' \
  '.agents/state/' \
  '.claude/.last-audit.json' \
  '.claude/.last-audit-handoff.json' \
  '.claude/.last-verdict.json' \
  '.claude/.pr-reviewed.json' \
  '.claude/.verdict-last-uuid' \
  '.claude/.verdict-decisions.log' > "$INST/.gitignore"
git -C "$INST" add -A
git -C "$INST" commit -qm base

# The plugin cache is outside the consumer checkout, so the installed path is
# deliberately absolute and points at this immutable plugin version.
EXPECTED_HOOKS="$REPO_ROOT/.githooks"
check_eq "setup points core.hooksPath at the installed plugin" \
  "$(install_probe "$INST")" "$EXPECTED_HOOKS"

# A linked worktree's .git is a FILE, not a directory. Testing for a directory
# named .git skipped installation in every worktree; ask git instead.
git -C "$INST" worktree add -q "$INST-wt" -b installer-wt
mkdir -p "$INST-wt/.githooks"
git -C "$INST-wt" config --worktree --unset core.hooksPath
wt_dot_git="dir"; [ -f "$INST-wt/.git" ] && wt_dot_git="file"
check_eq "a linked worktree's .git is a file (the case the guard must survive)" \
  "$wt_dot_git" "file"
check_eq "setup installs from inside a linked worktree" \
  "$(install_probe "$INST-wt")" "$EXPECTED_HOOKS"

git -C "$INST" config --worktree --unset core.hooksPath
check_eq "a second setup run is idempotent" \
  "$(install_probe "$INST")" "$EXPECTED_HOOKS"

# Identity is checked against the remote git actually has, not against a roster
# shipped in this repo — a public plugin cannot carry a list of private repository
# names. So the case that must fail closed is a manifest claiming to be a repository
# this checkout is not.
cp "$INST/.agent-tooling/profile.json" "$INST/.agent-tooling/profile.valid.json"
git -C "$INST" remote add origin "https://github.com/boxlite-ai/some-repo.git"
jq '.repository="boxlite-ai/a-different-repo"' "$INST/.agent-tooling/profile.valid.json" \
  > "$INST/.agent-tooling/profile.json"
if "$REPO_ROOT/scripts/setup.sh" "$INST" >/dev/null 2>"$INST/setup.err"; then
  invalid_result=allowed
else
  invalid_result=blocked
fi
check_eq "a repository that is not this checkout fails closed" "$invalid_result" "blocked"
grep -q 'origin does not match declared repository' "$INST/setup.err" && invalid_message=clear || invalid_message=missing
check_eq "an invalid profile names the error" "$invalid_message" "clear"
git -C "$INST" remote remove origin

git -C "$INST" worktree remove --force "$INST-wt"
rm -rf "$INST"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
