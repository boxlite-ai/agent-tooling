#!/usr/bin/env bash
# Tests for .agents/watch/pr-watch.sh and the arm point in .githooks/pre-push.
#
# Runs against a scratch repo with a stubbed `gh` on PATH — no network, and no
# chained framework hook to trigger.
#
# Covers:
#   1. Event emission: one per concluded check, every terminal bucket, dedup.
#   2. Confirmed merge-conflict emission, revision-scoped dedup, UNKNOWN handling.
#   3. The empty-field regression: a check with no `workflow` must not shift
#      `link` into the workflow column.
#   4. Single-instance lock.
#   5. pre-push arming: branch refs armed, deletions/tags skipped, opt-out.
#
# Run with:  bash .agents/watch/pr-watch.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# The watcher's opt-out, same as post-remote-write-watch.test.sh. Inherited it
# disarms every arm case and takes this suite to 18/22; the case that covers the
# opt-out sets it per-invocation.
unset BOXLITE_PR_WATCH

# Resolve from THIS script's location, not the caller's cwd. Same reasoning as
# .agents/hooks/post-remote-write-watch.test.sh: cwd-derived paths make a
# two-side check silently exercise a different checkout's copy and report a pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCHER="$REPO_ROOT/.agents/watch/pr-watch.sh"
PREPUSH="$REPO_ROOT/.githooks/pre-push"
# shellcheck source=../lib/pr-watch-state.sh
source "$REPO_ROOT/.agents/lib/pr-watch-state.sh"
# shellcheck source=../lib/verdict-audit-state.sh
source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
PR42_KEY="$(pr_watch_branch_key pr-42)"
TMP="$(mktemp -d)"
# Match ONLY this suite's scratch watcher — the pinned install's copy, the one
# file both the direct launches and the pre-push arm run. A bare
# "pr-watch.sh --branch" pattern also matches a real watcher following a real PR
# on this machine, so running the tests would silently kill it. Set once the
# pinned install exists; the trap reads it lazily. The fallback matters: this
# trap is armed before SCRATCH_WATCHER is assigned, and an empty pattern is
# never the cleanup being asked for. On this host (BSD pkill) it errors with
# "empty (sub)expression"; do not rely on that being the failure mode everywhere.
watcher_pat() { printf '%s' "${SCRATCH_WATCHER:-__pr_watch_no_scratch__}"; }
trap 'pkill -f "$(watcher_pat)" 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

check() {
  local desc="$1" actual="$2" expect="$3"
  if [[ "$actual" == "$expect" ]]; then ok "$desc"; else no "$desc" "got=[$actual] want=[$expect]"; fi
}

# ── scratch repo + gh stub ───────────────────────────────────────────────────

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
# A local bare remote, not a github URL: the watcher's first act is an ls-remote
# wait, and this keeps that offline and instant instead of dialing out.
git init -q --bare "$TMP/origin.git"
git -C "$REPO" remote add origin "$TMP/origin.git"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# pre-push refuses to run in an uninstalled consumer (scripts/verify-installation.sh)
# and resolves BOTH the verifier and the watcher against its own tooling root. So
# the suite builds the same pinned-cache installation githooks.test.sh setup()
# builds, and drives THAT copy of the hook. Invoking $REPO_ROOT/.githooks/pre-push
# directly can never pass verification — the configured hooks path must sit inside
# .git/agent-tooling/<pinned sha>/, and the working checkout does not — which is
# exactly the 3-failure state this suite sat in after the verifier landed.
scratch="$TMP/tooling-src"
plugin_rel="plugins/boxlite-agent-tooling"
mkdir -p "$scratch/$plugin_rel/.agents"
cp -R "$REPO_ROOT/.githooks" "$REPO_ROOT/scripts" "$REPO_ROOT/guidance" \
  "$scratch/$plugin_rel/"
cp -R "$REPO_ROOT/.agents/watch" "$scratch/$plugin_rel/.agents/watch"
mkdir -p "$scratch/$plugin_rel/.agents/lib"
cp "$REPO_ROOT/.agents/lib/pr-watch-state.sh" \
   "$REPO_ROOT/.agents/lib/pr-watch-pending.sh" \
   "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" "$scratch/$plugin_rel/.agents/lib/"
mkdir -p "$scratch/$plugin_rel/.agents/hooks"
cat > "$scratch/$plugin_rel/.agents/hooks/preflight-commit-push.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
jq -nc '{hookSpecificOutput:{permissionDecision:"allow",additionalContext:"fixture audit passed"}}'
EOF
chmod +x "$scratch/$plugin_rel/.agents/hooks/preflight-commit-push.sh"
git -C "$scratch" init -q
git -C "$scratch" -c user.email=t@t -c user.name=t add -A
git -C "$scratch" -c user.email=t@t -c user.name=t commit -qm tooling
PIN_SHA="$(git -C "$scratch" rev-parse HEAD)"
mkdir -p "$REPO/.git/agent-tooling"
mv "$scratch" "$REPO/.git/agent-tooling/$PIN_SHA"
PIN="$REPO/.git/agent-tooling/$PIN_SHA/$plugin_rel"
mkdir -p "$REPO/.agent-tooling"
printf '{"tooling":{"repository":"boxlite-ai/agent-tooling","ref":"main"}}\n' > "$REPO/.agent-tooling/profile.json"
printf '%s\n' "$PIN_SHA" > "$REPO/.git/agent-tooling/current"
"$PIN/scripts/sync-guidance.sh" "$REPO" >/dev/null
git -C "$REPO" config extensions.worktreeConfig true
git -C "$REPO" config --worktree core.hooksPath "$PIN/.githooks"
# From here on, the hook under test IS the pinned copy — and so is the watcher it
# arms, which is why the scratch watcher lives in the pin rather than beside $REPO.
PREPUSH="$PIN/.githooks/pre-push"
SCRATCH_WATCHER="$PIN/.agents/watch/pr-watch.sh"

STUB="$TMP/bin"
mkdir -p "$STUB"

# Fixture knobs the stub reads at call time, so a test can change CI state
# without rewriting the stub.
export FIXTURE_DIR="$TMP/fixtures"
mkdir -p "$FIXTURE_DIR"

cat > "$STUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
if [[ -n "${GH_GENERATION_MARKER:-}" ]]; then
  should_delay=1
  mkdir "${GH_GENERATION_MARKER}.once" 2>/dev/null || should_delay=0
  if (( should_delay )); then
    printf '%s\n' "$$" > "${GH_GENERATION_MARKER}.pid"
    trap ': > "${GH_GENERATION_MARKER}.term"; exit 143' TERM
    : > "${GH_GENERATION_MARKER}.ready"
    IFS= read -r generation_event < "${GH_GENERATION_MARKER}.release" \
      || exit 125
    [[ "$generation_event" == changed ]] || exit 125
    : > "${GH_GENERATION_MARKER}.completed"
  fi
fi
if [[ -n "${GH_FLOOD_MARKER:-}" ]]; then
  should_flood=1
  if [[ "${GH_FLOOD_MODE:-always}" == "once" ]]; then
    mkdir "${GH_FLOOD_MARKER}.once" 2>/dev/null || should_flood=0
  fi
  if (( should_flood )); then
    printf '%s\n' "$$" > "${GH_FLOOD_MARKER}.pid"
    trap '' TERM
    (
      trap '' TERM
      exec perl -e '
        use strict;
        use warnings;
        my ($marker, $remaining) = ($ENV{GH_FLOOD_MARKER}, 9 * 1024 * 1024);
        $SIG{TERM} = "IGNORE";
        $SIG{XFSZ} = "IGNORE";
        my $chunk = "x" x 65536;
        while ($remaining > 0) {
          my $wanted = $remaining < length($chunk) ? $remaining : length($chunk);
          my $written = syswrite(STDOUT, $chunk, $wanted);
          if (!defined($written)) {
            select undef, undef, undef, 0.01;
            next;
          }
          $remaining -= $written;
        }
        open(my $done, ">", $marker . ".completed") or die $!;
        close($done) or die $!;
        while (1) { select undef, undef, undef, 1; }
      '
    ) & descendant_pid=$!
    printf '%s\n' "$descendant_pid" > "${GH_FLOOD_MARKER}.descendant.pid"
    : > "${GH_FLOOD_MARKER}.ready"
    wait "$descendant_pid"
  fi
fi
if [[ -n "${GH_STUCK_MARKER:-}" ]]; then
  should_stick=1
  if [[ "${GH_STUCK_MODE:-always}" == "once" ]]; then
    mkdir "${GH_STUCK_MARKER}.once" 2>/dev/null || should_stick=0
  fi
  if (( should_stick )); then
    printf '%s\n' "$$" > "${GH_STUCK_MARKER}.pid"
    trap '' TERM
    (
      trap '' TERM
      while :; do sleep 1; done
    ) & descendant_pid=$!
    printf '%s\n' "$descendant_pid" > "${GH_STUCK_MARKER}.descendant.pid"
    : > "${GH_STUCK_MARKER}.ready"
    wait "$descendant_pid"
  fi
fi
if [[ -n "${GH_DELAY_SECONDS:-}" ]]; then
  sleep "$GH_DELAY_SECONDS"
fi
printf '%s\n' "$*" >> "$FIXTURE_DIR/gh-calls.log"
case "$1 $2" in
  "pr checks")  cat "$FIXTURE_DIR/checks.json" ;;
  "pr view")    cat "$FIXTURE_DIR/view.json" ;;
  "pr list")    cat "$FIXTURE_DIR/prnumber.txt" 2>/dev/null || true ;;
  "api "*|"api")
                cat "$FIXTURE_DIR/inline.json" ;;
  *) exit 1 ;;
esac
STUB_EOF
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"

write_fixtures() {
  : > "$FIXTURE_DIR/gh-calls.log"
  cat > "$FIXTURE_DIR/checks.json" <<'EOF'
[
  {"name":"CodeQL","state":"SUCCESS","bucket":"pass","workflow":"","link":"https://gh/runs/1"},
  {"name":"Lint (conclusion)","state":"SUCCESS","bucket":"pass","workflow":"Lint and Format","link":"https://gh/runs/2"},
  {"name":"Test (conclusion)","state":"FAILURE","bucket":"fail","workflow":"Test","link":"https://gh/runs/3"},
  {"name":"Rust Tests","state":"SKIPPED","bucket":"skipping","workflow":"Test","link":"https://gh/runs/4"},
  {"name":"E2E local","state":"IN_PROGRESS","bucket":"pending","workflow":"E2E local","link":"https://gh/runs/5"}
]
EOF
  cat > "$FIXTURE_DIR/view.json" <<'EOF'
{"state":"OPEN","mergeable":"MERGEABLE","headRefOid":"head-1","baseRefOid":"base-1",
 "comments":[{"id":"C1","author":{"login":"boxlite-agent"},"body":"line one\nline two","url":"https://gh/c/1"}],
 "reviews":[{"id":"R1","author":{"login":"coderabbitai"},"state":"COMMENTED","body":"nit"}]}
EOF
  cat > "$FIXTURE_DIR/inline.json" <<'EOF'
[{"id":"I1","user":{"login":"coderabbitai"},"path":"src/main.rs","body":"inline note","html_url":"https://gh/i/1"}]
EOF
  printf '42\n' > "$FIXTURE_DIR/prnumber.txt"
}
write_fixtures

run_watch() { (cd "$REPO" && bash "$WATCHER" "$@" 2>&1); }

# Every blocking call below waits on the code under test deciding to exit. If
# that decision regresses the suite would hang and CI would report a timeout
# instead of a named failing assertion, so bound them and let the assertion fail.
# macOS ships no coreutils `timeout`; a watchdog subshell is portable.
with_deadline() {
  local secs="$1"; shift
  ( "$@" ) & local job=$!
  # The watchdog MUST NOT inherit stdout. It is a background child of the same
  # command substitution, so while it holds the write end open `$(…)` cannot
  # return — every call would block for the full deadline even when the job
  # finished immediately.
  ( sleep "$secs"; kill -TERM "$job" 2>/dev/null ) >/dev/null 2>&1 & local dog=$!
  # Report the JOB's status. Returning the watchdog's would mask every exit code
  # with the 143 from killing it, so an exit-code assertion could never pass.
  local rc=0
  wait "$job" 2>/dev/null || rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null || true
  return "$rc"
}
events_of() { grep "\"kind\":\"$1\"" <<<"$2" 2>/dev/null; }
reset_state() { rm -rf "$REPO/.git/pr-watch"; }

# ── 1. event emission ────────────────────────────────────────────────────────

echo "## Event emission"
reset_state
OUT="$(run_watch --pr 42 --once)"

check "every line is valid JSON" \
  "$(jq -e . <<<"$OUT" >/dev/null 2>&1 && echo yes || echo no)" "yes"

check "emits 4 concluded checks, not the pending one" \
  "$(events_of check "$OUT" | wc -l | tr -d ' ')" "4"

check "emits the FAILING check (silence != success)" \
  "$(events_of check "$OUT" | jq -r 'select(.bucket=="fail") | .name')" "Test (conclusion)"

check "emits the skipped check too" \
  "$(events_of check "$OUT" | jq -r 'select(.bucket=="skipping") | .name')" "Rust Tests"

check "no checks_done while one check is still pending" \
  "$(events_of checks_done "$OUT" | wc -l | tr -d ' ')" "0"

check "emits the issue comment" \
  "$(events_of comment "$OUT" | jq -r '.author')" "boxlite-agent"

check "emits the review" \
  "$(events_of review "$OUT" | jq -r '.author + ":" + .state')" "coderabbitai:COMMENTED"

check "emits the inline review comment with its path" \
  "$(events_of review_comment "$OUT" | jq -r '.path')" "src/main.rs"
check "the PR view requests mergeability and both compared revisions" \
  "$(grep 'pr view' "$FIXTURE_DIR/gh-calls.log" \
      | grep -Fq -- '--json state,comments,reviews,mergeable,headRefOid,baseRefOid' \
      && echo yes || echo no)" "yes"

# ── 2. merge conflicts ───────────────────────────────────────────────────────

echo
echo "## Merge conflicts"
check "a mergeable PR emits no conflict event" \
  "$(events_of conflict "$OUT" | wc -l | tr -d ' ')" "0"

jq '.mergeable = "UNKNOWN"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
check "UNKNOWN mergeability is not misreported as a conflict" \
  "$(events_of conflict "$(run_watch --pr 42 --once)" | wc -l | tr -d ' ')" "0"

jq '.mergeable = "CONFLICTING"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
CONFLICT="$(run_watch --pr 42 --once)"
check "a confirmed merge conflict emits an event" \
  "$(events_of conflict "$CONFLICT" | wc -l | tr -d ' ')" "1"
check "the conflict event identifies both compared revisions" \
  "$(events_of conflict "$CONFLICT" | jq -r '.head_sha + "/" + .base_sha')" "head-1/base-1"
check "the same conflict is not repeated on every poll" \
  "$(events_of conflict "$(run_watch --pr 42 --once)" | wc -l | tr -d ' ')" "0"

jq '.headRefOid = "head-2"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
check "a conflict against a new revision is reported again" \
  "$(events_of conflict "$(run_watch --pr 42 --once)" | jq -r '.head_sha')" "head-2"

jq '.baseRefOid = "base-2"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
check "base movement independently makes the conflict new" \
  "$(events_of conflict "$(run_watch --pr 42 --once)" | jq -r '.base_sha')" "base-2"

jq 'del(.mergeable) | .headRefOid = "head-3"' \
  "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
check "missing mergeability is not misreported as a conflict" \
  "$(events_of conflict "$(run_watch --pr 42 --once)" | wc -l | tr -d ' ')" "0"
write_fixtures

# ── 3. the empty-field regression ────────────────────────────────────────────
#
# `IFS=$'\t' read` collapses runs of tabs, so a check with an empty `workflow`
# used to shift `link` one column left — CodeQL reported its URL as its workflow
# name and an empty url. Guard both columns.

echo
echo "## Regression: empty field must not shift columns"
CODEQL="$(events_of check "$OUT" | jq -c 'select(.name=="CodeQL")')"
check "empty workflow stays empty" \
  "$(jq -r '.workflow' <<<"$CODEQL")" ""
check "link lands in url, not workflow" \
  "$(jq -r '.url' <<<"$CODEQL")" "https://gh/runs/1"
check "populated workflow still lands correctly" \
  "$(events_of check "$OUT" | jq -r 'select(.name=="Lint (conclusion)") | .workflow')" "Lint and Format"

# ── 4. body handling ─────────────────────────────────────────────────────────

echo
echo "## Body handling"
check "multi-line comment body survives as one JSON line with real newlines" \
  "$(events_of comment "$OUT" | jq -r '.body' | wc -l | tr -d ' ')" "2"

# Backslashes, tabs and quotes must all survive verbatim. @tsv escaped only the
# first two — quotes pass through it untouched — and the hand-written decoder
# then corrupted a backslash followed by t, r or n, hence `C:\temp` and `C:\new`
# in the fixture. Escaped, `C:\temp` is `C:\\temp`, and a left-to-right pass
# reads the second backslash plus `t` as a tab. A backslash before any other
# letter (`C:\dir`, `a\b`, `\d+`) round-tripped fine, so a fixture without
# t/r/n would have passed against the buggy decoder. The quote still earns its
# place: it crosses the raw-separator to JSON re-encode boundary.
reset_state
jq '.comments[0].body = "win C:\\temp and C:\\new plus a \"quote\" and\ttab"' \
  "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/v.tmp" && mv "$FIXTURE_DIR/v.tmp" "$FIXTURE_DIR/view.json"
OUTB="$(run_watch --pr 42 --once)"
check "backslashes survive verbatim (no escape-decoding corruption)" \
  "$(events_of comment "$OUTB" | jq -r '.body')" \
  "$(printf 'win C:\\temp and C:\\new plus a "quote" and\ttab')"
write_fixtures

# ── 5. dedup + lock ──────────────────────────────────────────────────────────

echo
echo "## Dedup and locking"
OUT2="$(run_watch --pr 42 --once)"
check "second pass re-emits nothing" \
  "$(events_of check "$OUT2" | wc -l | tr -d ' ')" "0"

# A new check appearing is still emitted after the dedup pass.
jq '. + [{"name":"New Job","state":"SUCCESS","bucket":"pass","workflow":"Test","link":"https://gh/runs/9"}]' \
  "$FIXTURE_DIR/checks.json" > "$FIXTURE_DIR/checks.tmp" && mv "$FIXTURE_DIR/checks.tmp" "$FIXTURE_DIR/checks.json"
OUT3="$(run_watch --pr 42 --once)"
check "a newly-concluded check IS emitted after dedup" \
  "$(events_of check "$OUT3" | jq -r '.name')" "New Job"

# A lock owned by a LIVE process must be obeyed. $$ is this suite, definitely alive.
mkdir -p "$REPO/.git/pr-watch/$PR42_KEY.lock"
LIVE_LOCK_TOKEN="$(verdict_audit_process_start_token "$$")"
jq -nc --argjson pid "$$" --arg token "$LIVE_LOCK_TOKEN" \
  '{schema:1,pid:$pid,start_token:$token,watch_id:"watch-eeeeeeeeeeeeeeeeeeeeeeee",ready:true}' \
  > "$REPO/.git/pr-watch/$PR42_KEY.lock/owner.json"
OUT4="$(run_watch --pr 42 --once)"
check "lock held by a LIVE owner makes a second instance exit silently" \
  "$(printf '%s' "$OUT4" | wc -c | tr -d ' ')" "0"

# SIGKILL/OOM/reboot leaves a lock no trap could clear. Obeying it forever would
# silently suppress every future watcher for the branch.
#
# Earn a provably-dead PID instead of hardcoding a "big" one: PID ranges are
# platform-specific (macOS tops out at 99999, Linux pid_max is often 4194304),
# so no literal is portably unusable. Spawn, reap, then assert it is gone.
( exit 0 ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null
kill -0 "$dead_pid" 2>/dev/null && no "fixture: PID $dead_pid still alive" "cannot test stale lock"
jq -nc --argjson pid "$dead_pid" \
  '{schema:1,pid:$pid,start_token:"cksum-1-1",watch_id:"watch-ffffffffffffffffffffffff",ready:true}' \
  > "$REPO/.git/pr-watch/$PR42_KEY.lock/owner.json"
OUT4b="$(run_watch --pr 42 --once)"
check "STALE lock (dead owner) is reclaimed, not obeyed" \
  "$(events_of watch_start "$OUT4b" | jq -r '.pr')" "42"

# A lock dir with no pid file at all — e.g. written by an older version.
rm -rf "$REPO/.git/pr-watch/$PR42_KEY.lock"; mkdir -p "$REPO/.git/pr-watch/$PR42_KEY.lock"
OUT4c="$(run_watch --pr 42 --once)"
check "lock with no owner recorded is reclaimed" \
  "$(events_of watch_start "$OUT4c" | jq -r '.pr')" "42"
rm -rf "$REPO/.git/pr-watch/$PR42_KEY.lock"

# Hostile or crash-left lock metadata must never choose blocking I/O. The FIFO
# is opened read/write later only to release the unfixed raw `cat` path after the
# deadline, keeping the regression itself bounded.
mkdir -p "$REPO/.git/pr-watch/$PR42_KEY.lock"
mkfifo "$REPO/.git/pr-watch/$PR42_KEY.lock/pid"
(
  sleep 5
  perl -MFcntl=:DEFAULT -e '
    sysopen(my $fh, $ARGV[0], O_RDWR | O_NONBLOCK) or exit 0;
    syswrite($fh, "1\n");
  ' "$REPO/.git/pr-watch/$PR42_KEY.lock/pid"
) & LOCK_FIFO_WRITER=$!
LOCK_FIFO_OUT="$(with_deadline 3 run_watch --pr 42 --once)"
LOCK_FIFO_RC=$?
wait "$LOCK_FIFO_WRITER" 2>/dev/null || true
check "FIFO lock metadata is rejected without blocking" \
  "$(events_of watch_start "$LOCK_FIFO_OUT" | jq -r '.pr')/$LOCK_FIFO_RC" "42/0"

# A live numeric PID is not an owner identity after PID reuse. A mismatched
# process-start token makes this stale even though kill -0 succeeds.
rm -rf "$REPO/.git/pr-watch/$PR42_KEY.lock"
mkdir -p "$REPO/.git/pr-watch/$PR42_KEY.lock"
printf '%s\n' "$$" > "$REPO/.git/pr-watch/$PR42_KEY.lock/pid"
jq -nc --argjson pid "$$" \
  '{schema:1,pid:$pid,start_token:"cksum-1-1",watch_id:"watch-dddddddddddddddddddddddd",ready:true}' \
  > "$REPO/.git/pr-watch/$PR42_KEY.lock/owner.json"
LOCK_REUSED_PID_OUT="$(run_watch --pr 42 --once)"
check "live PID with a mismatched start token is reclaimed as stale" \
  "$(events_of watch_start "$LOCK_REUSED_PID_OUT" | jq -r '.pr')" "42"

# Cleanup owns the exact directory it acquired. Replacing the stable name with
# a newer lock before the old process exits must not let the old EXIT trap erase
# the newer owner.
reset_state
CLEANUP_BRANCH="cleanup-owner"
CLEANUP_KEY="$(pr_watch_branch_key "$CLEANUP_BRANCH")"
CLEANUP_LOCK="$REPO/.git/pr-watch/$CLEANUP_KEY.lock"
(cd "$REPO" && PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 \
  PR_WATCH_MAX_LIFETIME=60 bash "$WATCHER" --branch "$CLEANUP_BRANCH" --pr 42 \
  > "$TMP/cleanup-owner.out" 2>&1) & CLEANUP_PID=$!
CLEANUP_DEADLINE=$(( SECONDS + 10 ))
while (( SECONDS < CLEANUP_DEADLINE )); do
  [[ -d "$CLEANUP_LOCK" ]] && break
  sleep 1
done
mv "$CLEANUP_LOCK" "$CLEANUP_LOCK.old"
mkdir "$CLEANUP_LOCK"
printf 'new-owner\n' > "$CLEANUP_LOCK/sentinel"
kill -TERM "$CLEANUP_PID" 2>/dev/null || true
wait "$CLEANUP_PID" 2>/dev/null || true
check "old watcher cleanup preserves a replacement lock owner" \
  "$([[ -f "$CLEANUP_LOCK/sentinel" ]] && echo preserved || echo deleted)" "preserved"
reset_state

# Stale-lock retirement must not recursively delete any pathname after an
# identity check. Pause at the exact owner-record rewrite helper, replace the
# checked directory name, and prove the rewrite remains pinned to the original
# directory inode while the replacement survives untouched.
LOCK_RETIRE_BRANCH="lock-retire-race"
LOCK_RETIRE_KEY="$(pr_watch_branch_key "$LOCK_RETIRE_BRANCH")"
LOCK_RETIRE_STABLE="$REPO/.git/pr-watch/${LOCK_RETIRE_KEY}.lock"
LOCK_RETIRE_ENV="$TMP/lock-retire-env.sh"
reset_state
mkdir -p "$LOCK_RETIRE_STABLE"
mkdir -p "$TMP/lock-retire"
cat > "$LOCK_RETIRE_ENV" <<'LOCK_RETIRE_ENV_EOF'
if [[ -z "${PR_WATCH_LOCK_RETIRE_OWNER_PID:-}" ]]; then
  export PR_WATCH_LOCK_RETIRE_OWNER_PID="$$"
  pr_watch_lock_retire_debug() {
    [[ "$$" == "$PR_WATCH_LOCK_RETIRE_OWNER_PID" ]] || return 0
    [[ "$BASH_COMMAND" == rewrite_lock_owner_exact\ stale* ]] || return 0
    trap - DEBUG
    printf '%s\n' "$lock_dir" > "$PR_WATCH_LOCK_RETIRE_ROOT/selected-path"
    : > "$PR_WATCH_LOCK_RETIRE_ROOT/ready"
    while [[ ! -e "$PR_WATCH_LOCK_RETIRE_ROOT/release" ]]; do
      sleep 0.01
    done
  }
  set -T
  trap pr_watch_lock_retire_debug DEBUG
fi
LOCK_RETIRE_ENV_EOF
(
  cd "$REPO" || exit 1
  exec env BASH_ENV="$LOCK_RETIRE_ENV" PR_WATCH_LOCK_RETIRE_ROOT="$TMP/lock-retire" \
    bash "$WATCHER" --branch "$LOCK_RETIRE_BRANCH" --pr 42 --once
) > "$TMP/lock-retire.out" 2> "$TMP/lock-retire.err" & LOCK_RETIRE_JOB=$!
LOCK_RETIRE_DEADLINE=$(( SECONDS + 8 ))
while (( SECONDS < LOCK_RETIRE_DEADLINE )); do
  [[ -s "$TMP/lock-retire/selected-path" && -e "$TMP/lock-retire/ready" ]] && break
  kill -0 "$LOCK_RETIRE_JOB" 2>/dev/null || break
  sleep 0.02
done
LOCK_RETIRE_SELECTED="$(cat "$TMP/lock-retire/selected-path" 2>/dev/null || true)"
LOCK_RETIRE_BARRIER=missed
if [[ -n "$LOCK_RETIRE_SELECTED" && -d "$LOCK_RETIRE_SELECTED" ]]; then
  LOCK_RETIRE_BARRIER=hit
  mv "$LOCK_RETIRE_SELECTED" "$LOCK_RETIRE_SELECTED.original"
  mkdir "$LOCK_RETIRE_SELECTED"
  printf 'replacement\n' > "$LOCK_RETIRE_SELECTED/sentinel"
fi
touch "$TMP/lock-retire/release"
( sleep 5; kill -KILL "$LOCK_RETIRE_JOB" 2>/dev/null || true ) & LOCK_RETIRE_WATCHDOG=$!
wait "$LOCK_RETIRE_JOB" 2>/dev/null; LOCK_RETIRE_RC=$?
kill "$LOCK_RETIRE_WATCHDOG" 2>/dev/null || true
wait "$LOCK_RETIRE_WATCHDOG" 2>/dev/null || true
LOCK_RETIRE_REPLACEMENT=gone
[[ -n "$LOCK_RETIRE_SELECTED" && -f "$LOCK_RETIRE_SELECTED/sentinel" ]] \
  && LOCK_RETIRE_REPLACEMENT=preserved
check "lock retirement preserves a post-validation pathname replacement" \
  "barrier=$LOCK_RETIRE_BARRIER rc=$LOCK_RETIRE_RC replacement=$LOCK_RETIRE_REPLACEMENT" \
  "barrier=hit rc=0 replacement=preserved"
reset_state

# Every process invocation is a distinct delivery generation even when it
# watches the same branch and reuses branch-level de-dup state. Consumers need
# this discriminator so an old terminal record cannot end a new watch.
echo
echo "## Watch generations and branch identity"
reset_state
GEN1="$(run_watch --pr 42 --once)"
GEN2="$(run_watch --pr 42 --once)"
GEN1_ID="$(events_of watch_start "$GEN1" | jq -r '.watch_id // empty')"
GEN2_ID="$(events_of watch_start "$GEN2" | jq -r '.watch_id // empty')"
check "first generation has a watch_id" "$([[ -n "$GEN1_ID" ]] && echo yes || echo no)" "yes"
check "same branch gets a fresh watch_id on the next generation" \
  "$([[ -n "$GEN1_ID" && -n "$GEN2_ID" && "$GEN1_ID" != "$GEN2_ID" ]] && echo yes || echo no)" "yes"
GEN1_TAGGED="$(jq -s --arg id "$GEN1_ID" 'length > 0 and all(.[]; .watch_id == $id)' \
  <<<"$GEN1" 2>/dev/null || echo false)"
GEN2_TAGGED="$(jq -s --arg id "$GEN2_ID" 'length > 0 and all(.[]; .watch_id == $id)' \
  <<<"$GEN2" 2>/dev/null || echo false)"
check "every event carries its generation watch_id" \
  "$([[ "$GEN1_TAGGED" == true && "$GEN2_TAGGED" == true ]] && echo yes || echo no)" "yes"

# The branch journal used to grow forever. Once old generations crossed the
# stream reader's 2 MiB input boundary, even an explicitly named NEW generation
# appended at the end was rejected before selection. A producer that owns the
# branch lock must retire completed history before publishing the new start.
ROLLOVER_BRANCH="journal-rollover"
ROLLOVER_KEY="$(pr_watch_branch_key "$ROLLOVER_BRANCH")"
ROLLOVER_LOG="$REPO/.git/pr-watch/${ROLLOVER_KEY}.jsonl"
ROLLOVER_ID="watch-aaaaaaaaaaaaaaaaaaaaaaaa"
reset_state
mkdir -p "$REPO/.git/pr-watch"
perl -MJSON::PP -e '
  my $event = JSON::PP->new->canonical->encode({
    kind => "check", watch_id => "old-generation", body => ("x" x 900)
  }) . "\n";
  print $event while tell(STDOUT) <= 2097152;
' > "$ROLLOVER_LOG"
ROLLOVER_WATCH_OUT="$(run_watch --branch "$ROLLOVER_BRANCH" --pr 42 --once \
  --watch-id "$ROLLOVER_ID")"
ROLLOVER_STREAM_OUT="$(with_deadline 10 bash "$REPO_ROOT/.agents/watch/pr-watch-stream.sh" \
  "$ROLLOVER_LOG" 1 --watch-id "$ROLLOVER_ID")"
ROLLOVER_STREAM_RC=$?
check "an oversized completed journal cannot block the next explicit generation" \
  "$(printf '%s\n' "$ROLLOVER_STREAM_OUT" | jq -s --arg id "$ROLLOVER_ID" \
      'length >= 2 and all(.[]; .watch_id == $id)
       and any(.[]; .kind == "watch_start") and any(.[]; .kind == "watch_end")')/$ROLLOVER_STREAM_RC" \
  "true/0"
check "the producer bounds a branch journal at the stream input ceiling" \
  "$([[ "$(wc -c < "$ROLLOVER_LOG" | tr -d ' ')" -le 2097152 ]] && echo bounded || echo oversized)" \
  "bounded"
check "the rollover generation itself was published" \
  "$(events_of watch_start "$ROLLOVER_WATCH_OUT" | jq -r '.watch_id')" "$ROLLOVER_ID"

# The companion de-dup ledger had the same lifetime bug at a larger threshold:
# appends were unlimited, while reads failed permanently after 8 MiB. A new lock-
# owned generation must retire that completed state before polling.
SEEN_ROLLOVER_BRANCH="seen-rollover"
SEEN_ROLLOVER_KEY="$(pr_watch_branch_key "$SEEN_ROLLOVER_BRANCH")"
SEEN_ROLLOVER_FILE="$REPO/.git/pr-watch/${SEEN_ROLLOVER_KEY}.seen"
SEEN_ROLLOVER_ID="watch-bbbbbbbbbbbbbbbbbbbbbbbb"
reset_state
mkdir -p "$REPO/.git/pr-watch"
perl -e 'print "old-seen-key\n" while tell(STDOUT) <= 8388608' \
  > "$SEEN_ROLLOVER_FILE"
SEEN_ROLLOVER_OUT="$(run_watch --branch "$SEEN_ROLLOVER_BRANCH" --pr 42 --once \
  --watch-id "$SEEN_ROLLOVER_ID")"
check "an oversized completed de-dup ledger cannot block the next generation" \
  "$(events_of watch_end "$SEEN_ROLLOVER_OUT" | jq -r '.watch_id // empty')" \
  "$SEEN_ROLLOVER_ID"
check "the producer bounds de-dup state per generation" \
  "$([[ "$(wc -c < "$SEEN_ROLLOVER_FILE" | tr -d ' ')" -le 8388608 ]] \
      && echo bounded || echo oversized)" "bounded"

# A fixed claim slot may already carry a fresh command published by another
# hook invocation. Rejecting that occupied slot must not convert the selected
# inode into a retired record as error cleanup.
CLAIM_REJECT_DIR="$TMP/claim-reject"
CLAIM_REJECT_SOURCE="$CLAIM_REJECT_DIR/source.json"
CLAIM_REJECT_SLOT="$CLAIM_REJECT_DIR/attachment.json.claim.0"
CLAIM_REJECT_SNAPSHOT="$CLAIM_REJECT_DIR/slot.before"
CLAIM_REJECT_SOURCE_BODY='{"schema":1,"source":"new attachment"}'
CLAIM_REJECT_LIVE_BODY='{"schema":1,"created_at":4102444800,"live":true}'
mkdir -p "$CLAIM_REJECT_DIR"
printf '%s\n' "$CLAIM_REJECT_SOURCE_BODY" > "$CLAIM_REJECT_SOURCE"
printf '%s\n' "$CLAIM_REJECT_LIVE_BODY" > "$CLAIM_REJECT_SLOT"
cp "$CLAIM_REJECT_SLOT" "$CLAIM_REJECT_SNAPSHOT"
CLAIM_REJECT_SOURCE_ID="$(verdict_audit_path_identity "$CLAIM_REJECT_SOURCE")"
CLAIM_REJECT_SOURCE_HASH="$(LC_ALL=C printf '%s' "$CLAIM_REJECT_SOURCE_BODY" \
  | shasum -a 256 | awk '{print $1}')"
CLAIM_REJECT_SLOT_ID_BEFORE="$(verdict_audit_path_identity "$CLAIM_REJECT_SLOT")"
pr_watch_claim_regular_file "$CLAIM_REJECT_SOURCE" "$CLAIM_REJECT_SLOT" \
  "$CLAIM_REJECT_SOURCE_ID" "$CLAIM_REJECT_SOURCE_HASH" >/dev/null 2>&1
CLAIM_REJECT_RC=$?
CLAIM_REJECT_SLOT_ID_AFTER="$(verdict_audit_path_identity \
  "$CLAIM_REJECT_SLOT" 2>/dev/null || true)"
CLAIM_REJECT_ID_STATE=changed
[[ "$CLAIM_REJECT_SLOT_ID_AFTER" == "$CLAIM_REJECT_SLOT_ID_BEFORE" ]] \
  && CLAIM_REJECT_ID_STATE=same
CLAIM_REJECT_BYTE_STATE=changed
cmp -s "$CLAIM_REJECT_SLOT" "$CLAIM_REJECT_SNAPSHOT" \
  && CLAIM_REJECT_BYTE_STATE=same
check "rejecting an occupied live claim preserves its exact inode and bytes" \
  "rc=$CLAIM_REJECT_RC inode=$CLAIM_REJECT_ID_STATE bytes=$CLAIM_REJECT_BYTE_STATE" \
  "rc=1 inode=same bytes=same"

# Claim publication must never fsync an independent JSON copy while the source
# JSON is still consumable. Stop the helper at its first durable write and count
# unique JSON inodes, not names: a hard-link handoff may temporarily have two
# names but still represents one exact authority.
CLAIM_ATOMIC_DIR="$TMP/claim-atomic"
CLAIM_ATOMIC_LIB="$CLAIM_ATOMIC_DIR/lib"
CLAIM_ATOMIC_SOURCE="$CLAIM_ATOMIC_DIR/source.json"
CLAIM_ATOMIC_SLOT="$CLAIM_ATOMIC_DIR/source.json.claim.0"
CLAIM_ATOMIC_BODY='{"schema":1,"source":"atomic attachment"}'
mkdir -p "$CLAIM_ATOMIC_LIB"
printf '%s\n' "$CLAIM_ATOMIC_BODY" > "$CLAIM_ATOMIC_SOURCE"
CLAIM_ATOMIC_SOURCE_ID="$(verdict_audit_path_identity "$CLAIM_ATOMIC_SOURCE")"
CLAIM_ATOMIC_HASH="$(LC_ALL=C printf '%s' "$CLAIM_ATOMIC_BODY" \
  | shasum -a 256 | awk '{print $1}')"
cat > "$CLAIM_ATOMIC_LIB/PrWatchClaimAtomic.pm" <<'CLAIM_ATOMIC_MODULE_EOF'
package PrWatchClaimAtomic;
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
    if ($armed) {
      $armed = 0;
      open(my $pid_fh, ">", $ENV{CLAIM_ATOMIC_PID}) or die $!;
      print {$pid_fh} "$$\n";
      close($pid_fh) or die $!;
      open(my $ready_fh, ">", $ENV{CLAIM_ATOMIC_READY}) or die $!;
      print {$ready_fh} "ready\n";
      close($ready_fh) or die $!;
      until (-e $ENV{CLAIM_ATOMIC_RELEASE}) {
        select(undef, undef, undef, 0.01);
      }
    }
    return $result;
  };
}
1;
CLAIM_ATOMIC_MODULE_EOF
(
  export PERL5LIB="$CLAIM_ATOMIC_LIB"
  export PERL5OPT=-MPrWatchClaimAtomic
  export CLAIM_ATOMIC_PID="$CLAIM_ATOMIC_DIR/helper.pid"
  export CLAIM_ATOMIC_READY="$CLAIM_ATOMIC_DIR/ready"
  export CLAIM_ATOMIC_RELEASE="$CLAIM_ATOMIC_DIR/release"
  pr_watch_claim_regular_file "$CLAIM_ATOMIC_SOURCE" "$CLAIM_ATOMIC_SLOT" \
    "$CLAIM_ATOMIC_SOURCE_ID" "$CLAIM_ATOMIC_HASH"
) > "$CLAIM_ATOMIC_DIR/out" 2> "$CLAIM_ATOMIC_DIR/err" \
  & CLAIM_ATOMIC_JOB=$!
CLAIM_ATOMIC_DEADLINE=$(( SECONDS + 5 ))
while (( SECONDS < CLAIM_ATOMIC_DEADLINE )); do
  [[ -e "$CLAIM_ATOMIC_DIR/ready" ]] && break
  kill -0 "$CLAIM_ATOMIC_JOB" 2>/dev/null || break
  sleep 0.02
done
CLAIM_ATOMIC_UNIQUE=0
CLAIM_ATOMIC_IDENTITIES=""
for CLAIM_ATOMIC_PATH in "$CLAIM_ATOMIC_SOURCE" "$CLAIM_ATOMIC_SLOT"; do
  if [[ -f "$CLAIM_ATOMIC_PATH" \
     && "$(cat "$CLAIM_ATOMIC_PATH" 2>/dev/null)" == "$CLAIM_ATOMIC_BODY" ]]; then
    CLAIM_ATOMIC_IDENTITY="$(verdict_audit_path_identity \
      "$CLAIM_ATOMIC_PATH" 2>/dev/null || true)"
    if [[ -n "$CLAIM_ATOMIC_IDENTITY" \
       && "|$CLAIM_ATOMIC_IDENTITIES|" != *"|$CLAIM_ATOMIC_IDENTITY|"* ]]; then
      CLAIM_ATOMIC_IDENTITIES="${CLAIM_ATOMIC_IDENTITIES:+$CLAIM_ATOMIC_IDENTITIES|}$CLAIM_ATOMIC_IDENTITY"
      CLAIM_ATOMIC_UNIQUE=$((CLAIM_ATOMIC_UNIQUE + 1))
    fi
  fi
done
CLAIM_ATOMIC_HELPER_PID="$(cat "$CLAIM_ATOMIC_DIR/helper.pid" 2>/dev/null || true)"
if [[ "$CLAIM_ATOMIC_HELPER_PID" =~ ^[1-9][0-9]*$ ]]; then
  kill -KILL "$CLAIM_ATOMIC_HELPER_PID" 2>/dev/null || true
fi
touch "$CLAIM_ATOMIC_DIR/release"
wait "$CLAIM_ATOMIC_JOB" 2>/dev/null; CLAIM_ATOMIC_RC=$?
if [[ -e "$CLAIM_ATOMIC_DIR/ready" && "$CLAIM_ATOMIC_RC" -ne 0 \
   && "$CLAIM_ATOMIC_UNIQUE" -le 1 ]]; then
  ok "claim handoff has one durable JSON authority at every sync"
else
  no "claim handoff has one durable JSON authority at every sync" \
    "barrier=$([[ -e "$CLAIM_ATOMIC_DIR/ready" ]] && echo hit || echo missed) rc=$CLAIM_ATOMIC_RC unique=$CLAIM_ATOMIC_UNIQUE identities=$CLAIM_ATOMIC_IDENTITIES"
fi

# The per-branch daemon log shares the event stream's 2 MiB local-state budget.
# Three sequential producer generations each write through the real descriptor
# helper; preserving only an append-only file would exceed that adjacent cap.
DAEMON_BOUND_DIR="$TMP/daemon-bound"
DAEMON_BOUND_LOG="$DAEMON_BOUND_DIR/branch.daemon.log"
DAEMON_BOUND_LIMIT=2097152
mkdir -p "$DAEMON_BOUND_DIR"
DAEMON_BOUND_IDENTITY="$(pr_watch_state_directory_identity "$DAEMON_BOUND_DIR")"
DAEMON_BOUND_RUNS=ok
for DAEMON_BOUND_GENERATION in 1 2 3; do
  (
    pr_watch_exec_with_regular_log "$DAEMON_BOUND_LOG" "$DAEMON_BOUND_IDENTITY" \
      /bin/bash -c '
        perl -e '\''print "o" x 524288'\''
        perl -e '\''print "e" x 524288'\'' >&2
        printf "\ngeneration-%s\n" "$1"
      ' -- "$DAEMON_BOUND_GENERATION"
  ) || DAEMON_BOUND_RUNS=failed
done
DAEMON_BOUND_BYTES="$(wc -c < "$DAEMON_BOUND_LOG" | tr -d ' ')"
DAEMON_BOUND_LATEST="$(tail -n 1 "$DAEMON_BOUND_LOG" 2>/dev/null || true)"
check "per-branch daemon output stays within the stream's 2 MiB state budget" \
  "runs=$DAEMON_BOUND_RUNS bounded=$(( DAEMON_BOUND_BYTES <= DAEMON_BOUND_LIMIT )) latest=$DAEMON_BOUND_LATEST" \
  "runs=ok bounded=1 latest=generation-3"

# The bound applies while one generation is still live, not only when a later
# generation happens to truncate the file. Keep the writer alive after it emits
# 3 MiB so the assertion samples the active descriptor boundary.
DAEMON_ACTIVE_BOUND_DIR="$TMP/daemon-active-bound"
DAEMON_ACTIVE_BOUND_LOG="$DAEMON_ACTIVE_BOUND_DIR/branch.daemon.log"
DAEMON_ACTIVE_BOUND_READY="$DAEMON_ACTIVE_BOUND_DIR/writer.ready"
DAEMON_ACTIVE_BOUND_RELEASE="$DAEMON_ACTIVE_BOUND_DIR/writer.release"
mkdir -p "$DAEMON_ACTIVE_BOUND_DIR"
DAEMON_ACTIVE_BOUND_DIR_ID="$(pr_watch_state_directory_identity \
  "$DAEMON_ACTIVE_BOUND_DIR")"
(
  pr_watch_exec_with_regular_log \
    "$DAEMON_ACTIVE_BOUND_LOG" "$DAEMON_ACTIVE_BOUND_DIR_ID" \
    /bin/bash -c '
      perl -e '\''print "x" x (3 * 1024 * 1024)'\''
      : > "$1"
      while [[ ! -e "$2" ]]; do /bin/sleep 0.05; done
    ' -- "$DAEMON_ACTIVE_BOUND_READY" "$DAEMON_ACTIVE_BOUND_RELEASE"
) &
DAEMON_ACTIVE_BOUND_PID=$!
DAEMON_ACTIVE_BOUND_BARRIER=missed
DAEMON_ACTIVE_BOUND_DEADLINE=$(( SECONDS + 5 ))
while (( SECONDS < DAEMON_ACTIVE_BOUND_DEADLINE )); do
  if [[ -e "$DAEMON_ACTIVE_BOUND_READY" ]]; then
    DAEMON_ACTIVE_BOUND_BARRIER=hit
    break
  fi
  kill -0 "$DAEMON_ACTIVE_BOUND_PID" 2>/dev/null || break
  sleep 0.05
done
DAEMON_ACTIVE_BOUND_BYTES="$(wc -c < "$DAEMON_ACTIVE_BOUND_LOG" \
  2>/dev/null | tr -d ' ' || printf 0)"
DAEMON_ACTIVE_BOUND_STATE=oversized
[[ "$DAEMON_ACTIVE_BOUND_BYTES" =~ ^[0-9]+$ \
   && "$DAEMON_ACTIVE_BOUND_BYTES" -le "$DAEMON_BOUND_LIMIT" ]] \
  && DAEMON_ACTIVE_BOUND_STATE=bounded
: > "$DAEMON_ACTIVE_BOUND_RELEASE"
DAEMON_ACTIVE_BOUND_DEADLINE=$(( SECONDS + 3 ))
while (( SECONDS < DAEMON_ACTIVE_BOUND_DEADLINE )); do
  kill -0 "$DAEMON_ACTIVE_BOUND_PID" 2>/dev/null || break
  sleep 0.05
done
kill -KILL "$DAEMON_ACTIVE_BOUND_PID" 2>/dev/null || true
wait "$DAEMON_ACTIVE_BOUND_PID" 2>/dev/null || true
check "one live daemon generation cannot exceed the 2 MiB log budget" \
  "barrier=$DAEMON_ACTIVE_BOUND_BARRIER state=$DAEMON_ACTIVE_BOUND_STATE" \
  "barrier=hit state=bounded"

# The shared lease is a pathname-selected serialization object. If that name is
# replaced while the active helper still owns the old inode, a repeat helper
# must not mistake the replacement for an unlocked new generation and truncate
# the active diagnostic sentinel.
DAEMON_REPLACE_DIR="$TMP/daemon-lease-replace"
DAEMON_REPLACE_LOG="$DAEMON_REPLACE_DIR/branch.daemon.log"
DAEMON_REPLACE_OWNER="${DAEMON_REPLACE_LOG}.owner"
DAEMON_REPLACE_DISPLACED="${DAEMON_REPLACE_OWNER}.displaced"
DAEMON_REPLACE_READY="$DAEMON_REPLACE_DIR/active.ready"
DAEMON_REPLACE_RELEASE="$DAEMON_REPLACE_DIR/active.release"
DAEMON_REPLACE_SENTINEL="active-daemon-sentinel-must-survive-owner-replacement"
mkdir -p "$DAEMON_REPLACE_DIR"
DAEMON_REPLACE_DIR_ID="$(pr_watch_state_directory_identity "$DAEMON_REPLACE_DIR")"
(
  pr_watch_exec_with_regular_log "$DAEMON_REPLACE_LOG" "$DAEMON_REPLACE_DIR_ID" \
    /bin/bash -c '
      printf "%s\n" "$1"
      : > "$2"
      while [[ ! -e "$3" ]]; do /bin/sleep 0.05; done
    ' -- "$DAEMON_REPLACE_SENTINEL" "$DAEMON_REPLACE_READY" \
    "$DAEMON_REPLACE_RELEASE"
) &
DAEMON_REPLACE_ACTIVE_PID=$!
DAEMON_REPLACE_BARRIER=missed
DAEMON_REPLACE_DEADLINE=$(( SECONDS + 5 ))
while (( SECONDS < DAEMON_REPLACE_DEADLINE )); do
  if [[ -e "$DAEMON_REPLACE_READY" ]]; then
    DAEMON_REPLACE_BARRIER=hit
    break
  fi
  kill -0 "$DAEMON_REPLACE_ACTIVE_PID" 2>/dev/null || break
  sleep 0.05
done
if [[ "$DAEMON_REPLACE_BARRIER" == hit ]]; then
  if [[ -f "$DAEMON_REPLACE_OWNER" ]]; then
    mv "$DAEMON_REPLACE_OWNER" "$DAEMON_REPLACE_DISPLACED"
  fi
  printf 'replacement lease must be irrelevant\n' > "$DAEMON_REPLACE_OWNER"
  pr_watch_exec_with_regular_log \
    "$DAEMON_REPLACE_LOG" "$DAEMON_REPLACE_DIR_ID" /bin/true \
    >/dev/null 2>&1 || true
fi
DAEMON_REPLACE_DIAGNOSTIC=truncated
grep -Fqx "$DAEMON_REPLACE_SENTINEL" "$DAEMON_REPLACE_LOG" 2>/dev/null \
  && DAEMON_REPLACE_DIAGNOSTIC=preserved
: > "$DAEMON_REPLACE_RELEASE"
wait "$DAEMON_REPLACE_ACTIVE_PID" 2>/dev/null || true
check "owner-path replacement cannot truncate an active daemon diagnostic" \
  "barrier=$DAEMON_REPLACE_BARRIER diagnostic=$DAEMON_REPLACE_DIAGNOSTIC" \
  "barrier=hit diagnostic=preserved"

# A watcher may briefly launch helpers, but lease lifetime belongs to the
# watcher leader. A background child that survives the leader must not inherit
# enough authority to make the next generation look active forever.
DAEMON_DESC_DIR="$TMP/daemon-descendant-lease"
DAEMON_DESC_LOG="$DAEMON_DESC_DIR/branch.daemon.log"
DAEMON_DESC_OWNER="${DAEMON_DESC_LOG}.owner"
DAEMON_DESC_PID_FILE="$DAEMON_DESC_DIR/descendant.pid"
mkdir -p "$DAEMON_DESC_DIR"
DAEMON_DESC_DIR_ID="$(pr_watch_state_directory_identity "$DAEMON_DESC_DIR")"
pr_watch_exec_with_regular_log "$DAEMON_DESC_LOG" "$DAEMON_DESC_DIR_ID" \
  /bin/bash -c '
    ( exec /bin/sleep 30 ) &
    printf "%s\n" "$!" > "$1"
  ' -- "$DAEMON_DESC_PID_FILE" >/dev/null 2>&1
DAEMON_DESC_LEADER_RC=$?
DAEMON_DESC_PID="$(cat "$DAEMON_DESC_PID_FILE" 2>/dev/null || true)"
DAEMON_DESC_TOKEN=""
if [[ "$DAEMON_DESC_PID" =~ ^[1-9][0-9]*$ ]]; then
  DAEMON_DESC_TOKEN="$(verdict_audit_process_start_token \
    "$DAEMON_DESC_PID" 2>/dev/null || true)"
fi
DAEMON_DESC_LEASE_PATH="$DAEMON_DESC_OWNER"
[[ -f "$DAEMON_DESC_LEASE_PATH" ]] \
  || DAEMON_DESC_LEASE_PATH="$DAEMON_DESC_LOG"
if perl -MFcntl=:DEFAULT,:flock -e '
    sysopen(my $fh, $ARGV[0], O_RDWR | O_NONBLOCK) or exit 2;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
  ' "$DAEMON_DESC_LEASE_PATH" 2>/dev/null; then
  DAEMON_DESC_LEASE=released
else
  DAEMON_DESC_LEASE=held
fi
if [[ -n "$DAEMON_DESC_TOKEN" \
   && "$(verdict_audit_process_start_token \
      "$DAEMON_DESC_PID" 2>/dev/null || true)" == "$DAEMON_DESC_TOKEN" ]]; then
  kill -KILL "$DAEMON_DESC_PID" 2>/dev/null || true
fi
check "a background descendant cannot retain the daemon lease after its leader exits" \
  "leader_rc=$DAEMON_DESC_LEADER_RC pid=$([[ "$DAEMON_DESC_PID" =~ ^[1-9][0-9]*$ ]] && echo recorded || echo missing) lease=$DAEMON_DESC_LEASE" \
  "leader_rc=0 pid=recorded lease=released"

# Replacing slash with dash aliases valid Git branches (foo/bar and foo-bar).
# Both producer state and the consumer command must address distinct files.
reset_state
run_watch --branch foo/bar --pr 42 --once >/dev/null
run_watch --branch foo-bar --pr 42 --once >/dev/null
BRANCH_LOG_COUNT="$(find "$REPO/.git/pr-watch" -maxdepth 1 -type f -name '*.jsonl' \
  | wc -l | tr -d ' ')"
check "foo/bar and foo-bar use collision-free event logs" "$BRANCH_LOG_COUNT" "2"
check "branch event-log names stay one bounded filesystem component" \
  "$(find "$REPO/.git/pr-watch" -maxdepth 1 -type f -name '*.jsonl' -exec basename {} \; \
      | awk 'length($0) > 80 || $0 !~ /^branch-[0-9a-f]+\.jsonl$/ { bad=1 } END { print bad ? "no" : "yes" }')" "yes"

# ── 6. terminal states ───────────────────────────────────────────────────────

echo
echo "## Terminal states"
reset_state
jq '[.[] | select(.bucket != "pending")]' "$FIXTURE_DIR/checks.json" > "$FIXTURE_DIR/checks.tmp" \
  && mv "$FIXTURE_DIR/checks.tmp" "$FIXTURE_DIR/checks.json"
OUT5="$(run_watch --pr 42 --once)"
check "checks_done fires once all checks conclude" \
  "$(events_of checks_done "$OUT5" | jq -r '.failed')" "1"

check "checks_done does not repeat for the same set" \
  "$(events_of checks_done "$(run_watch --pr 42 --once)" | wc -l | tr -d ' ')" "0"

# A CI re-run keeps the check COUNT identical but produces new job URLs. Keying
# the summary on the count alone reported the first completion and then went
# silent forever — including for a re-run that turned red.
jq '[.[] | .link |= sub("/runs/"; "/runs/re-") | .bucket = "pass" | .state = "SUCCESS"]' \
  "$FIXTURE_DIR/checks.json" > "$FIXTURE_DIR/checks.tmp" && mv "$FIXTURE_DIR/checks.tmp" "$FIXTURE_DIR/checks.json"
OUT5b="$(run_watch --pr 42 --once)"
# 5 concluded checks by now: the 4 from write_fixtures plus the "New Job" added
# in the dedup section above. All flipped to pass, so 0 failed / 5 passed.
check "checks_done re-fires after a re-run with the same check count" \
  "$(events_of checks_done "$OUT5b" | jq -r '.failed + "/" + .passed')" "0/5"

reset_state
jq '.state = "MERGED"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
OUT6="$(with_deadline 30 run_watch --pr 42)"   # no --once: must still exit, PR is MERGED
check "merged PR ends the watch without --once" \
  "$(events_of watch_end "$OUT6" | jq -r '.reason')" "PR MERGED"

write_fixtures

# ── 6b. watch until merged, not until quiet ──────────────────────────────────
#
# The whole point of the watch is to still be running at merge time. A PR with
# green CI awaiting human review produces NO new events for hours; an earlier
# version measured "time since the last new event" and quit long before the
# merge it existed to report.

echo
echo "## Runs until merged, not until quiet"

# Everything already seen, PR open, nothing new will ever arrive: the classic
# awaiting-review state. Must keep polling rather than call it idle.
reset_state
run_watch --pr 42 --once >/dev/null            # prime .seen so nothing is new
jq '.mergeable = "UNKNOWN"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/v.tmp" \
  && mv "$FIXTURE_DIR/v.tmp" "$FIXTURE_DIR/view.json"
QUIET="$(PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=3 PR_WATCH_MAX_LIFETIME=6 with_deadline 40 run_watch --pr 42)"
check "a quiet OPEN PR with UNKNOWN mergeability still has contact" \
  "$(events_of watch_end "$QUIET" | jq -r '.reason')" \
  "max lifetime 6s reached before merge"

# A valid JSON object missing the requested mergeability field is not a
# successful observation. Otherwise a downgraded/changed API shape would keep
# the watcher alive while silently disabling the conflict guarantee.
reset_state
jq 'del(.mergeable)' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/view.tmp" \
  && mv "$FIXTURE_DIR/view.tmp" "$FIXTURE_DIR/view.json"
MISSING_MERGEABILITY="$(PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=2 PR_WATCH_MAX_LIFETIME=6 with_deadline 40 run_watch --pr 42)"
check "missing mergeability is treated as lost contact" \
  "$(events_of watch_end "$MISSING_MERGEABILITY" | jq -r '.reason')" \
  "no contact with PR for 2s"
write_fixtures

# Same silence, but now the polls themselves fail: contact is genuinely lost.
reset_state
run_watch --pr 42 --once >/dev/null
mv "$FIXTURE_DIR/view.json" "$FIXTURE_DIR/view.hidden"
printf 'not json\n' > "$FIXTURE_DIR/view.json"
LOST="$(PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=2 PR_WATCH_MAX_LIFETIME=60 with_deadline 40 run_watch --pr 42)"
check "lost contact DOES end the watch" \
  "$(events_of watch_end "$LOST" | jq -r '.reason')" \
  "no contact with PR for 2s"
mv "$FIXTURE_DIR/view.hidden" "$FIXTURE_DIR/view.json"

# A merge that lands mid-watch must still be reported, after the quiet stretch.
reset_state
run_watch --pr 42 --once >/dev/null
( sleep 3; jq '.state = "MERGED"' "$FIXTURE_DIR/view.json" > "$FIXTURE_DIR/v.tmp" \
    && mv "$FIXTURE_DIR/v.tmp" "$FIXTURE_DIR/view.json" ) &
LATE="$(PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 PR_WATCH_MAX_LIFETIME=60 with_deadline 40 run_watch --pr 42)"
wait
check "a merge after a quiet stretch is still reported" \
  "$(events_of watch_end "$LATE" | jq -r '.reason')" "PR MERGED"

write_fixtures

# PR discovery runs before the main polling loop, but it is still part of the
# producer's absolute lifetime. A discovery pause longer than the remaining
# lifetime makes that backstop ineffective when no PR exists yet.
reset_state
: > "$FIXTURE_DIR/prnumber.txt"
DISCOVERY_STARTED_AT="$(date +%s)"
DISCOVERY_OUT="$(with_deadline 5 /bin/bash -c '
  cd "$1" || exit 1
  exec env PR_WATCH_INTERVAL=3 PR_WATCH_IDLE_TIMEOUT=30 \
    PR_WATCH_MAX_LIFETIME=1 bash "$2" --branch discovery-lifetime \
      --watch-id watch-dddddddddddddddddddddddd
' -- "$REPO" "$WATCHER" 2>&1)"
DISCOVERY_RC=$?
DISCOVERY_ELAPSED=$(( $(date +%s) - DISCOVERY_STARTED_AT ))
write_fixtures
check "PR discovery clamps its pause to the remaining producer lifetime" \
  "$(events_of watch_end "$DISCOVERY_OUT" | wc -l | tr -d ' ')/$DISCOVERY_RC/$(( DISCOVERY_ELAPSED <= 2 ))" \
  "1/0/1"

# The absolute producer lifetime also bounds work inside a discovery attempt.
# A slow gh invocation must inherit only the remaining lifetime, not the larger
# per-command timeout, and expiry is not evidence that no PR exists.
reset_state
: > "$FIXTURE_DIR/prnumber.txt"
SLOW_DISCOVERY_STARTED_AT="$(date +%s)"
SLOW_DISCOVERY_OUT="$(with_deadline 5 /bin/bash -c '
  cd "$1" || exit 1
  exec env GH_DELAY_SECONDS=5 PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 \
    PR_WATCH_MAX_LIFETIME=1 PR_WATCH_COMMAND_TIMEOUT=10 \
    bash "$2" --branch slow-discovery-lifetime \
      --watch-id watch-cccccccccccccccccccccccc
' -- "$REPO" "$WATCHER" 2>&1)"
SLOW_DISCOVERY_RC=$?
SLOW_DISCOVERY_ELAPSED=$(( $(date +%s) - SLOW_DISCOVERY_STARTED_AT ))
write_fixtures
check "PR discovery command is bounded by the remaining producer lifetime" \
  "$(events_of watch_end "$SLOW_DISCOVERY_OUT" | jq -r '.reason')/$SLOW_DISCOVERY_RC/$(( SLOW_DISCOVERY_ELAPSED <= 3 ))" \
  "max lifetime 1s reached before merge/0/1"

# ── 7. the stream reader ─────────────────────────────────────────────────────

echo
echo "## Stream reader"
STREAM="$REPO_ROOT/.agents/watch/pr-watch-stream.sh"
SLOG="$TMP/stream.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"base-generation"}' \
  '{"kind":"check","watch_id":"base-generation","bucket":"pass"}' > "$SLOG"
( sleep 2; printf '%s\n' \
    '{"kind":"check","watch_id":"base-generation","bucket":"fail"}' >> "$SLOG"
  sleep 2; printf '%s\n' \
    '{"kind":"watch_end","watch_id":"base-generation","reason":"PR MERGED"}' >> "$SLOG" ) &
SOUT="$(with_deadline 30 bash "$STREAM" "$SLOG" 1)"
SRC=$?
wait

check "replays existing lines and follows new ones" \
  "$(printf '%s\n' "$SOUT" | wc -l | tr -d ' ')" "4"
check "delivers watch_end before terminating" \
  "$(printf '%s\n' "$SOUT" | tail -1 | jq -r '.kind')" "watch_end"
check "exits 0 at watch_end instead of following forever" "$SRC" "0"

MISSING="$(PR_WATCH_STREAM_WAIT=2 bash "$STREAM" "$TMP/does-not-exist.jsonl" 1 2>/dev/null)"
check "a log that never appears reports an error instead of hanging" \
  "$(printf '%s' "$MISSING" | jq -r '.kind')" "stream_error"

# Each wait loop has one absolute deadline. Sleeping the full poll interval can
# overshoot it by an arbitrary amount, so exercise all three wait phases with a
# poll longer than the declared wait and assert both the reason and wall bound.
MISSING_CLAMP_LOG="$TMP/missing-clamped.jsonl"
MISSING_CLAMP_STARTED_AT="$(date +%s)"
MISSING_CLAMP_OUT="$(with_deadline 6 env PR_WATCH_STREAM_WAIT=2 \
  bash "$STREAM" "$MISSING_CLAMP_LOG" 4)"
MISSING_CLAMP_RC=$?
MISSING_CLAMP_ELAPSED=$(( $(date +%s) - MISSING_CLAMP_STARTED_AT ))
check "absent-log sleep is clamped to the remaining stream wait" \
  "$(printf '%s\n' "$MISSING_CLAMP_OUT" \
      | jq -r 'select(.kind == "stream_error") | .reason')/$MISSING_CLAMP_RC/$(( MISSING_CLAMP_ELAPSED <= 3 ))" \
  "no_event_log/1/1"

NO_LIVE_CLAMP_LOG="$TMP/no-live-clamped.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"ended-before-discovery"}' \
  '{"kind":"watch_end","watch_id":"ended-before-discovery","reason":"already ended"}' \
  > "$NO_LIVE_CLAMP_LOG"
NO_LIVE_CLAMP_STARTED_AT="$(date +%s)"
NO_LIVE_CLAMP_OUT="$(with_deadline 6 env PR_WATCH_STREAM_WAIT=2 \
  bash "$STREAM" "$NO_LIVE_CLAMP_LOG" 4)"
NO_LIVE_CLAMP_RC=$?
NO_LIVE_CLAMP_ELAPSED=$(( $(date +%s) - NO_LIVE_CLAMP_STARTED_AT ))
check "live-generation discovery sleep is clamped to the remaining wait" \
  "$(printf '%s\n' "$NO_LIVE_CLAMP_OUT" \
      | jq -r 'select(.kind == "stream_error") | .reason')/$NO_LIVE_CLAMP_RC/$(( NO_LIVE_CLAMP_ELAPSED <= 3 ))" \
  "no_live_generation/1/1"

MISSING_ID_CLAMP_STARTED_AT="$(date +%s)"
MISSING_ID_CLAMP_OUT="$(with_deadline 6 env PR_WATCH_STREAM_WAIT=2 \
  bash "$STREAM" "$NO_LIVE_CLAMP_LOG" 4 --watch-id never-published)"
MISSING_ID_CLAMP_RC=$?
MISSING_ID_CLAMP_ELAPSED=$(( $(date +%s) - MISSING_ID_CLAMP_STARTED_AT ))
check "explicit-generation discovery sleep is clamped to the remaining wait" \
  "$(printf '%s\n' "$MISSING_ID_CLAMP_OUT" \
      | jq -r 'select(.kind == "stream_error") | .reason')/$MISSING_ID_CLAMP_RC/$(( MISSING_ID_CLAMP_ELAPSED <= 3 ))" \
  "watch_id_not_found/1/1"

OVERSIZE_LOG="$TMP/oversize.jsonl"
perl -e '
  print qq{{"kind":"watch_start","watch_id":"oversize-generation"}\n};
  print "x" x 2097152;
' > "$OVERSIZE_LOG"
OVERSIZE_OUT="$(with_deadline 5 bash "$STREAM" "$OVERSIZE_LOG" 1 \
  --watch-id oversize-generation)"
OVERSIZE_RC=$?
check "stream rejects an oversized regular journal before scanning it" \
  "$(printf '%s\n' "$OVERSIZE_OUT" | jq -r 'select(.kind == "stream_error") | .reason')/$OVERSIZE_RC" \
  "input_limit/1"

echo
echo "## Generation-scoped stream replay"
GEN_LOG="$TMP/generations.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"old-generation"}' \
  '{"kind":"check","watch_id":"old-generation","bucket":"pass"}' \
  '{"kind":"watch_end","watch_id":"old-generation","reason":"old complete"}' \
  '{"kind":"watch_start","watch_id":"new-generation"}' \
  '{"kind":"check","watch_id":"new-generation","bucket":"fail"}' > "$GEN_LOG"
( sleep 2; printf '%s\n' \
    '{"kind":"watch_end","watch_id":"new-generation","reason":"new complete"}' >> "$GEN_LOG" ) &
GEN_OUT="$(with_deadline 20 bash "$STREAM" "$GEN_LOG" 1)"
GEN_RC=$?
wait
check "historical watch_end cannot terminate the latest live generation" \
  "$(printf '%s\n' "$GEN_OUT" | jq -r 'select(.kind == "watch_end") | .reason')" "new complete"
check "default stream emits only the latest live watch_id" \
  "$(printf '%s\n' "$GEN_OUT" | jq -s 'all(.[]; .watch_id == "new-generation")')" "true"
check "latest generation stream exits 0 at its own watch_end" "$GEN_RC" "0"

CURSOR_OUT="$(with_deadline 10 bash "$STREAM" "$GEN_LOG" 1 --watch-id old-generation)"
CURSOR_RC=$?
check "explicit watch-id cursor replays only that historical generation" \
  "$(printf '%s\n' "$CURSOR_OUT" | jq -s \
      'length == 3 and all(.[]; .watch_id == "old-generation")')" "true"
check "explicit ended generation exits 0" "$CURSOR_RC" "0"

# A syntactically valid start record is not proof that a producer is still
# alive. Crash/signal paths can leave a start-only journal and no branch lock;
# an attached consumer must surface that orphan instead of following forever.
ORPHAN_LOG="$REPO/.git/pr-watch/$(pr_watch_branch_key orphan-stream).jsonl"
mkdir -p "${ORPHAN_LOG%/*}"
jq -nc '{ts:"2026-01-01T00:00:00Z",kind:"watch_start",
  watch_id:"orphan-generation",pr:"42",branch:"orphan-stream",interval:"1"}' \
  > "$ORPHAN_LOG"
ORPHAN_STARTED_AT="$(date +%s)"
ORPHAN_OUT="$(with_deadline 5 env PR_WATCH_STREAM_WAIT=2 \
  bash "$STREAM" "$ORPHAN_LOG" 1 --watch-id orphan-generation)"
ORPHAN_RC=$?
ORPHAN_ELAPSED=$(( $(date +%s) - ORPHAN_STARTED_AT ))
ORPHAN_ERRORS="$(printf '%s\n' "$ORPHAN_OUT" | jq -s '
  [.[] | select(.kind == "stream_error")] as $errors
  | ($errors | length) == 1
    and ($errors[0].reason | ascii_downcase
      | test("orphan|producer.*(gone|dead|missing|inactive|lost)|abandon"))')"
check "start-only generation without a producer fails explicitly in bounded time" \
  "$ORPHAN_ERRORS/$(( ORPHAN_RC != 0 ))/$(( ORPHAN_ELAPSED <= 3 ))" \
  "true/1/1"

# Producer shutdown publishes watch_end before it retires the lock. Force that
# ordering between the reader's journal sample and liveness sample: after the
# failed liveness observation, the reader must rescan and deliver the terminal
# record instead of misreporting a completed generation as orphaned.
TERMINAL_RACE_BRANCH="terminal-race"
TERMINAL_RACE_ID="watch-bbbbbbbbbbbbbbbbbbbbbbbb"
TERMINAL_RACE_LOG="$REPO/.git/pr-watch/$(pr_watch_branch_key "$TERMINAL_RACE_BRANCH").jsonl"
TERMINAL_RACE_LOCK="${TERMINAL_RACE_LOG%.jsonl}.lock"
TERMINAL_RACE_TOKEN="$(verdict_audit_process_start_token "$$")"
mkdir -p "$TERMINAL_RACE_LOCK"
jq -nc --arg id "$TERMINAL_RACE_ID" \
  '{kind:"watch_start",watch_id:$id}' > "$TERMINAL_RACE_LOG"
jq -nc --argjson pid "$$" --arg token "$TERMINAL_RACE_TOKEN" \
  --arg id "$TERMINAL_RACE_ID" \
  '{schema:1,pid:$pid,start_token:$token,watch_id:$id,ready:true}' \
  > "$TERMINAL_RACE_LOCK/owner.json"

TERMINAL_RACE_BIN="$TMP/terminal-race-bin"
TERMINAL_RACE_REAL_PERL="$(command -v perl)"
TERMINAL_RACE_ONCE="$TMP/terminal-race.once"
TERMINAL_RACE_BLOCKED="$TMP/terminal-race.blocked"
TERMINAL_RACE_RELEASE="$TMP/terminal-race.release"
mkdir -p "$TERMINAL_RACE_BIN"
cat > "$TERMINAL_RACE_BIN/perl" <<'EOF'
#!/usr/bin/env bash
joined="$*"
if [[ "$joined" == *'exit 1 unless @state && -d _ && !-l _'* \
   && ! -e "$TERMINAL_RACE_ONCE" ]]; then
  : > "$TERMINAL_RACE_ONCE"
  : > "$TERMINAL_RACE_BLOCKED"
  while [[ ! -e "$TERMINAL_RACE_RELEASE" ]]; do sleep 0.01; done
fi
exec "$TERMINAL_RACE_REAL_PERL" "$@"
EOF
chmod +x "$TERMINAL_RACE_BIN/perl"
PATH="$TERMINAL_RACE_BIN:$PATH" \
TERMINAL_RACE_REAL_PERL="$TERMINAL_RACE_REAL_PERL" \
TERMINAL_RACE_ONCE="$TERMINAL_RACE_ONCE" \
TERMINAL_RACE_BLOCKED="$TERMINAL_RACE_BLOCKED" \
TERMINAL_RACE_RELEASE="$TERMINAL_RACE_RELEASE" \
  bash "$STREAM" "$TERMINAL_RACE_LOG" 1 --watch-id "$TERMINAL_RACE_ID" \
  > "$TMP/terminal-race.out" 2> "$TMP/terminal-race.err" &
terminal_race_pid=$!
terminal_race_barrier=missed
for _ in {1..300}; do
  if [[ -e "$TERMINAL_RACE_BLOCKED" ]]; then
    terminal_race_barrier=hit
    break
  fi
  kill -0 "$terminal_race_pid" 2>/dev/null || break
  sleep 0.01
done
jq -nc --arg id "$TERMINAL_RACE_ID" \
  '{kind:"watch_end",watch_id:$id,reason:"normal complete"}' \
  >> "$TERMINAL_RACE_LOG"
printf 'retired\n' > "$TERMINAL_RACE_LOCK/owner.json"
: > "$TERMINAL_RACE_RELEASE"
terminal_race_timed_out=no
for _ in {1..300}; do
  kill -0 "$terminal_race_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$terminal_race_pid" 2>/dev/null; then
  terminal_race_timed_out=yes
  kill -TERM "$terminal_race_pid" 2>/dev/null || true
fi
wait "$terminal_race_pid"
TERMINAL_RACE_RC=$?
TERMINAL_RACE_RESULT="$(jq -sr '
  ([.[] | .kind] | join(",")) + "/"
  + (([.[] | select(.kind == "stream_error")] | length) | tostring)' \
  "$TMP/terminal-race.out" 2>/dev/null || printf invalid)"
check "terminal append racing lock retirement is delivered before orphan detection" \
  "$terminal_race_barrier/$terminal_race_timed_out/$TERMINAL_RACE_RESULT/$TERMINAL_RACE_RC" \
  "hit/no/watch_start,watch_end/0/0"

# Exercise the real signal boundary too. Either the producer publishes a
# watch_end before releasing its lock, or the consumer detects the now-orphaned
# generation and emits the same explicit error contract.
reset_state
SIGNAL_BRANCH="signal-orphan"
SIGNAL_ID="watch-eeeeeeeeeeeeeeeeeeeeeeee"
SIGNAL_LOG="$REPO/.git/pr-watch/$(pr_watch_branch_key "$SIGNAL_BRANCH").jsonl"
/bin/bash -c '
  cd "$1" || exit 1
  exec env PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 \
    PR_WATCH_MAX_LIFETIME=60 bash "$2" --branch "$3" --pr 42 --watch-id "$4"
' -- "$REPO" "$WATCHER" "$SIGNAL_BRANCH" "$SIGNAL_ID" \
  >"$TMP/signal-orphan-producer.out" 2>&1 &
SIGNAL_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  grep -q '"kind":"watch_start"' "$SIGNAL_LOG" 2>/dev/null && break
  sleep 0.1
done
kill -TERM "$SIGNAL_PID" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
         21 22 23 24 25 26 27 28 29 30; do
  kill -0 "$SIGNAL_PID" 2>/dev/null || break
  sleep 0.1
done
kill -KILL "$SIGNAL_PID" 2>/dev/null || true
wait "$SIGNAL_PID" 2>/dev/null || true
SIGNAL_STREAM_OUT="$(with_deadline 5 env PR_WATCH_STREAM_WAIT=2 \
  bash "$STREAM" "$SIGNAL_LOG" 1 --watch-id "$SIGNAL_ID")"
SIGNAL_STREAM_RC=$?
SIGNAL_TERMINAL="$(printf '%s\n' "$SIGNAL_STREAM_OUT" | jq -sr '
  ([.[] | select(.kind == "watch_end")] | length) as $ends
  | [.[] | select(.kind == "stream_error")] as $errors
  | if $ends == 1 then "watch_end"
    elif (($errors | length) == 1
          and ($errors[0].reason | ascii_downcase
            | test("orphan|producer.*(gone|dead|missing|inactive|lost)|abandon")))
    then "stream_error" else "missing" end')"
if [[ "$SIGNAL_TERMINAL" == watch_end ]]; then
  SIGNAL_TERMINAL_STATUS="$SIGNAL_STREAM_RC"
else
  SIGNAL_TERMINAL_STATUS="$(( SIGNAL_STREAM_RC != 0 ))"
fi
check "signalled producer leaves a terminally detectable generation" \
  "$SIGNAL_TERMINAL/$SIGNAL_TERMINAL_STATUS" \
  "$(if [[ "$SIGNAL_TERMINAL" == watch_end ]]; then printf 'watch_end/0'; else printf 'stream_error/1'; fi)"

# A consumer may be attached with the public one-hour poll ceiling. TERM must
# tear down the in-flight timer too; otherwise the shell exits while `sleep`
# remains reparented for the rest of that hour.
stream_term_reaps_long_poll() {
  local missing_log="$TMP/stream-term-long-poll.jsonl"
  local stream_pid sleep_pid="" sleep_token="" deadline
  local stream_state sleep_state sleep_ppid
  rm -f "$missing_log"
  PR_WATCH_STREAM_WAIT=3600 bash "$STREAM" "$missing_log" 3600 \
    >"$TMP/stream-term-long-poll.out" \
    2>"$TMP/stream-term-long-poll.err" &
  stream_pid=$!
  deadline=$(( SECONDS + 5 ))
  while (( SECONDS < deadline )); do
    sleep_pid="$(pgrep -P "$stream_pid" -x sleep 2>/dev/null | head -n 1)"
    [[ "$sleep_pid" =~ ^[1-9][0-9]*$ ]] && break
    kill -0 "$stream_pid" 2>/dev/null || break
    sleep 0.05
  done
  if [[ ! "$sleep_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" 2>/dev/null || true
    printf 'stream=never-waited sleep=missing'
    return
  fi
  sleep_token="$(verdict_audit_process_start_token "$sleep_pid" 2>/dev/null || true)"
  kill -TERM "$stream_pid" 2>/dev/null || true
  deadline=$(( SECONDS + 3 ))
  while (( SECONDS < deadline )); do
    kill -0 "$stream_pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$stream_pid" 2>/dev/null; then
    stream_state=alive
  else
    stream_state=dead
  fi
  if [[ -n "$sleep_token" \
     && "$(verdict_audit_process_start_token "$sleep_pid" 2>/dev/null || true)" \
        == "$sleep_token" ]]; then
    sleep_ppid="$(ps -o ppid= -p "$sleep_pid" 2>/dev/null | tr -d ' ')"
    sleep_state="alive-ppid-${sleep_ppid:-unknown}"
  else
    sleep_state=dead
  fi
  kill -KILL "$stream_pid" "$sleep_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
  printf 'stream=%s sleep=%s' "$stream_state" "$sleep_state"
}

check "TERM reaps the stream's one-hour poll child" \
  "$(stream_term_reaps_long_poll)" "stream=dead sleep=dead"

stream_test_pid_state() {  # pid start-token
  local pid="$1" token="$2" current_token
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ || -z "$token" ]]; then
    printf 'missing'
    return
  fi
  current_token="$(verdict_audit_process_start_token \
    "$pid" 2>/dev/null || true)"
  if [[ "$current_token" == "$token" ]]; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

stream_test_kill_identity() {  # pid start-token
  local pid="$1" token="$2"
  [[ "$(stream_test_pid_state "$pid" "$token")" == alive ]] || return 0
  kill -KILL "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ "$(stream_test_pid_state "$pid" "$token")" == dead ]] && return 0
    /bin/sleep 0.05
  done
}

# Bash can run a pending signal trap after starting an asynchronous command but
# before the following PID assignment. Stop on that exact DEBUG boundary: the
# stream must still own and reap the child it has already forked.
STREAM_GAP_ENV="$TMP/stream-sleep-gap-env.sh"
STREAM_GAP_CHILD_RECORD="$TMP/stream-sleep-gap.child"
STREAM_GAP_BARRIER="$TMP/stream-sleep-gap.barrier"
STREAM_GAP_LOG="$TMP/stream-sleep-gap-missing.jsonl"
cat > "$STREAM_GAP_ENV" <<'STREAM_GAP_ENV_EOF'
stream_sleep_gap_debug() {
  [[ "${FUNCNAME[1]:-}" == stream_sleep ]] || return 0
  case "$BASH_COMMAND" in
    'stream_sleep_pid=$!')
      stream_gap_child_pid="$!"
      trap - DEBUG
      stream_gap_child_token="$(verdict_audit_process_start_token \
        "$stream_gap_child_pid" 2>/dev/null || true)"
      printf '%s %s\n' "$stream_gap_child_pid" "$stream_gap_child_token" \
        > "$STREAM_GAP_CHILD_RECORD"
      : > "$STREAM_GAP_BARRIER"
      kill -TERM "$$"
      ;;
  esac
}
set -T
trap stream_sleep_gap_debug DEBUG
STREAM_GAP_ENV_EOF
rm -f "$STREAM_GAP_CHILD_RECORD" "$STREAM_GAP_BARRIER" "$STREAM_GAP_LOG"
BASH_ENV="$STREAM_GAP_ENV" \
STREAM_GAP_CHILD_RECORD="$STREAM_GAP_CHILD_RECORD" \
STREAM_GAP_BARRIER="$STREAM_GAP_BARRIER" \
PR_WATCH_STREAM_WAIT=3600 \
  bash "$STREAM" "$STREAM_GAP_LOG" 3600 \
  > "$TMP/stream-sleep-gap.out" 2> "$TMP/stream-sleep-gap.err" &
STREAM_GAP_PID=$!
( /bin/sleep 3; kill -KILL "$STREAM_GAP_PID" 2>/dev/null || true ) \
  >/dev/null 2>&1 &
STREAM_GAP_WATCHDOG=$!
wait "$STREAM_GAP_PID" 2>/dev/null
STREAM_GAP_RC=$?
kill "$STREAM_GAP_WATCHDOG" 2>/dev/null || true
wait "$STREAM_GAP_WATCHDOG" 2>/dev/null || true
STREAM_GAP_CHILD_PID=""
STREAM_GAP_CHILD_TOKEN=""
read -r STREAM_GAP_CHILD_PID STREAM_GAP_CHILD_TOKEN \
  < "$STREAM_GAP_CHILD_RECORD" 2>/dev/null || true
STREAM_GAP_BARRIER_STATE=missed
[[ -e "$STREAM_GAP_BARRIER" ]] && STREAM_GAP_BARRIER_STATE=hit
STREAM_GAP_CHILD_STATE="$(stream_test_pid_state \
  "$STREAM_GAP_CHILD_PID" "$STREAM_GAP_CHILD_TOKEN")"
stream_test_kill_identity "$STREAM_GAP_CHILD_PID" "$STREAM_GAP_CHILD_TOKEN"
check "TERM at the stream sleep fork-to-PID gap reaps the forked child" \
  "barrier=$STREAM_GAP_BARRIER_STATE rc=$STREAM_GAP_RC child=$STREAM_GAP_CHILD_STATE" \
  "barrier=hit rc=143 child=dead"

# A PATH-provided timer can be a wrapper with its own child. Signal teardown
# owns the complete timer process group, not only the wrapper PID recorded by
# Bash. Trigger TERM after the assignment and after both identities are stable.
STREAM_WRAPPER_BIN="$TMP/stream-sleep-wrapper-bin"
STREAM_WRAPPER_ENV="$TMP/stream-sleep-wrapper-env.sh"
STREAM_WRAPPER_RECORD="$TMP/stream-sleep-wrapper.record"
STREAM_WRAPPER_PID_FILE="$TMP/stream-sleep-wrapper.pid"
STREAM_WRAPPER_DESC_PID_FILE="$TMP/stream-sleep-wrapper-descendant.pid"
STREAM_WRAPPER_READY="$TMP/stream-sleep-wrapper.ready"
STREAM_WRAPPER_BARRIER="$TMP/stream-sleep-wrapper.barrier"
STREAM_WRAPPER_LOG="$TMP/stream-sleep-wrapper-missing.jsonl"
mkdir -p "$STREAM_WRAPPER_BIN"
cat > "$STREAM_WRAPPER_BIN/sleep" <<'STREAM_WRAPPER_EOF'
#!/usr/bin/env bash
trap '' TERM INT
(
  exec perl -e '
    $SIG{TERM} = "IGNORE";
    $SIG{INT} = "IGNORE";
    while (1) { select undef, undef, undef, 1; }
  '
) &
stream_wrapper_descendant=$!
printf '%s\n' "$$" > "$STREAM_WRAPPER_PID_FILE"
printf '%s\n' "$stream_wrapper_descendant" > "$STREAM_WRAPPER_DESC_PID_FILE"
: > "$STREAM_WRAPPER_READY"
wait "$stream_wrapper_descendant"
STREAM_WRAPPER_EOF
chmod +x "$STREAM_WRAPPER_BIN/sleep"
cat > "$STREAM_WRAPPER_ENV" <<'STREAM_WRAPPER_ENV_EOF'
stream_sleep_wrapper_debug() {
  [[ "${FUNCNAME[1]:-}" == stream_sleep ]] || return 0
  case "$BASH_COMMAND" in
    'wait "$stream_sleep_pid"'*)
      trap - DEBUG
      stream_wrapper_deadline=$(( SECONDS + 3 ))
      while (( SECONDS < stream_wrapper_deadline )); do
        [[ -e "$STREAM_WRAPPER_READY" \
           && -s "$STREAM_WRAPPER_PID_FILE" \
           && -s "$STREAM_WRAPPER_DESC_PID_FILE" ]] && break
        /bin/sleep 0.01
      done
      stream_wrapper_pid="$(cat "$STREAM_WRAPPER_PID_FILE" 2>/dev/null || true)"
      stream_wrapper_descendant_pid="$(cat \
        "$STREAM_WRAPPER_DESC_PID_FILE" 2>/dev/null || true)"
      stream_wrapper_token="$(verdict_audit_process_start_token \
        "$stream_wrapper_pid" 2>/dev/null || true)"
      stream_wrapper_descendant_token="$(verdict_audit_process_start_token \
        "$stream_wrapper_descendant_pid" 2>/dev/null || true)"
      printf '%s %s %s %s\n' \
        "$stream_wrapper_pid" "$stream_wrapper_token" \
        "$stream_wrapper_descendant_pid" "$stream_wrapper_descendant_token" \
        > "$STREAM_WRAPPER_RECORD"
      : > "$STREAM_WRAPPER_BARRIER"
      kill -TERM "$$"
      ;;
  esac
}
set -T
trap stream_sleep_wrapper_debug DEBUG
STREAM_WRAPPER_ENV_EOF
rm -f "$STREAM_WRAPPER_RECORD" "$STREAM_WRAPPER_PID_FILE" \
  "$STREAM_WRAPPER_DESC_PID_FILE" "$STREAM_WRAPPER_READY" \
  "$STREAM_WRAPPER_BARRIER" "$STREAM_WRAPPER_LOG"
PATH="$STREAM_WRAPPER_BIN:$PATH" \
BASH_ENV="$STREAM_WRAPPER_ENV" \
STREAM_WRAPPER_RECORD="$STREAM_WRAPPER_RECORD" \
STREAM_WRAPPER_PID_FILE="$STREAM_WRAPPER_PID_FILE" \
STREAM_WRAPPER_DESC_PID_FILE="$STREAM_WRAPPER_DESC_PID_FILE" \
STREAM_WRAPPER_READY="$STREAM_WRAPPER_READY" \
STREAM_WRAPPER_BARRIER="$STREAM_WRAPPER_BARRIER" \
PR_WATCH_STREAM_WAIT=3600 \
  bash "$STREAM" "$STREAM_WRAPPER_LOG" 3600 \
  > "$TMP/stream-sleep-wrapper.out" \
  2> "$TMP/stream-sleep-wrapper.err" &
STREAM_WRAPPER_STREAM_PID=$!
( /bin/sleep 5; kill -KILL "$STREAM_WRAPPER_STREAM_PID" 2>/dev/null || true ) \
  >/dev/null 2>&1 &
STREAM_WRAPPER_WATCHDOG=$!
wait "$STREAM_WRAPPER_STREAM_PID" 2>/dev/null
STREAM_WRAPPER_RC=$?
kill "$STREAM_WRAPPER_WATCHDOG" 2>/dev/null || true
wait "$STREAM_WRAPPER_WATCHDOG" 2>/dev/null || true
STREAM_WRAPPER_PID=""
STREAM_WRAPPER_TOKEN=""
STREAM_WRAPPER_DESC_PID=""
STREAM_WRAPPER_DESC_TOKEN=""
read -r STREAM_WRAPPER_PID STREAM_WRAPPER_TOKEN \
  STREAM_WRAPPER_DESC_PID STREAM_WRAPPER_DESC_TOKEN \
  < "$STREAM_WRAPPER_RECORD" 2>/dev/null || true
STREAM_WRAPPER_BARRIER_STATE=missed
[[ -e "$STREAM_WRAPPER_BARRIER" ]] && STREAM_WRAPPER_BARRIER_STATE=hit
STREAM_WRAPPER_STATE="$(stream_test_pid_state \
  "$STREAM_WRAPPER_PID" "$STREAM_WRAPPER_TOKEN")"
STREAM_WRAPPER_DESC_STATE="$(stream_test_pid_state \
  "$STREAM_WRAPPER_DESC_PID" "$STREAM_WRAPPER_DESC_TOKEN")"
stream_test_kill_identity "$STREAM_WRAPPER_PID" "$STREAM_WRAPPER_TOKEN"
stream_test_kill_identity "$STREAM_WRAPPER_DESC_PID" "$STREAM_WRAPPER_DESC_TOKEN"
check "TERM reaps a stream sleep wrapper and its background descendant" \
  "barrier=$STREAM_WRAPPER_BARRIER_STATE rc=$STREAM_WRAPPER_RC wrapper=$STREAM_WRAPPER_STATE descendant=$STREAM_WRAPPER_DESC_STATE" \
  "barrier=hit rc=143 wrapper=dead descendant=dead"

echo
echo "## Stream reset detection"
TRUNC_LOG="$TMP/truncated.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"trunc-generation"}' \
  '{"kind":"check","watch_id":"trunc-generation","bucket":"pass"}' > "$TRUNC_LOG"
( sleep 2; : > "$TRUNC_LOG" ) &
TRUNC_OUT="$(with_deadline 9 bash "$STREAM" "$TRUNC_LOG" 1)"
TRUNC_RC=$?
wait
check "byte truncation emits a machine-readable stream_error" \
  "$(printf '%s\n' "$TRUNC_OUT" | jq -r 'select(.kind == "stream_error") | .reason')" "log_truncated"
check "byte truncation exits nonzero" "$TRUNC_RC" "1"

REPLACE_LOG="$TMP/replaced.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"replace-generation"}' \
  '{"kind":"check","watch_id":"replace-generation","bucket":"pass"}' > "$REPLACE_LOG"
( sleep 2
  mv "$REPLACE_LOG" "$REPLACE_LOG.old"
  printf '%s\n' \
    '{"kind":"watch_start","watch_id":"replace-generation"}' \
    '{"kind":"watch_end","watch_id":"replace-generation","reason":"replacement"}' > "$REPLACE_LOG"
) &
REPLACE_OUT="$(with_deadline 9 bash "$STREAM" "$REPLACE_LOG" 1)"
REPLACE_RC=$?
wait
check "log replacement emits a machine-readable stream_error" \
  "$(printf '%s\n' "$REPLACE_OUT" | jq -r 'select(.kind == "stream_error") | .reason')" "log_replaced"
check "log replacement exits nonzero" "$REPLACE_RC" "1"

SYMLINK_TARGET="$TMP/symlink-target.jsonl"
SYMLINK_LOG="$TMP/symlink-stream.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"symlink-generation"}' \
  '{"kind":"watch_end","watch_id":"symlink-generation","reason":"symlink"}' \
  > "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_LOG"
SYMLINK_OUT="$(with_deadline 5 bash "$STREAM" "$SYMLINK_LOG" 1)"
SYMLINK_RC=$?
check "stream rejects a symlink instead of following its target" \
  "$(printf '%s\n' "$SYMLINK_OUT" | jq -r 'select(.kind == "stream_error") | .reason')/$SYMLINK_RC" \
  "not_regular/1"

# Replace the accepted pathname immediately before the next size read. A reader
# that reopens the name for wc/sed blocks on the FIFO; a stable opened inode
# detects the pathname change without ever opening the replacement.
FIFO_SWAP_LOG="$TMP/fifo-swap.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"fifo-swap-generation"}' \
  > "$FIFO_SWAP_LOG"
(
  sleep 2
  mv "$FIFO_SWAP_LOG" "$FIFO_SWAP_LOG.old"
  mkfifo "$FIFO_SWAP_LOG"
  sleep 5
  perl -MFcntl=:DEFAULT -e '
    sysopen(my $fh, $ARGV[0], O_RDWR | O_NONBLOCK) or exit 0;
    syswrite($fh, "release\n");
  ' "$FIFO_SWAP_LOG"
) & FIFO_SWAP_WRITER=$!
FIFO_SWAP_OUT="$(with_deadline 6 bash "$STREAM" "$FIFO_SWAP_LOG" 1)"
FIFO_SWAP_RC=$?
wait "$FIFO_SWAP_WRITER" 2>/dev/null || true
check "stream never reopens a FIFO replacement while following" \
  "$(printf '%s\n' "$FIFO_SWAP_OUT" | jq -r 'select(.kind == "stream_error") | .reason')/$FIFO_SWAP_RC" \
  "log_replaced/1"

REGRESS_LOG="$TMP/regressed.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"regress-generation"}' \
  '{"kind":"check","watch_id":"regress-generation","bucket":"pass"}' \
  '{"kind":"check","watch_id":"regress-generation","bucket":"pass"}' > "$REGRESS_LOG"
( sleep 2
  jq -nc --arg body "$(printf '%0500d' 1)" \
    '{kind:"check",watch_id:"regress-generation",body:$body}' > "$REGRESS_LOG"
) &
REGRESS_OUT="$(with_deadline 9 bash "$STREAM" "$REGRESS_LOG" 1)"
REGRESS_RC=$?
wait
check "line-count regression is detected even when bytes grow" \
  "$(printf '%s\n' "$REGRESS_OUT" | jq -r 'select(.kind == "stream_error") | .reason')" "line_regression"
check "line-count regression exits nonzero" "$REGRESS_RC" "1"

echo
echo "## Bounded replay"
CAP_LOG="$TMP/capped.jsonl"
printf '%s\n' '{"kind":"watch_start","watch_id":"cap-generation"}' > "$CAP_LOG"
for n in 1 2 3 4 5 6 7 8; do
  jq -nc --arg id "check-$n" --arg body "$(printf '%0180d' "$n")" \
    '{kind:"check",watch_id:"cap-generation",id:$id,body:$body}' >> "$CAP_LOG"
done
( sleep 2; printf '%s\n' \
    '{"kind":"watch_end","watch_id":"cap-generation","reason":"cap complete"}' >> "$CAP_LOG" ) &
CAP_OUT="$(with_deadline 20 env PR_WATCH_STREAM_MAX_EVENTS=3 \
  PR_WATCH_STREAM_MAX_BYTES=700 bash "$STREAM" "$CAP_LOG" 1)"
CAP_RC=$?
wait
check "bounded replay reports omitted event count" \
  "$(printf '%s\n' "$CAP_OUT" | jq -r 'select(.kind == "stream_omitted") | (.omitted_events > 0)')" "true"
check "bounded replay reports omitted byte count" \
  "$(printf '%s\n' "$CAP_OUT" | jq -r 'select(.kind == "stream_omitted") | (.omitted_bytes > 0)')" "true"
check "initial replay retains at most the configured event count" \
  "$(printf '%s\n' "$CAP_OUT" | jq -s \
      '[.[] | select(.kind == "check")] | length <= 3')" "true"
check "bounded replay summary retains its terminal reason and exits 0" \
  "$(printf '%s\n' "$CAP_OUT" | jq -r \
      'select(.kind == "stream_omitted" and .scope == "lifetime") | .terminal.reason')/$CAP_RC" \
  "cap complete/0"

LIFETIME_LOG="$REPO/.git/lifetime-stream.jsonl"
jq -nc '{kind:"watch_start",watch_id:"lifetime-generation"}' > "$LIFETIME_LOG"
(
  sleep 2
  jq -nc '{kind:"check",watch_id:"lifetime-generation",name:"batch-1-a"}' >> "$LIFETIME_LOG"
  jq -nc '{kind:"check",watch_id:"lifetime-generation",name:"batch-1-b"}' >> "$LIFETIME_LOG"
  sleep 2
  jq -nc '{kind:"check",watch_id:"lifetime-generation",name:"batch-2-a"}' >> "$LIFETIME_LOG"
  jq -nc '{kind:"check",watch_id:"lifetime-generation",name:"batch-2-b"}' >> "$LIFETIME_LOG"
  sleep 2
  jq -nc '{kind:"check",watch_id:"lifetime-generation",name:"batch-3-a"}' >> "$LIFETIME_LOG"
  jq -nc '{kind:"watch_end",watch_id:"lifetime-generation",reason:"lifetime complete"}' >> "$LIFETIME_LOG"
) &
LIFETIME_OUT="$(with_deadline 20 env PR_WATCH_STREAM_MAX_EVENTS=4 \
  PR_WATCH_STREAM_MAX_BYTES=900 bash "$STREAM" "$LIFETIME_LOG" 1 \
  --watch-id lifetime-generation)"
LIFETIME_RC=$?
wait
LIFETIME_LINES="$(printf '%s\n' "$LIFETIME_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
LIFETIME_BYTES="$(LC_ALL=C printf '%s\n' "$LIFETIME_OUT" | wc -c | tr -d ' ')"
LIFETIME_SUMMARIES="$(printf '%s\n' "$LIFETIME_OUT" | jq -s \
  '[.[] | select(.kind == "stream_omitted" and .scope == "lifetime"
                 and .terminal_output == true)] | length')"
LIFETIME_AFTER_SUMMARY="$(printf '%s\n' "$LIFETIME_OUT" | jq -sr '
  reduce .[] as $event ({closed:false,after:0};
    if .closed then .after += 1
    elif ($event.kind == "stream_omitted" and $event.scope == "lifetime")
    then .closed = true else . end) | .after')"
check "stream lifetime caps do not reset across appended batches" \
  "$(( LIFETIME_LINES <= 4 && LIFETIME_BYTES <= 900 ))/$LIFETIME_SUMMARIES/$LIFETIME_AFTER_SUMMARY/$LIFETIME_RC" \
  "1/1/0/0"

echo
echo "## Multi-ref attachment"
ATTACH="$REPO_ROOT/.agents/watch/pr-watch-attach.sh"
ATTACH_DIR="$REPO/.git/pr-watch"
mkdir -p "$ATTACH_DIR"
attach_claim_path() {  # unique-fixture-label [slot]
  local digest
  digest="$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')"
  printf '%s/attach-%s.json.claim.%s' \
    "$ATTACH_DIR" "$digest" "${2:-0}"
}
ATTACH_ONE_ID="watch-aaaaaaaaaaaaaaaaaaaaaaaa"
ATTACH_TWO_ID="watch-bbbbbbbbbbbbbbbbbbbbbbbb"
ATTACH_ONE_LOG="$ATTACH_DIR/$(pr_watch_branch_key attach-one).jsonl"
ATTACH_TWO_LOG="$ATTACH_DIR/$(pr_watch_branch_key attach-two).jsonl"
jq -nc --arg id "$ATTACH_ONE_ID" '{kind:"watch_start",watch_id:$id}' > "$ATTACH_ONE_LOG"
jq -nc --arg id "$ATTACH_ONE_ID" '{kind:"watch_end",watch_id:$id,reason:"one done"}' >> "$ATTACH_ONE_LOG"
jq -nc --arg id "$ATTACH_TWO_ID" '{kind:"watch_start",watch_id:$id}' > "$ATTACH_TWO_LOG"
jq -nc --arg id "$ATTACH_TWO_ID" '{kind:"watch_end",watch_id:$id,reason:"two done"}' >> "$ATTACH_TWO_LOG"
ATTACH_MANIFEST="$(attach_claim_path direct-attach)"
jq -nc --arg one "$ATTACH_ONE_LOG" --arg two "$ATTACH_TWO_LOG" \
  --arg one_id "$ATTACH_ONE_ID" --arg two_id "$ATTACH_TWO_ID" '
  {schema:1,omitted_refs:0,entries:[
    {remote_ref:"refs/heads/attach-one",branch:"attach-one",watch_id:$one_id,event_log:$one},
    {remote_ref:"refs/heads/attach-two",branch:"attach-two",watch_id:$two_id,event_log:$two}]}' \
  > "$ATTACH_MANIFEST"
ATTACH_OUT="$(bash "$ATTACH" "$ATTACH_MANIFEST")"
ATTACH_RC=$?
check "one bounded consumer drains both explicit generations" \
  "$(printf '%s\n' "$ATTACH_OUT" | jq -s --arg one "$ATTACH_ONE_ID" --arg two "$ATTACH_TWO_ID" \
      '[.[] | select(.kind == "watch_end") | .watch_id] | sort == ([$one,$two] | sort)')/$ATTACH_RC" \
  "true/0"
bash "$ATTACH" "$ATTACH_MANIFEST" >/dev/null 2>&1
ATTACH_REPLAY_RC=$?
check "attachment manifest is one-shot" "$ATTACH_REPLAY_RC" "1"

# A claim remains the only retry authority until every represented stream has
# crossed fork, exec, and its explicit ready publication. Force each launch
# boundary to fail before readiness; no failure may turn the exact JSON claim
# into a consumed tombstone.
ATTACH_LAUNCH_ROOT="$TMP/attach-launch-tooling"
ATTACH_LAUNCH_BIN="$TMP/attach-launch-bin"
ATTACH_LAUNCH_ENV="$TMP/attach-launch.env"
ATTACH_LAUNCH_MARKER="$TMP/attach-launch"
ATTACH_LAUNCH="$ATTACH_LAUNCH_ROOT/.agents/watch/pr-watch-attach.sh"
ATTACH_LAUNCH_STREAM="$ATTACH_LAUNCH_ROOT/.agents/watch/pr-watch-stream.sh"
ATTACH_LAUNCH_LOG="$ATTACH_DIR/$(pr_watch_branch_key attach-launch).jsonl"
mkdir -p "$ATTACH_LAUNCH_ROOT/.agents/watch" \
  "$ATTACH_LAUNCH_ROOT/.agents/lib" "$ATTACH_LAUNCH_BIN"
cp "$ATTACH" "$ATTACH_LAUNCH"
cp "$STREAM" "$ATTACH_LAUNCH_STREAM"
cp "$REPO_ROOT/.agents/lib/pr-watch-state.sh" \
  "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
  "$ATTACH_LAUNCH_ROOT/.agents/lib/"
jq -nc '{kind:"watch_start",watch_id:"watch-dddddddddddddddddddddddd"}' \
  > "$ATTACH_LAUNCH_LOG"
jq -nc '{kind:"watch_end",watch_id:"watch-dddddddddddddddddddddddd",
         reason:"launch fixture complete"}' >> "$ATTACH_LAUNCH_LOG"

attach_launch_manifest() {  # unique-fixture-label
  local launch_manifest
  launch_manifest="$(attach_claim_path "$1")"
  jq -nc --arg log "$ATTACH_LAUNCH_LOG" '
    {schema:1,omitted_refs:0,entries:[
      {remote_ref:"refs/heads/attach-launch",branch:"attach-launch",
       watch_id:"watch-dddddddddddddddddddddddd",event_log:$log}]}' \
    > "$launch_manifest"
  printf '%s' "$launch_manifest"
}

attach_claim_state() {  # claimed-manifest
  if jq -e 'type == "object" and .schema == 1' "$1" >/dev/null 2>&1; then
    printf json
  elif grep -q '^consumed:' "$1" 2>/dev/null; then
    printf consumed
  else
    printf invalid
  fi
}

cat > "$ATTACH_LAUNCH_BIN/perl" <<'ATTACH_LAUNCH_PERL_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == -MIO::Select \
   && -n "${ATTACH_LAUNCH_FAILURE:-}" ]]; then
  serializer_modules=()
  while [[ "${1:-}" == -M* ]]; do
    serializer_modules+=("$1")
    shift
  done
  [[ "${1:-}" == -e && -n "${2:-}" ]] || exec "$ATTACH_LAUNCH_REAL_PERL" \
    "${serializer_modules[@]}" "$@"
  serializer="$2"
  shift 2
  case "$ATTACH_LAUNCH_FAILURE" in
    fork)
      original='      my $pid = fork();'
      replacement='      my $pid = undef;'
      ;;
    sigkill)
      original='    my $selector = IO::Select->new();'
      replacement='    kill(q{KILL}, $$);
    my $selector = IO::Select->new();'
      ;;
    *) exit 126 ;;
  esac
  serializer="$(printf '%s' "$serializer" | "$ATTACH_LAUNCH_REAL_PERL" -0777 -e '
    my ($needle, $replacement) = @ARGV;
    my $source = <STDIN>;
    my $offset = index($source, $needle);
    exit 126 if $offset < 0;
    substr($source, $offset, length($needle), $replacement);
    print $source;
  ' "$original" "$replacement")" || exit $?
  exec "$ATTACH_LAUNCH_REAL_PERL" "${serializer_modules[@]}" \
    -e "$serializer" "$@"
fi
exec "$ATTACH_LAUNCH_REAL_PERL" "$@"
ATTACH_LAUNCH_PERL_EOF
chmod +x "$ATTACH_LAUNCH_BIN/perl"
printf '%s\n' \
  'set -T' \
  '_attach_launch_debug() {' \
  '  [[ "$1" == PR_WATCH_STREAM_MAX_EVENTS=*perl* ]] || return 0' \
  '  trap - DEBUG' \
  '  export PATH="$ATTACH_LAUNCH_BIN:$PATH"' \
  '}' \
  'trap '\''_attach_launch_debug "$BASH_COMMAND"'\'' DEBUG' \
  > "$ATTACH_LAUNCH_ENV"

attach_failed_launch_is_retryable() {  # fork|sigkill
  local failure="$1" launch_manifest first_rc retry_rc
  local first_state retry_state claim_state
  launch_manifest="$(attach_launch_manifest "launch-${failure}")"
  with_deadline 5 env BASH_ENV="$ATTACH_LAUNCH_ENV" \
    ATTACH_LAUNCH_BIN="$ATTACH_LAUNCH_BIN" \
    ATTACH_LAUNCH_REAL_PERL="$(command -v perl)" \
    ATTACH_LAUNCH_FAILURE="$failure" \
    bash "$ATTACH_LAUNCH" "$launch_manifest" \
    > "${ATTACH_LAUNCH_MARKER}.${failure}.out" \
    2> "${ATTACH_LAUNCH_MARKER}.${failure}.err"
  first_rc=$?
  (( first_rc == 0 )) && first_state=passed || first_state=failed
  claim_state="$(attach_claim_state "$launch_manifest")"
  with_deadline 5 bash "$ATTACH_LAUNCH" "$launch_manifest" \
    > "${ATTACH_LAUNCH_MARKER}.${failure}.retry.out" \
    2> "${ATTACH_LAUNCH_MARKER}.${failure}.retry.err"
  retry_rc=$?
  (( retry_rc == 0 )) && retry_state=passed || retry_state=failed
  printf 'first=%s claim=%s retry=%s' \
    "$first_state" "$claim_state" "$retry_state"
}

check "serializer fork failure preserves retry authority" \
  "$(attach_failed_launch_is_retryable fork)" \
  "first=failed claim=json retry=passed"

check "serializer SIGKILL before child launch preserves retry authority" \
  "$(attach_failed_launch_is_retryable sigkill)" \
  "first=failed claim=json retry=passed"

ATTACH_EXEC_MANIFEST="$(attach_launch_manifest launch-exec)"
mv "$ATTACH_LAUNCH_STREAM" "${ATTACH_LAUNCH_STREAM}.unavailable"
with_deadline 5 bash "$ATTACH_LAUNCH" "$ATTACH_EXEC_MANIFEST" \
  > "${ATTACH_LAUNCH_MARKER}.exec.out" \
  2> "${ATTACH_LAUNCH_MARKER}.exec.err"
ATTACH_EXEC_FIRST_RC=$?
mv "${ATTACH_LAUNCH_STREAM}.unavailable" "$ATTACH_LAUNCH_STREAM"
ATTACH_EXEC_CLAIM_STATE="$(attach_claim_state "$ATTACH_EXEC_MANIFEST")"
with_deadline 5 bash "$ATTACH_LAUNCH" "$ATTACH_EXEC_MANIFEST" \
  > "${ATTACH_LAUNCH_MARKER}.exec.retry.out" \
  2> "${ATTACH_LAUNCH_MARKER}.exec.retry.err"
ATTACH_EXEC_RETRY_RC=$?
if (( ATTACH_EXEC_FIRST_RC != 0 && ATTACH_EXEC_RETRY_RC == 0 )); then
  ATTACH_EXEC_RESULT="first=failed claim=$ATTACH_EXEC_CLAIM_STATE retry=passed"
else
  ATTACH_EXEC_RESULT="first=$ATTACH_EXEC_FIRST_RC claim=$ATTACH_EXEC_CLAIM_STATE retry=$ATTACH_EXEC_RETRY_RC"
fi
check "stream exec/ready failure preserves retry authority" \
  "$ATTACH_EXEC_RESULT" "first=failed claim=json retry=passed"

# A stream that has published readiness owns the still-JSON claim lease across
# serializer death. A concurrent retry may inspect the claim, but it must not
# fork a duplicate stream. Once the live stream releases its inherited lease,
# the same exact claim becomes retryable and can be consumed normally.
ATTACH_LEASE_ROOT="$TMP/attach-lease-tooling"
ATTACH_LEASE_BIN="$TMP/attach-lease-bin"
ATTACH_LEASE_ENV="$TMP/attach-lease.env"
ATTACH_LEASE_MARKER="$TMP/attach-lease"
ATTACH_LEASE="$ATTACH_LEASE_ROOT/.agents/watch/pr-watch-attach.sh"
ATTACH_LEASE_STREAM="$ATTACH_LEASE_ROOT/.agents/watch/pr-watch-stream.sh"
ATTACH_LEASE_MANIFEST="$(attach_launch_manifest launch-lease)"
mkdir -p "$ATTACH_LEASE_ROOT/.agents/watch" \
  "$ATTACH_LEASE_ROOT/.agents/lib" "$ATTACH_LEASE_BIN"
cp "$ATTACH" "$ATTACH_LEASE"
cp "$STREAM" "${ATTACH_LEASE_STREAM}.real"
cp "$REPO_ROOT/.agents/lib/pr-watch-state.sh" \
  "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
  "$ATTACH_LEASE_ROOT/.agents/lib/"
mkfifo "${ATTACH_LEASE_MARKER}.release" "${ATTACH_LEASE_MARKER}.released"
cat > "$ATTACH_LEASE_STREAM" <<'ATTACH_LEASE_STREAM_EOF'
#!/usr/bin/env bash
set -uo pipefail
ready_fd=""
while (( $# )); do
  case "$1" in
    --ready-fd)
      ready_fd="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ "$ready_fd" == 4 ]] || exit 2
printf '%s\n' "$$" >> "${ATTACH_LEASE_MARKER}.launches"
printf 'ready\n' >&4 || exit 1
exec 4>&-
IFS= read -r release < "${ATTACH_LEASE_MARKER}.release" || exit 1
[[ "$release" == release ]] || exit 1
exec 7> "${ATTACH_LEASE_MARKER}.released"
exec 8>&-
printf 'released\n' >&7
exec 7>&-
if [[ "${ATTACH_LEASE_EMIT_AFTER_RELEASE:-0}" == 1 ]]; then
  trap '' PIPE
  printf '%s\n' \
    '{"kind":"check","watch_id":"watch-dddddddddddddddddddddddd","name":"drain-event"}' \
    || true
fi
ATTACH_LEASE_STREAM_EOF
chmod +x "$ATTACH_LEASE_STREAM"
cp "$ATTACH_LEASE_STREAM" "${ATTACH_LEASE_STREAM}.blocked"
cat > "$ATTACH_LEASE_BIN/perl" <<'ATTACH_LEASE_PERL_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == -MIO::Select \
   && -n "${ATTACH_LEASE_MARKER:-}" ]]; then
  serializer_modules=()
  while [[ "${1:-}" == -M* ]]; do
    serializer_modules+=("$1")
    shift
  done
  [[ "${1:-}" == -e && -n "${2:-}" ]] || exec "$ATTACH_LEASE_REAL_PERL" \
    "${serializer_modules[@]}" "$@"
  serializer="$2"
  shift 2
  relay_probe_order=""
  case "${ATTACH_LEASE_KILL_POINT:-}" in
    before_publish) original='    publish_tombstone();' ;;
    before_drain) original='    while ($selector->count) {' ;;
    after_drain)
      original='    write_all($drained_output);'
      if [[ "$serializer" != *"$original"* ]]; then
        original='    exit($stopping || $status);'
      fi
      ;;
    relay_ready)
      original='    await_delivery_ack();'
      relay_probe_order=before
      if [[ "$serializer" != *"$original"* ]]; then
        original='    publish_tombstone();'
        relay_probe_order=after
      fi
      ;;
    *) exit 126 ;;
  esac
  if [[ -n "$relay_probe_order" ]]; then
    relay_probe='    open(my $delivery_probe, q{>}, $ENV{ATTACH_RELAY_SERIALIZER_READY}) or exit 125;
    print {$delivery_probe} "ready\n"; close($delivery_probe) or exit 125;'
    if [[ "$relay_probe_order" == before ]]; then
      replacement="$relay_probe
$original"
    else
      replacement="$original
$relay_probe"
    fi
  else
    replacement='    open(my $launch_probe, q{>}, $ENV{ATTACH_LEASE_MARKER} . q{.serializer}) or exit 125;
    print {$launch_probe} "$$\n"; close($launch_probe) or exit 125;
    kill(q{KILL}, $$);
    '"$original"
  fi
  serializer="$(printf '%s' "$serializer" | "$ATTACH_LEASE_REAL_PERL" -0777 -e '
    my ($needle, $replacement) = @ARGV;
    my $source = <STDIN>;
    my $offset = index($source, $needle);
    exit 126 if $offset < 0;
    substr($source, $offset, length($needle), $replacement);
    print $source;
  ' "$original" "$replacement")" || exit $?
  exec "$ATTACH_LEASE_REAL_PERL" "${serializer_modules[@]}" \
    -e "$serializer" "$@"
fi
exec "$ATTACH_LEASE_REAL_PERL" "$@"
ATTACH_LEASE_PERL_EOF
chmod +x "$ATTACH_LEASE_BIN/perl"
printf '%s\n' \
  'set -T' \
  '_attach_lease_debug() {' \
  '  [[ "$1" == PR_WATCH_STREAM_MAX_EVENTS=*perl* ]] || return 0' \
  '  trap - DEBUG' \
  '  export PATH="$ATTACH_LEASE_BIN:$PATH"' \
  '}' \
  'trap '\''_attach_lease_debug "$BASH_COMMAND"'\'' DEBUG' \
  > "$ATTACH_LEASE_ENV"
with_deadline 5 env BASH_ENV="$ATTACH_LEASE_ENV" \
  ATTACH_LEASE_BIN="$ATTACH_LEASE_BIN" \
  ATTACH_LEASE_REAL_PERL="$(command -v perl)" \
  ATTACH_LEASE_MARKER="$ATTACH_LEASE_MARKER" \
  ATTACH_LEASE_KILL_POINT=before_drain \
  bash "$ATTACH_LEASE" "$ATTACH_LEASE_MANIFEST" \
  > "${ATTACH_LEASE_MARKER}.first.out" \
  2> "${ATTACH_LEASE_MARKER}.first.err"
ATTACH_LEASE_FIRST_RC=$?
ATTACH_LEASE_FIRST_STATE="$(attach_claim_state "$ATTACH_LEASE_MANIFEST")"
ATTACH_LEASE_CHILD="$(head -1 "${ATTACH_LEASE_MARKER}.launches" 2>/dev/null || true)"
if [[ "$ATTACH_LEASE_CHILD" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$ATTACH_LEASE_CHILD" 2>/dev/null; then
  ATTACH_LEASE_CHILD_STATE=alive
else
  ATTACH_LEASE_CHILD_STATE=dead
fi
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_LEASE_MANIFEST" \
  > "${ATTACH_LEASE_MARKER}.retry.out" \
  2> "${ATTACH_LEASE_MARKER}.retry.err"
ATTACH_LEASE_RETRY_RC=$?
if [[ -f "${ATTACH_LEASE_MARKER}.launches" ]]; then
  ATTACH_LEASE_LAUNCHES="$(wc -l < "${ATTACH_LEASE_MARKER}.launches" | tr -d ' ')"
else
  ATTACH_LEASE_LAUNCHES=0
fi
ATTACH_LEASE_RELEASED=missing
if [[ "$ATTACH_LEASE_CHILD_STATE" == alive ]]; then
  ( printf 'release\n' > "${ATTACH_LEASE_MARKER}.release" ) &
  ATTACH_LEASE_RELEASE_WRITER=$!
  IFS= read -r ATTACH_LEASE_RELEASED < "${ATTACH_LEASE_MARKER}.released"
  wait "$ATTACH_LEASE_RELEASE_WRITER"
fi
mv "${ATTACH_LEASE_STREAM}.real" "$ATTACH_LEASE_STREAM"
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_LEASE_MANIFEST" \
  > "${ATTACH_LEASE_MARKER}.final.out" \
  2> "${ATTACH_LEASE_MARKER}.final.err"
ATTACH_LEASE_FINAL_RC=$?
ATTACH_LEASE_FINAL_STATE="$(attach_claim_state "$ATTACH_LEASE_MANIFEST")"
check "serializer death keeps one live stream and a recoverable claim lease" \
  "first=$ATTACH_LEASE_FIRST_RC retry=$ATTACH_LEASE_RETRY_RC final=$ATTACH_LEASE_FINAL_RC claim=$ATTACH_LEASE_FIRST_STATE child=$ATTACH_LEASE_CHILD_STATE launches=$ATTACH_LEASE_LAUNCHES released=$ATTACH_LEASE_RELEASED final_claim=$ATTACH_LEASE_FINAL_STATE serializer=$([[ -f "${ATTACH_LEASE_MARKER}.serializer" ]] && echo reached || echo missing)" \
  "first=137 retry=1 final=0 claim=json child=alive launches=1 released=released final_claim=consumed serializer=reached"

# The claim must remain recovery authority until child output has actually been
# drained. Kill the serializer after readiness at the old tombstone-before-drain
# boundary: the live child lease excludes a concurrent retry, then the exact
# claim must replay once after that child observes its closed pipe and exits.
ATTACH_DRAIN_MARKER="$TMP/attach-drain"
ATTACH_DRAIN_MANIFEST="$(attach_launch_manifest launch-drain)"
mkfifo "${ATTACH_DRAIN_MARKER}.release" "${ATTACH_DRAIN_MARKER}.released"
mv "$ATTACH_LEASE_STREAM" "${ATTACH_LEASE_STREAM}.real-drain"
cp "${ATTACH_LEASE_STREAM}.blocked" "$ATTACH_LEASE_STREAM"
with_deadline 5 env BASH_ENV="$ATTACH_LEASE_ENV" \
  ATTACH_LEASE_BIN="$ATTACH_LEASE_BIN" \
  ATTACH_LEASE_REAL_PERL="$(command -v perl)" \
  ATTACH_LEASE_MARKER="$ATTACH_DRAIN_MARKER" \
  ATTACH_LEASE_KILL_POINT=before_drain \
  ATTACH_LEASE_EMIT_AFTER_RELEASE=1 \
  bash "$ATTACH_LEASE" "$ATTACH_DRAIN_MANIFEST" \
  > "${ATTACH_DRAIN_MARKER}.first.out" \
  2> "${ATTACH_DRAIN_MARKER}.first.err"
ATTACH_DRAIN_FIRST_RC=$?
ATTACH_DRAIN_FIRST_STATE="$(attach_claim_state "$ATTACH_DRAIN_MANIFEST")"
ATTACH_DRAIN_CHILD="$(head -1 "${ATTACH_DRAIN_MARKER}.launches" 2>/dev/null || true)"
if [[ "$ATTACH_DRAIN_CHILD" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 "$ATTACH_DRAIN_CHILD" 2>/dev/null; then
  ATTACH_DRAIN_CHILD_STATE=alive
else
  ATTACH_DRAIN_CHILD_STATE=dead
fi
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_DRAIN_MANIFEST" \
  > "${ATTACH_DRAIN_MARKER}.retry.out" \
  2> "${ATTACH_DRAIN_MARKER}.retry.err"
ATTACH_DRAIN_RETRY_RC=$?
if [[ -f "${ATTACH_DRAIN_MARKER}.launches" ]]; then
  ATTACH_DRAIN_LAUNCHES="$(wc -l < "${ATTACH_DRAIN_MARKER}.launches" | tr -d ' ')"
else
  ATTACH_DRAIN_LAUNCHES=0
fi
ATTACH_DRAIN_RELEASED=missing
if [[ "$ATTACH_DRAIN_CHILD_STATE" == alive ]]; then
  perl -e '
    use strict;
    use warnings;
    my ($fifo, $output) = @ARGV;
    $SIG{ALRM} = sub { exit 124 };
    alarm 5;
    open(my $reader, q{<}, $fifo) or exit 1;
    my $record = <$reader>;
    close($reader) or exit 1;
    exit 1 unless defined($record) && $record eq qq{released\n};
    open(my $writer, q{>}, $output) or exit 1;
    print {$writer} $record or exit 1;
    close($writer) or exit 1;
    alarm 0;
  ' "${ATTACH_DRAIN_MARKER}.released" \
    "${ATTACH_DRAIN_MARKER}.released.out" &
  ATTACH_DRAIN_RELEASE_READER=$!
  ( printf 'release\n' > "${ATTACH_DRAIN_MARKER}.release" ) &
  ATTACH_DRAIN_RELEASE_WRITER=$!
  wait "$ATTACH_DRAIN_RELEASE_WRITER"
  if wait "$ATTACH_DRAIN_RELEASE_READER"; then
    IFS= read -r ATTACH_DRAIN_RELEASED \
      < "${ATTACH_DRAIN_MARKER}.released.out"
  fi
fi
mv "${ATTACH_LEASE_STREAM}.real-drain" "$ATTACH_LEASE_STREAM"
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_DRAIN_MANIFEST" \
  > "${ATTACH_DRAIN_MARKER}.final.out" \
  2> "${ATTACH_DRAIN_MARKER}.final.err"
ATTACH_DRAIN_FINAL_RC=$?
ATTACH_DRAIN_FINAL_STATE="$(attach_claim_state "$ATTACH_DRAIN_MANIFEST")"
ATTACH_DRAIN_DELIVERIES="$(grep -c '"watch_id":"watch-dddddddddddddddddddddddd"' \
  "${ATTACH_DRAIN_MARKER}.final.out" 2>/dev/null || true)"
check "serializer death before drain preserves one replay authority" \
  "first=$ATTACH_DRAIN_FIRST_RC retry=$ATTACH_DRAIN_RETRY_RC final=$ATTACH_DRAIN_FINAL_RC claim=$ATTACH_DRAIN_FIRST_STATE child=$ATTACH_DRAIN_CHILD_STATE launches=$ATTACH_DRAIN_LAUNCHES released=$ATTACH_DRAIN_RELEASED deliveries=$ATTACH_DRAIN_DELIVERIES final_claim=$ATTACH_DRAIN_FINAL_STATE serializer=$([[ -f "${ATTACH_DRAIN_MARKER}.serializer" ]] && echo reached || echo missing)" \
  "first=137 retry=1 final=0 claim=json child=alive launches=1 released=released deliveries=2 final_claim=consumed serializer=reached"

# Drain completes into the finalizer's bounded private buffer before any stdout
# delivery. A crash at that exact boundary therefore has no prefix to duplicate:
# the still-JSON claim can replay the whole generation once.
ATTACH_FINALIZER_MARKER="$TMP/attach-finalizer"
ATTACH_FINALIZER_MANIFEST="$(attach_launch_manifest launch-finalizer)"
with_deadline 5 env BASH_ENV="$ATTACH_LEASE_ENV" \
  ATTACH_LEASE_BIN="$ATTACH_LEASE_BIN" \
  ATTACH_LEASE_REAL_PERL="$(command -v perl)" \
  ATTACH_LEASE_MARKER="$ATTACH_FINALIZER_MARKER" \
  ATTACH_LEASE_KILL_POINT=after_drain \
  bash "$ATTACH_LEASE" "$ATTACH_FINALIZER_MANIFEST" \
  > "${ATTACH_FINALIZER_MARKER}.first.out" \
  2> "${ATTACH_FINALIZER_MARKER}.first.err"
ATTACH_FINALIZER_FIRST_RC=$?
ATTACH_FINALIZER_FIRST_STATE="$(attach_claim_state \
  "$ATTACH_FINALIZER_MANIFEST")"
ATTACH_FINALIZER_FIRST_BYTES="$(wc -c \
  < "${ATTACH_FINALIZER_MARKER}.first.out" | tr -d ' ')"
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_FINALIZER_MANIFEST" \
  > "${ATTACH_FINALIZER_MARKER}.final.out" \
  2> "${ATTACH_FINALIZER_MARKER}.final.err"
ATTACH_FINALIZER_FINAL_RC=$?
ATTACH_FINALIZER_FINAL_STATE="$(attach_claim_state \
  "$ATTACH_FINALIZER_MANIFEST")"
ATTACH_FINALIZER_DELIVERIES="$(grep -c \
  '"watch_id":"watch-dddddddddddddddddddddddd"' \
  "${ATTACH_FINALIZER_MARKER}.final.out" 2>/dev/null || true)"
check "post-drain death replays without a duplicate delivered prefix" \
  "first=$ATTACH_FINALIZER_FIRST_RC claim=$ATTACH_FINALIZER_FIRST_STATE first_bytes=$ATTACH_FINALIZER_FIRST_BYTES final=$ATTACH_FINALIZER_FINAL_RC deliveries=$ATTACH_FINALIZER_DELIVERIES final_claim=$ATTACH_FINALIZER_FINAL_STATE serializer=$([[ -f "${ATTACH_FINALIZER_MARKER}.serializer" ]] && echo reached || echo missing)" \
  "first=137 claim=json first_bytes=0 final=0 deliveries=2 final_claim=consumed serializer=reached"

# The outer Bash relay is the stdout delivery boundary. Pause it before opening
# the serializer FIFO: a concurrent retry must still see the live generation
# lease, and killing the paused relay must leave the exact claim replayable.
ATTACH_RELAY_MARKER="$TMP/attach-relay"
ATTACH_RELAY_ENV="${ATTACH_RELAY_MARKER}.env"
ATTACH_RELAY_MANIFEST="$(attach_launch_manifest launch-relay)"
mkfifo "${ATTACH_RELAY_MARKER}.ready" "${ATTACH_RELAY_MARKER}.release" \
  "${ATTACH_RELAY_MARKER}.serializer-ready"
printf '%s\n' \
  'export PATH="$ATTACH_LEASE_BIN:$PATH"' \
  'if [[ -z "${ATTACH_RELAY_ROOT_PID:-}" ]]; then' \
  '  export ATTACH_RELAY_ROOT_PID="$$"' \
  '  set -T' \
  '  _attach_relay_pause() {' \
  '    [[ "$1" == '\''exec 3< "$event_fifo"'\'' ]] || return 0' \
  '    trap - DEBUG' \
  '    printf '\''ready\n'\'' > "$ATTACH_RELAY_READY"' \
  '    _attach_relay_release=""' \
  '    while [[ "$_attach_relay_release" != release ]]; do' \
  '      IFS= read -r _attach_relay_release < "$ATTACH_RELAY_RELEASE" || true' \
  '    done' \
  '  }' \
  '  trap '\''_attach_relay_pause "$BASH_COMMAND"'\'' DEBUG' \
  'fi' \
  > "$ATTACH_RELAY_ENV"
env BASH_ENV="$ATTACH_RELAY_ENV" \
  ATTACH_LEASE_BIN="$ATTACH_LEASE_BIN" \
  ATTACH_LEASE_REAL_PERL="$(command -v perl)" \
  ATTACH_LEASE_MARKER="$ATTACH_RELAY_MARKER" \
  ATTACH_LEASE_KILL_POINT=relay_ready \
  ATTACH_RELAY_READY="${ATTACH_RELAY_MARKER}.ready" \
  ATTACH_RELAY_RELEASE="${ATTACH_RELAY_MARKER}.release" \
  ATTACH_RELAY_SERIALIZER_READY="${ATTACH_RELAY_MARKER}.serializer-ready" \
  bash "$ATTACH_LEASE" "$ATTACH_RELAY_MANIFEST" \
  > "${ATTACH_RELAY_MARKER}.first.out" \
  2> "${ATTACH_RELAY_MARKER}.first.err" &
ATTACH_RELAY_PARENT=$!
with_deadline 5 perl -e '
  use strict;
  use warnings;
  my $fifo = shift;
  $SIG{ALRM} = sub { exit 124 };
  alarm 4;
  open(my $reader, q{<}, $fifo) or exit 1;
  my $record = <$reader>;
  close($reader) or exit 1;
  exit 1 unless defined($record) && $record eq qq{ready\n};
  alarm 0;
' "${ATTACH_RELAY_MARKER}.ready"
ATTACH_RELAY_PAUSED_RC=$?
with_deadline 5 perl -e '
  use strict;
  use warnings;
  my $fifo = shift;
  $SIG{ALRM} = sub { exit 124 };
  alarm 4;
  open(my $reader, q{<}, $fifo) or exit 1;
  my $record = <$reader>;
  close($reader) or exit 1;
  exit 1 unless defined($record) && $record eq qq{ready\n};
  alarm 0;
' "${ATTACH_RELAY_MARKER}.serializer-ready"
ATTACH_RELAY_SERIALIZER_RC=$?
ATTACH_RELAY_FIRST_STATE="$(attach_claim_state "$ATTACH_RELAY_MANIFEST")"
ATTACH_RELAY_FIRST_BYTES="$(wc -c \
  < "${ATTACH_RELAY_MARKER}.first.out" | tr -d ' ')"
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_RELAY_MANIFEST" \
  > "${ATTACH_RELAY_MARKER}.retry.out" \
  2> "${ATTACH_RELAY_MARKER}.retry.err"
ATTACH_RELAY_RETRY_RC=$?
kill -KILL "$ATTACH_RELAY_PARENT" 2>/dev/null || true
wait "$ATTACH_RELAY_PARENT" 2>/dev/null
ATTACH_RELAY_FIRST_RC=$?
with_deadline 5 perl -MFcntl=:DEFAULT,:flock -e '
  use strict;
  use warnings;
  my $path = shift;
  $SIG{ALRM} = sub { exit 124 };
  alarm 4;
  sysopen(my $claim, $path, O_RDWR | O_NONBLOCK) or exit 1;
  flock($claim, LOCK_EX) or exit 1;
  close($claim) or exit 1;
  alarm 0;
' "$ATTACH_RELAY_MANIFEST"
ATTACH_RELAY_UNLOCK_RC=$?
with_deadline 5 bash "$ATTACH_LEASE" "$ATTACH_RELAY_MANIFEST" \
  > "${ATTACH_RELAY_MARKER}.final.out" \
  2> "${ATTACH_RELAY_MARKER}.final.err"
ATTACH_RELAY_FINAL_RC=$?
ATTACH_RELAY_FINAL_STATE="$(attach_claim_state "$ATTACH_RELAY_MANIFEST")"
ATTACH_RELAY_DELIVERIES="$(grep -c \
  '"watch_id":"watch-dddddddddddddddddddddddd"' \
  "${ATTACH_RELAY_MARKER}.final.out" 2>/dev/null || true)"
check "relay death before FIFO delivery preserves one replay authority" \
  "pause=$ATTACH_RELAY_PAUSED_RC serializer=$ATTACH_RELAY_SERIALIZER_RC first=$ATTACH_RELAY_FIRST_RC claim=$ATTACH_RELAY_FIRST_STATE first_bytes=$ATTACH_RELAY_FIRST_BYTES retry=$ATTACH_RELAY_RETRY_RC unlock=$ATTACH_RELAY_UNLOCK_RC final=$ATTACH_RELAY_FINAL_RC deliveries=$ATTACH_RELAY_DELIVERIES final_claim=$ATTACH_RELAY_FINAL_STATE" \
  "pause=0 serializer=0 first=137 claim=json first_bytes=0 retry=1 unlock=0 final=0 deliveries=2 final_claim=consumed"

ATTACH_CAP_MANIFEST="$(attach_claim_path direct-cap)"
jq -nc --arg log "$ATTACH_ONE_LOG" --arg id "$ATTACH_ONE_ID" '
  {schema:1,omitted_refs:0,entries:[range(0;5) as $n |
    {remote_ref:("refs/heads/cap-"+($n|tostring)),branch:("cap-"+($n|tostring)),
     watch_id:$id,event_log:$log}]}' > "$ATTACH_CAP_MANIFEST"
bash "$ATTACH" "$ATTACH_CAP_MANIFEST" >/dev/null 2>&1
ATTACH_CAP_RC=$?
check "attachment rejects more than four represented refs" "$ATTACH_CAP_RC" "1"

ATTACH_GLOBAL_MANIFEST="$(attach_claim_path direct-global-cap)"
ATTACH_GLOBAL_ENTRIES='[]'
for ATTACH_INDEX in 1 2 3 4; do
  ATTACH_BRANCH="global-${ATTACH_INDEX}"
  ATTACH_ID="watch-${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}${ATTACH_INDEX}"
  ATTACH_LOG="$ATTACH_DIR/$(pr_watch_branch_key "$ATTACH_BRANCH").jsonl"
  jq -nc --arg id "$ATTACH_ID" '{kind:"watch_start",watch_id:$id}' > "$ATTACH_LOG"
  for EVENT_INDEX in 1 2 3; do
    jq -nc --arg id "$ATTACH_ID" --arg name "event-${EVENT_INDEX}" \
      '{kind:"check",watch_id:$id,name:$name,body:("x" * 120)}' >> "$ATTACH_LOG"
  done
  jq -nc --arg id "$ATTACH_ID" '{kind:"watch_end",watch_id:$id,reason:"global done"}' >> "$ATTACH_LOG"
  ATTACH_ENTRY="$(jq -nc --arg branch "$ATTACH_BRANCH" --arg id "$ATTACH_ID" --arg log "$ATTACH_LOG" \
    '{remote_ref:("refs/heads/"+$branch),branch:$branch,watch_id:$id,event_log:$log}')"
  ATTACH_GLOBAL_ENTRIES="$(jq -nc --argjson entries "$ATTACH_GLOBAL_ENTRIES" \
    --argjson entry "$ATTACH_ENTRY" '$entries + [$entry]')"
done
jq -nc --argjson entries "$ATTACH_GLOBAL_ENTRIES" \
  '{schema:1,omitted_refs:0,entries:$entries}' > "$ATTACH_GLOBAL_MANIFEST"
ATTACH_GLOBAL_OUT="$(PR_WATCH_ATTACH_MAX_EVENTS=8 PR_WATCH_ATTACH_MAX_BYTES=2000 \
  bash "$ATTACH" "$ATTACH_GLOBAL_MANIFEST")"
ATTACH_GLOBAL_RC=$?
ATTACH_GLOBAL_LINES="$(printf '%s\n' "$ATTACH_GLOBAL_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
ATTACH_GLOBAL_BYTES="$(LC_ALL=C printf '%s\n' "$ATTACH_GLOBAL_OUT" | wc -c | tr -d ' ')"
ATTACH_GLOBAL_SUMMARIES="$(printf '%s\n' "$ATTACH_GLOBAL_OUT" | jq -s \
  '[.[] | select(.kind == "stream_omitted" and .scope == "attachment"
                 and .terminal_output == true)] | length')"
check "four-ref attach has one aggregate lifetime budget" \
  "$(( ATTACH_GLOBAL_LINES <= 8 && ATTACH_GLOBAL_BYTES <= 2000 ))/$ATTACH_GLOBAL_SUMMARIES/$ATTACH_GLOBAL_RC" \
  "1/1/0"

# Each child stream can emit a JSON record larger than POSIX PIPE_BUF. When all
# children write those records directly to one FIFO, the kernel may interleave
# their writes and preserve newlines while destroying JSON record boundaries.
ATTACH_ATOMIC_ENTRIES='[]'
for ATTACH_INDEX in 1 2 3 4; do
  ATTACH_BRANCH="atomic-${ATTACH_INDEX}"
  printf -v ATTACH_ID 'watch-%024d' "$ATTACH_INDEX"
  ATTACH_LOG="$ATTACH_DIR/$(pr_watch_branch_key "$ATTACH_BRANCH").jsonl"
  jq -nc --arg id "$ATTACH_ID" '{kind:"watch_start",watch_id:$id}' > "$ATTACH_LOG"
  jq -nc --arg id "$ATTACH_ID" --arg body "$(printf '%07000d' "$ATTACH_INDEX")" \
    '{kind:"check",watch_id:$id,body:$body}' >> "$ATTACH_LOG"
  jq -nc --arg id "$ATTACH_ID" \
    '{kind:"watch_end",watch_id:$id,reason:"atomic done"}' >> "$ATTACH_LOG"
  ATTACH_ENTRY="$(jq -nc --arg branch "$ATTACH_BRANCH" --arg id "$ATTACH_ID" \
    --arg log "$ATTACH_LOG" \
    '{remote_ref:("refs/heads/"+$branch),branch:$branch,watch_id:$id,event_log:$log}')"
  ATTACH_ATOMIC_ENTRIES="$(jq -nc --argjson entries "$ATTACH_ATOMIC_ENTRIES" \
    --argjson entry "$ATTACH_ENTRY" '$entries + [$entry]')"
done
ATTACH_ATOMIC_RESULT=valid
for ATTACH_ATTEMPT in 1 2 3 4 5 6 7 8; do
  ATTACH_ATOMIC_MANIFEST="$(attach_claim_path "direct-atomic-${ATTACH_ATTEMPT}")"
  ATTACH_ATOMIC_OUT="$ATTACH_DIR/direct-atomic-${ATTACH_ATTEMPT}.out"
  jq -nc --argjson entries "$ATTACH_ATOMIC_ENTRIES" \
    '{schema:1,omitted_refs:0,entries:$entries}' > "$ATTACH_ATOMIC_MANIFEST"
  PR_WATCH_ATTACH_MAX_EVENTS=16 PR_WATCH_ATTACH_MAX_BYTES=32768 \
    bash "$ATTACH" "$ATTACH_ATOMIC_MANIFEST" > "$ATTACH_ATOMIC_OUT" 2>/dev/null
  if ! jq -s 'length == 12 and all(.[]; type == "object")' \
      "$ATTACH_ATOMIC_OUT" >/dev/null 2>&1; then
    ATTACH_ATOMIC_RESULT=corrupt
    break
  fi
done
check "multi-ref attach preserves one valid JSON record per child event" \
  "$ATTACH_ATOMIC_RESULT" "valid"

# Inject a public-boundary probe immediately after the serializer's real fork,
# before its PID map is updated. The child remains controlled until the
# serializer proves it owns and reaps that exact PID.
ATTACH_RACE_BIN="$TMP/attach-race-bin"
ATTACH_RACE_ENV="$TMP/attach-fork-race.env"
ATTACH_RACE_MARKER="$TMP/attach-fork-race"
ATTACH_RACE_MANIFEST="$(attach_claim_path direct-fork-race)"
ATTACH_RACE_BRANCH="attach-race"
ATTACH_RACE_ID="watch-cccccccccccccccccccccccc"
ATTACH_RACE_LOG="$ATTACH_DIR/$(pr_watch_branch_key "$ATTACH_RACE_BRANCH").jsonl"
mkdir -p "$ATTACH_RACE_BIN"
cat > "$ATTACH_RACE_BIN/perl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == -MIO::Select \
   && -n "${ATTACH_FORK_RACE_MARKER:-}" ]]; then
  serializer_modules=(-MIO::Select)
  shift
  if [[ "${1:-}" == -MPOSIX=* ]]; then
    serializer_modules+=("$1")
    shift
  fi
  [[ "${1:-}" == -e && -n "${2:-}" ]] || exec "$ATTACH_FORK_RACE_REAL_PERL" \
    "${serializer_modules[@]}" "$@"
  serializer="$2"
  shift 2
  fork_line='      my $pid = fork();'
  injected='      pipe(my $probe_reader, my $probe_writer) or exit 125;
      my $pid = fork();
      if (defined($pid) && $pid == 0) {
        close($probe_reader);
        my $marker = $ENV{ATTACH_FORK_RACE_MARKER};
        open(my $probe, q{>}, $marker . q{.child}) or exit 125;
        print {$probe} "$$\n"; close($probe) or exit 125;
        syswrite($probe_writer, q{r}, 1) == 1 or exit 125;
        close($probe_writer) or exit 125;
        $SIG{TERM} = sub { exit 0 };
        $SIG{INT} = sub { exit 0 };
        require POSIX;
        my $probe_signals = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT());
        POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $probe_signals);
        while (1) { select(undef, undef, undef, 0.1); }
      }
      if (defined($pid) && $pid > 0) {
        close($probe_writer);
        my $ready = q{};
        sysread($probe_reader, $ready, 1) == 1 or exit 125;
        close($probe_reader) or exit 125;
        kill(q{TERM}, $$);
      }'
  serializer="$(printf '%s' "$serializer" | "$ATTACH_FORK_RACE_REAL_PERL" \
    -0777 -e '
      my ($needle, $replacement) = @ARGV;
      my $source = <STDIN>;
      my $offset = index($source, $needle);
      exit 126 if $offset < 0;
      substr($source, $offset, length($needle), $replacement);
      print $source;
    ' "$fork_line" "$injected")" || exit $?
  exec "$ATTACH_FORK_RACE_REAL_PERL" "${serializer_modules[@]}" \
    -e "$serializer" "$@"
fi
exec "$ATTACH_FORK_RACE_REAL_PERL" "$@"
EOF
chmod +x "$ATTACH_RACE_BIN/perl"
printf '%s\n' \
  'set -T' \
  '_attach_race_debug() {' \
  '  [[ "$1" == PR_WATCH_STREAM_MAX_EVENTS=*perl* ]] || return 0' \
  '  trap - DEBUG' \
  '  export PATH="$ATTACH_FORK_RACE_BIN:$PATH"' \
  '}' \
  'trap '\''_attach_race_debug "$BASH_COMMAND"'\'' DEBUG' \
  > "$ATTACH_RACE_ENV"
jq -nc --arg branch "$ATTACH_RACE_BRANCH" --arg log "$ATTACH_RACE_LOG" \
  --arg id "$ATTACH_RACE_ID" '
  {schema:1,omitted_refs:0,entries:[
    {remote_ref:("refs/heads/"+$branch),branch:$branch,watch_id:$id,event_log:$log}]}' \
  > "$ATTACH_RACE_MANIFEST"
jq -nc --arg id "$ATTACH_RACE_ID" '{kind:"watch_start",watch_id:$id}' \
  > "$ATTACH_RACE_LOG"
ATTACH_RACE_DIR_STATE="$(ls -ld "$ATTACH_DIR" 2>&1)"
ATTACH_RACE_DIRECT_IDENTITY="$(pr_watch_state_directory_identity \
  "$ATTACH_DIR" 2>&1)"
with_deadline 5 env BASH_ENV="$ATTACH_RACE_ENV" \
  ATTACH_FORK_RACE_BIN="$ATTACH_RACE_BIN" \
  ATTACH_FORK_RACE_REAL_PERL="$(command -v perl)" \
  ATTACH_FORK_RACE_MARKER="$ATTACH_RACE_MARKER" \
  bash "$ATTACH" "$ATTACH_RACE_MANIFEST" \
  > "${ATTACH_RACE_MARKER}.out" 2> "${ATTACH_RACE_MARKER}.err"
ATTACH_RACE_RC=$?
ATTACH_RACE_CHILD="$(cat "${ATTACH_RACE_MARKER}.child" 2>/dev/null || true)"
ATTACH_RACE_DEADLINE=$(( SECONDS + 2 ))
while [[ "$ATTACH_RACE_CHILD" =~ ^[1-9][0-9]*$ ]] \
      && kill -0 "$ATTACH_RACE_CHILD" 2>/dev/null \
      && (( SECONDS < ATTACH_RACE_DEADLINE )); do
  sleep 0.02
done
if [[ ! "$ATTACH_RACE_CHILD" =~ ^[1-9][0-9]*$ ]]; then
  ATTACH_RACE_CHILD_STATE=missing
elif kill -0 "$ATTACH_RACE_CHILD" 2>/dev/null; then
  ATTACH_RACE_CHILD_STATE=alive
  kill -KILL "$ATTACH_RACE_CHILD" 2>/dev/null || true
else
  ATTACH_RACE_CHILD_STATE=dead
fi
if [[ "$ATTACH_RACE_RC/$ATTACH_RACE_CHILD_STATE" == 143/dead ]]; then
  ok "TERM at serializer fork publication reaps the forked stream"
else
  no "TERM at serializer fork publication reaps the forked stream" \
    "rc=$ATTACH_RACE_RC child=$ATTACH_RACE_CHILD_STATE direct=$ATTACH_RACE_DIRECT_IDENTITY dir=$ATTACH_RACE_DIR_STATE stderr=$(tr '\n' ' ' < "${ATTACH_RACE_MARKER}.err" 2>/dev/null)"
fi

# The attach command is a public shell boundary. A caller-supplied directory,
# even one shaped like a claim name, must never be renamed as a side effect of
# discovering that it is not a regular manifest.
ATTACH_DIRECTORY="$(attach_claim_path directory-input)"
mkdir "$ATTACH_DIRECTORY"
printf 'keep\n' > "$ATTACH_DIRECTORY/sentinel"
bash "$ATTACH" "$ATTACH_DIRECTORY" >/dev/null 2>&1
ATTACH_DIRECTORY_RC=$?
ATTACH_DIRECTORY_DRAINS="$(find "$ATTACH_DIR" -maxdepth 1 \
  -name "${ATTACH_DIRECTORY##*/}.drain.*" | wc -l | tr -d ' ')"
check "attach rejects a directory without moving or consuming it" \
  "$([[ -f "$ATTACH_DIRECTORY/sentinel" ]] && echo present || echo moved)/$ATTACH_DIRECTORY_DRAINS/$ATTACH_DIRECTORY_RC" \
  "present/0/1"

# ── 8. pre-push arming ───────────────────────────────────────────────────────
#
# Drive the hook the way git does: ref updates on stdin. is_agent is forced off
# so the audit gate is skipped — this suite tests the arm, not the gate.

echo
echo "## pre-push arming"

ZERO="0000000000000000000000000000000000000000"
# Agent pushes materialize audit evidence before arming. Use a real local commit:
# a fabricated object id correctly fails closed before any attachment manifest.
SHA="$(git -C "$REPO" rev-parse HEAD)"

# TERM does not take effect while the daemon sits in `sleep`: bash runs a trap
# only after the foreground child returns. Polling for actual absence keeps a
# still-dying watcher from being misread as the NEXT case's arm.
kill_watchers() {
  pkill -f "$(watcher_pat)" 2>/dev/null
  local deadline=$(( SECONDS + 15 ))
  while (( SECONDS < deadline )); do
    pgrep -f "$(watcher_pat)" >/dev/null 2>&1 || return 0
    sleep 1
  done
  pkill -9 -f "$(watcher_pat)" 2>/dev/null
  sleep 1
}

# A daemon that ignores SIGTERM is unkillable in practice, and every push would
# leave another one polling. Guards the signal traps in pr-watch.sh: a bare
# `trap '<cleanup>' TERM` runs the handler and then RESUMES the loop.
term_kills_daemon() {
  kill_watchers
  reset_state
  ( cd "$REPO" && nohup bash "$SCRATCH_WATCHER" --branch termprobe --sha deadbeef \
      >/dev/null 2>&1 & )
  sleep 2
  pgrep -f "$(watcher_pat) --branch termprobe" >/dev/null 2>&1 || { echo "never-started"; return; }
  pkill -TERM -f "$(watcher_pat) --branch termprobe" 2>/dev/null
  # Generous: bash defers a trap until the foreground `sleep` returns.
  local deadline=$(( SECONDS + 20 ))
  while (( SECONDS < deadline )); do
    pgrep -f "$(watcher_pat) --branch termprobe" >/dev/null 2>&1 || { echo "died"; return; }
    sleep 1
  done
  echo "survived"
  pkill -9 -f "$(watcher_pat) --branch termprobe" 2>/dev/null
}

term_kills_stuck_gh() {
  kill_watchers
  reset_state
  local marker="$TMP/stuck-gh" watcher_pid gh_pid="" descendant_pid="" deadline state
  local watcher_state gh_state descendant_state
  rm -f "${marker}.pid" "${marker}.descendant.pid" "${marker}.ready"
  (
    cd "$REPO" || exit 1
    exec env GH_STUCK_MARKER="$marker" bash "$SCRATCH_WATCHER" \
      --branch stuck-gh --pr 42 --watch-id watch-999999999999999999999999
  ) >"$TMP/stuck-gh.out" 2>"$TMP/stuck-gh.err" & watcher_pid=$!
  deadline=$(( SECONDS + 8 ))
  while (( SECONDS < deadline )); do
    [[ -s "${marker}.pid" && -s "${marker}.descendant.pid" \
       && -e "${marker}.ready" ]] && break
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.1
  done
  gh_pid="$(cat "${marker}.pid" 2>/dev/null || true)"
  descendant_pid="$(cat "${marker}.descendant.pid" 2>/dev/null || true)"
  if [[ ! "$gh_pid" =~ ^[1-9][0-9]*$ \
     || ! "$descendant_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    printf 'watcher=never-ready gh=missing descendant=missing'
    return
  fi
  kill -TERM "$watcher_pid" 2>/dev/null || true
  deadline=$(( SECONDS + 5 ))
  while (( SECONDS < deadline )); do
    ! kill -0 "$watcher_pid" 2>/dev/null \
      && ! kill -0 "$gh_pid" 2>/dev/null \
      && ! kill -0 "$descendant_pid" 2>/dev/null && break
    sleep 0.1
  done
  if kill -0 "$watcher_pid" 2>/dev/null; then watcher_state=alive; else watcher_state=dead; fi
  if kill -0 "$gh_pid" 2>/dev/null; then gh_state=alive; else gh_state=dead; fi
  if kill -0 "$descendant_pid" 2>/dev/null; then descendant_state=alive; else descendant_state=dead; fi
  state="watcher=$watcher_state gh=$gh_state descendant=$descendant_state"
  kill -KILL "$watcher_pid" "$gh_pid" "$descendant_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  printf '%s' "$state"
}

timeout_kills_stuck_gh() {
  kill_watchers
  reset_state
  local marker="$TMP/timeout-gh" watcher_pid gh_pid="" descendant_pid="" deadline state
  local gh_state descendant_state watcher_state
  rm -f "${marker}.pid" "${marker}.descendant.pid" "${marker}.ready"
  rm -rf "${marker}.once"
  (
    cd "$REPO" || exit 1
    exec env GH_STUCK_MARKER="$marker" GH_STUCK_MODE=once \
      PR_WATCH_COMMAND_TIMEOUT=1 bash "$SCRATCH_WATCHER" \
      --branch timeout-gh --pr 42 --once \
      --watch-id watch-888888888888888888888888
  ) >"$TMP/timeout-gh.out" 2>"$TMP/timeout-gh.err" & watcher_pid=$!
  deadline=$(( SECONDS + 8 ))
  while (( SECONDS < deadline )); do
    [[ -s "${marker}.pid" && -s "${marker}.descendant.pid" \
       && -e "${marker}.ready" ]] && break
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.1
  done
  gh_pid="$(cat "${marker}.pid" 2>/dev/null || true)"
  descendant_pid="$(cat "${marker}.descendant.pid" 2>/dev/null || true)"
  deadline=$(( SECONDS + 6 ))
  while (( SECONDS < deadline )); do
    ! kill -0 "$gh_pid" 2>/dev/null \
      && ! kill -0 "$descendant_pid" 2>/dev/null && break
    sleep 0.1
  done
  if kill -0 "$gh_pid" 2>/dev/null; then gh_state=alive; else gh_state=dead; fi
  if kill -0 "$descendant_pid" 2>/dev/null; then descendant_state=alive; else descendant_state=dead; fi
  deadline=$(( SECONDS + 6 ))
  while (( SECONDS < deadline )); do
    ! kill -0 "$watcher_pid" 2>/dev/null && break
    sleep 0.1
  done
  if kill -0 "$watcher_pid" 2>/dev/null; then watcher_state=alive; else watcher_state=dead; fi
  state="watcher=$watcher_state gh=$gh_state descendant=$descendant_state"
  kill -KILL "$watcher_pid" "$gh_pid" "$descendant_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  printf '%s' "$state"
}

# Deliver TERM from the DEBUG hook immediately after Bash forks the external
# command but before the following `$!` assignment publishes ownership. The
# hook records the unowned child so the assertion observes the real leak, not a
# source-shape proxy for it.
term_at_external_launch_publication() {
  kill_watchers
  reset_state
  local marker="$TMP/external-launch-race" bash_env="$TMP/external-launch-race.env"
  local watcher_pid child_pid="" deadline rc=0 child_state monitor_pid monitor_state
  rm -rf "${marker}.once"
  rm -f "${marker}.child" "${marker}.monitor" "${marker}.timeout"
  rm -f "${marker}.monitor-ready"
  mkfifo "${marker}.monitor-ready" || return 1
  apply_test_external_launch_env "$bash_env"
  (
    cd "$REPO" || exit 1
    exec env BASH_ENV="$bash_env" PR_WATCH_LAUNCH_RACE_MARKER="$marker" \
      PR_WATCH_LAUNCH_RACE_POINT="${1:-publication}" \
      GH_STUCK_MARKER="${marker}.gh" bash "$SCRATCH_WATCHER" \
      --branch launch-race --pr 42 --once \
      --watch-id watch-777777777777777777777777
  ) >"${marker}.out" 2>"${marker}.err" & watcher_pid=$!
  wait_for_launch_cleanup "$watcher_pid" "$marker" || rc=$?
  deadline=$(( SECONDS + 3 ))
  while (( SECONDS < deadline )); do
    child_pid="$(cat "${marker}.child" 2>/dev/null || true)"
    [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && break
    sleep 0.02
  done
  deadline=$(( SECONDS + 2 ))
  while [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] \
        && kill -0 "$child_pid" 2>/dev/null \
        && (( SECONDS < deadline )); do
    sleep 0.02
  done
  if [[ ! "$child_pid" =~ ^[1-9][0-9]*$ ]]; then
    child_state=missing
  elif kill -0 "$child_pid" 2>/dev/null; then
    child_state=alive
  else
    child_state=dead
  fi
  if [[ "$child_state" == alive ]]; then
    kill -KILL -- "-$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null || true
  fi
  printf 'rc=%s child=%s' "$rc" "$child_state"
  if [[ -s "${marker}.monitor" ]]; then
    monitor_pid="$(cat "${marker}.monitor")"
    monitor_state=dead
    kill -0 "$monitor_pid" 2>/dev/null && monitor_state=alive
    kill -KILL "$monitor_pid" 2>/dev/null || true
    printf ' monitor=%s' "$monitor_state"
  fi
}

# Keep this independent of the watcher's own timers and TERM cleanup. A stuck
# cleanup must fail the assertion, even when the watchdog subsequently reaps it.
wait_for_launch_cleanup() {  # watcher-pid marker
  local watcher_pid="$1" marker="$2" watchdog_pid rc=0
  perl -e '
    my ($watcher, $marker) = @ARGV;
    select undef, undef, undef, 8;
    my $child = 0;
    if (open(my $record, "<", "$marker.child")) {
      my $value = <$record> // "";
      $child = $1 if $value =~ /\A([1-9][0-9]*)\s*\z/;
      close($record);
    }
    open(my $report, ">", "$marker.timeout") or die $!;
    print $report "launch cleanup timeout=8s watcher=$watcher child=$child\n";
    print $report "PID PPID PGID STAT COMMAND\n";
    my @rows;
    if (open(my $ps, "-|", "ps", "-axo", "pid=,ppid=,pgid=,stat=,comm=")) {
      while (<$ps>) {
        push @rows, [$1, $2, $3, $_] if /^\s*(\d+)\s+(\d+)\s+(\d+)\s/;
      }
      close($ps);
    } else {
      print $report "ps failed: $!\n";
    }
    my %owned = ($watcher => 1);
    $owned{$child} = 1 if $child;
    my $changed = 1;
    while ($changed) {
      $changed = 0;
      for my $row (@rows) {
        next if $owned{$row->[0]};
        if ($owned{$row->[1]} || ($child && $row->[2] == $child)) {
          $owned{$row->[0]} = 1;
          $changed = 1;
        }
      }
    }
    print $report $_->[3] for grep { $owned{$_->[0]} } @rows;
    close($report);
    kill "KILL", -$child if $child;
    kill "KILL", grep { $_ != $watcher } keys %owned;
    kill "KILL", $watcher;
  ' "$watcher_pid" "$marker" </dev/null >/dev/null 2>&1 & watchdog_pid=$!
  wait "$watcher_pid" 2>/dev/null || rc=$?
  kill -KILL "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [[ -f "${marker}.timeout" ]]; then
    cat "${marker}.timeout" >&2
    return 124
  fi
  return "$rc"
}

apply_test_external_launch_env() {  # destination
  cat > "$1" <<'LAUNCH_ENV'
set -T
if [[ -n "${PR_WATCH_LAUNCH_RACE_MARKER:-}" && -z "${PR_WATCH_LAUNCH_RACE_OWNER_PID:-}" ]]; then
  export PR_WATCH_LAUNCH_RACE_OWNER_PID="$$"
fi
# Substitute only the selected bookkeeping monitor, keeping the real watcher
# responsible for its launch, cancellation, and wait. The FIFO proves TERM is
# ignored before the parent enters cleanup.
if [[ "$PR_WATCH_LAUNCH_RACE_POINT" == ignoring-* ]]; then
perl() {
  if [[ "$1" == -e ]] && {
    [[ "$PR_WATCH_LAUNCH_RACE_POINT" == ignoring-monitor && "$2" == *'my ($max_bytes, $pid, $parent, $expected)'* ]] \
      || [[ "$PR_WATCH_LAUNCH_RACE_POINT" == ignoring-timeout && "$2" == *'my ($seconds, $pid, $parent, $expected)'* ]];
  }; then
    exec perl -e '
      $SIG{TERM} = "IGNORE";
      open(my $ready, ">", "$ARGV[0].monitor-ready") or die $!;
      print $ready "ready\n";
      close($ready);
      while (1) { select undef, undef, undef, 60; }
    ' "$PR_WATCH_LAUNCH_RACE_MARKER"
  else
    command perl "$@"
  fi
}
fi
_pr_watch_launch_debug() {
  local pending_command="$1" ready
  case "$PR_WATCH_LAUNCH_RACE_POINT" in
    ignoring-monitor) [[ "$pending_command" == 'active_external_limit_pid=$!' ]] || return 0 ;;
    ignoring-timeout) [[ "$pending_command" == 'active_external_timeout_pid=$!' ]] || return 0 ;;
    *) [[ "$pending_command" == 'active_external_pid=$!' ]] || return 0 ;;
  esac
  [[ -n "${PR_WATCH_LAUNCH_RACE_MARKER:-}" ]] || return 0
  mkdir "${PR_WATCH_LAUNCH_RACE_MARKER}.once" 2>/dev/null || return 0
  trap - DEBUG
  if [[ "$PR_WATCH_LAUNCH_RACE_POINT" == ignoring-* ]]; then
    printf '%s\n' "$active_external_pid" > "${PR_WATCH_LAUNCH_RACE_MARKER}.child"
    printf '%s\n' "$!" > "${PR_WATCH_LAUNCH_RACE_MARKER}.monitor"
    IFS= read -r ready < "${PR_WATCH_LAUNCH_RACE_MARKER}.monitor-ready"
  else
    printf '%s\n' "$!" > "${PR_WATCH_LAUNCH_RACE_MARKER}.child"
  fi
  if [[ "$PR_WATCH_LAUNCH_RACE_POINT" == stopped-watcher ]]; then
    kill -STOP "$PR_WATCH_LAUNCH_RACE_OWNER_PID"
  fi
  kill -TERM "$PR_WATCH_LAUNCH_RACE_OWNER_PID"
}
trap '_pr_watch_launch_debug "$BASH_COMMAND"' DEBUG
LAUNCH_ENV
}

# Make the timeout observer see a different generation for the recorded target
# after the parent has captured the original identity. A generation-bound
# monitor must retire without signalling that now-unrelated PID.
timeout_rejects_reused_generation() {
  kill_watchers
  reset_state
  local marker="$TMP/monitor-generation" bash_env="$TMP/monitor-generation.env"
  local ps_dir="$TMP/monitor-generation-bin" watcher_pid watchdog_pid rc=0
  local term_state completed_state
  rm -rf "$ps_dir" "${marker}.once"
  rm -f "${marker}.target" "${marker}.ps-count" "${marker}.term" \
    "${marker}.completed" "${marker}.ready" "${marker}.release"
  mkdir -p "$ps_dir"
  mkfifo "${marker}.release" || {
    printf 'fixture=fifo-failed'
    return
  }
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target="$(cat "$PR_WATCH_MONITOR_MARKER.target" 2>/dev/null || true)"' \
    'if [[ " $* " == *" -p $target "* && " $* " == *" lstart= "* ]]; then' \
    '    count="$(cat "$PR_WATCH_MONITOR_MARKER.ps-count" 2>/dev/null || printf 0)"' \
    '    count=$((count + 1))' \
    '    printf '\''%s\n'\'' "$count" > "$PR_WATCH_MONITOR_MARKER.ps-count"' \
    '    if (( count > 1 )); then' \
    '      printf '\''99999 Mon Jan  1 00:00:00 2001\n'\''' \
    '      printf '\''changed\n'\'' > "$PR_WATCH_MONITOR_MARKER.release"' \
    '      exit 0' \
    '    fi' \
    'fi' \
    'exec "$PR_WATCH_REAL_PS" "$@"' \
    > "$ps_dir/ps"
  chmod +x "$ps_dir/ps"
  printf '%s\n' \
    'set -T' \
    '_pr_watch_monitor_debug() {' \
    '  [[ "$1" == '\''active_external_pid=$!'\'' ]] || return 0' \
    '  [[ -n "${PR_WATCH_MONITOR_MARKER:-}" ]] || return 0' \
    '  trap - DEBUG' \
    '  printf '\''%s\n'\'' "$!" > "${PR_WATCH_MONITOR_MARKER}.target"' \
    '}' \
    'trap '\''_pr_watch_monitor_debug "$BASH_COMMAND"'\'' DEBUG' \
    > "$bash_env"
  (
    cd "$REPO" || exit 1
    exec env PATH="$ps_dir:$PATH" BASH_ENV="$bash_env" \
      PR_WATCH_MONITOR_MARKER="$marker" PR_WATCH_REAL_PS="$(command -v ps)" \
      GH_GENERATION_MARKER="$marker" PR_WATCH_COMMAND_TIMEOUT=1 \
      bash "$SCRATCH_WATCHER" --branch monitor-generation --pr 42 --once \
      --watch-id watch-555555555555555555555555
  ) >"${marker}.out" 2>"${marker}.err" & watcher_pid=$!
  perl -e '
    my ($seconds, $pid) = @ARGV;
    select(undef, undef, undef, $seconds);
    kill(q{TERM}, $pid);
  ' 8 "$watcher_pid" >/dev/null 2>&1 & watchdog_pid=$!
  wait "$watcher_pid" 2>/dev/null || rc=$?
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  [[ -e "${marker}.term" ]] && term_state=present || term_state=absent
  [[ -e "${marker}.completed" ]] && completed_state=present || completed_state=absent
  if [[ "$rc/$term_state/$completed_state" == 0/absent/present ]]; then
    printf 'rc=0 term=absent completed=present'
  else
    printf 'rc=%s term=%s completed=%s target=%s ps=%s ready=%s stderr=%s' \
      "$rc" "$term_state" "$completed_state" \
      "$(cat "${marker}.target" 2>/dev/null || true)" \
      "$(cat "${marker}.ps-count" 2>/dev/null || true)" \
      "$([[ -e "${marker}.ready" ]] && echo yes || echo no)" \
      "$(tr '\n' ' ' < "${marker}.err" 2>/dev/null)"
  fi
}

output_cap_kills_flooding_gh() {
  kill_watchers
  reset_state
  local marker="$TMP/flood-gh" watcher_pid gh_pid="" descendant_pid="" deadline
  local watcher_state gh_state descendant_state completed_state rc=0
  rm -f "${marker}.pid" "${marker}.descendant.pid" "${marker}.ready" \
    "${marker}.completed"
  rm -rf "${marker}.once"
  (
    cd "$REPO" || exit 1
    exec env GH_FLOOD_MARKER="$marker" GH_FLOOD_MODE=once \
      PR_WATCH_COMMAND_TIMEOUT=20 bash "$SCRATCH_WATCHER" \
      --branch flood-gh --pr 42 --once \
      --watch-id watch-666666666666666666666666
  ) >"$TMP/flood-gh.out" 2>"$TMP/flood-gh.err" & watcher_pid=$!
  deadline=$(( SECONDS + 8 ))
  while (( SECONDS < deadline )); do
    [[ -s "${marker}.pid" && -s "${marker}.descendant.pid" \
       && -e "${marker}.ready" ]] && break
    kill -0 "$watcher_pid" 2>/dev/null || break
    sleep 0.1
  done
  gh_pid="$(cat "${marker}.pid" 2>/dev/null || true)"
  descendant_pid="$(cat "${marker}.descendant.pid" 2>/dev/null || true)"
  deadline=$(( SECONDS + 7 ))
  while (( SECONDS < deadline )); do
    ! kill -0 "$watcher_pid" 2>/dev/null && break
    sleep 0.1
  done
  if kill -0 "$watcher_pid" 2>/dev/null; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  wait "$watcher_pid" 2>/dev/null || rc=$?
  deadline=$(( SECONDS + 3 ))
  while (( SECONDS < deadline )); do
    ! kill -0 "$gh_pid" 2>/dev/null \
      && ! kill -0 "$descendant_pid" 2>/dev/null && break
    sleep 0.1
  done
  [[ -e "${marker}.completed" ]] && completed_state=present || completed_state=absent
  if kill -0 "$watcher_pid" 2>/dev/null; then watcher_state=alive; else watcher_state=dead; fi
  if kill -0 "$gh_pid" 2>/dev/null; then gh_state=alive; else gh_state=dead; fi
  if kill -0 "$descendant_pid" 2>/dev/null; then descendant_state=alive; else descendant_state=dead; fi
  kill -KILL "$watcher_pid" "$gh_pid" "$descendant_pid" 2>/dev/null || true
  printf 'completed=%s watcher=%s rc=%s gh=%s descendant=%s' \
    "$completed_state" "$watcher_state" "$rc" "$gh_state" "$descendant_state"
}

kill_tooling_arm() {
  local pattern="$SCRATCH_WATCHER --branch feat --sha $SHA"
  pkill -f "$pattern" 2>/dev/null || true
  local deadline=$(( SECONDS + 15 ))
  while (( SECONDS < deadline )); do
    pgrep -f "$pattern" >/dev/null 2>&1 || return 0
    sleep 1
  done
  pkill -9 -f "$pattern" 2>/dev/null || true
}

arm() {
  local stdin_line="$1" ; shift
  kill_watchers
  kill_tooling_arm
  reset_state
  # The watcher's first act is a bounded ls-remote wait against the local bare
  # remote, so it stays alive long enough to observe without touching a network.
  (cd "$REPO" && printf '%s\n' "$stdin_line" \
    | env -u CLAUDECODE -u CODEX_SANDBOX -u AGENT_GATED ${@+"$@"} \
      bash "$PREPUSH" origin "$TMP/origin.git" >/dev/null 2>&1)
  sleep 1
  local result
  if pgrep -f "$SCRATCH_WATCHER --branch feat --sha $SHA" >/dev/null 2>&1; then result=armed; else result=idle; fi
  kill_tooling_arm
  kill_watchers
  printf '%s' "$result"
}

check "branch push arms a watcher" \
  "$(arm "refs/heads/feat $SHA refs/heads/feat $ZERO")" "armed"

check "branch DELETION arms nothing" \
  "$(arm "refs/heads/feat $ZERO refs/heads/feat $SHA")" "idle"

check "tag push arms nothing" \
  "$(arm "refs/tags/v1 $SHA refs/tags/v1 $ZERO")" "idle"

check "BOXLITE_PR_WATCH=0 opts out" \
  "$(arm "refs/heads/feat $SHA refs/heads/feat $ZERO" BOXLITE_PR_WATCH=0)" "idle"

attachment_key_for() { # session-scope command-hash
  local digest
  digest="$(printf 'scope=%s\ncommand=%s' "$1" "$2" \
    | shasum -a 256 | awk '{print $1}')"
  printf 'attach-%s' "$digest"
}

arm_agent_manifest() { # command session ref-update-lines
  local command="$1" session="$2" updates="$3" scope command_hash key owner_token
  kill_watchers
  reset_state
  mkdir -p "$REPO/.agents/state"
  scope="git-$(printf '%s' "$session" | git -C "$REPO" hash-object --stdin)"
  command_hash="$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')"
  key="$(attachment_key_for "$scope" "$command_hash")"
  owner_token="$(verdict_audit_process_start_token "$$")"
  jq -nc --arg branch "$(git -C "$REPO" branch --show-current)" \
    --arg head "$(git -C "$REPO" rev-parse HEAD)" --arg command_hash "$command_hash" \
    --arg scope "$scope" --argjson owner_pid "$$" --arg owner_token "$owner_token" \
    '{branch:$branch,head:$head,command_kind:"push",diff_hash:"fixture",command_hash:$command_hash,
      owner:{pid:$owner_pid,start_token:$owner_token},override:null,
      lifecycle:{session_scope:$scope,prompt_epoch:"1-1-0"}}' \
    > "$REPO/.agents/state/last-audit-handoff.json"
  (cd "$REPO" && printf '%s\n' "$updates" \
    | CLAUDECODE=1 bash "$PREPUSH" origin "$TMP/origin.git" >/dev/null 2>&1)
  sleep 1
  kill_watchers
  printf '%s' "$REPO/.git/pr-watch/${key}.json"
}

EXPLICIT_COMMAND="git push origin refs/heads/local:refs/heads/other"
EXPLICIT_MANIFEST="$(arm_agent_manifest "$EXPLICIT_COMMAND" session-explicit \
  "refs/heads/local $SHA refs/heads/other $ZERO")"
check "pre-push records the explicit remote ref, watch generation, and hashed log" \
  "$(jq -r '.entries[0] | .remote_ref + ":" + .branch + ":" + .watch_id + ":" + (.event_log | split("/")[-1])' \
      "$EXPLICIT_MANIFEST" 2>/dev/null)" \
  "refs/heads/other:other:$(jq -r '.entries[0].watch_id' "$EXPLICIT_MANIFEST" 2>/dev/null):$(pr_watch_branch_key other).jsonl"
check "pre-push generation id is explicit and bounded" \
  "$(jq -r '.entries[0].watch_id | test("^watch-[0-9a-f]{24}$")' "$EXPLICIT_MANIFEST" 2>/dev/null)" "true"

MULTI_COMMAND="git push origin refs/heads/one:refs/heads/remote-one refs/heads/two:refs/heads/remote-two"
MULTI_MANIFEST="$(arm_agent_manifest "$MULTI_COMMAND" session-multi \
  "refs/heads/one $SHA refs/heads/remote-one $ZERO
refs/heads/two $SHA refs/heads/remote-two $ZERO")"
check "pre-push represents both remote refs from one push" \
  "$(jq -r '[.entries[].remote_ref] | join("|")' "$MULTI_MANIFEST" 2>/dev/null)" \
  "refs/heads/remote-one|refs/heads/remote-two"
check "pre-push assigns a distinct generation to every armed ref" \
  "$(jq -r '[.entries[].watch_id] | length == 2 and (unique | length == 2)' "$MULTI_MANIFEST" 2>/dev/null)" "true"

# A second push commonly arrives while the first branch watcher remains live.
# The manifest must name a generation that actually published watch_start, not
# the fresh id of a duplicate process that exited at the live branch lock.
kill_watchers
reset_state
REPEAT_BRANCH="repeat-branch"
REPEAT_ACTIVE_ID="watch-cccccccccccccccccccccccc"
REPEAT_READY_FIFO="$TMP/repeat-ready"
mkfifo "$REPEAT_READY_FIFO"
exec 9<> "$REPEAT_READY_FIFO"
rm -f "$REPEAT_READY_FIFO"
( cd "$REPO" && PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 \
    PR_WATCH_MAX_LIFETIME=60 nohup bash "$SCRATCH_WATCHER" \
      --branch "$REPEAT_BRANCH" --pr 42 --watch-id "$REPEAT_ACTIVE_ID" \
      --ready-fd 9 \
      > "$REPO/.git/repeat-watcher.out" 2>&1 & )
REPEAT_LOG="$REPO/.git/pr-watch/$(pr_watch_branch_key "$REPEAT_BRANCH").jsonl"
IFS= read -r -t 10 -u 9 REPEAT_READY_ID || REPEAT_READY_ID=""
exec 9>&-
REPEAT_COMMAND="git push origin refs/heads/local:refs/heads/$REPEAT_BRANCH"
REPEAT_SESSION="session-repeat"
REPEAT_SCOPE="git-$(printf '%s' "$REPEAT_SESSION" | git -C "$REPO" hash-object --stdin)"
REPEAT_COMMAND_HASH="$(printf '%s' "$REPEAT_COMMAND" | shasum -a 256 | awk '{print $1}')"
REPEAT_KEY="$(attachment_key_for "$REPEAT_SCOPE" "$REPEAT_COMMAND_HASH")"
REPEAT_OWNER_TOKEN="$(verdict_audit_process_start_token "$$")"
jq -nc --arg branch "$(git -C "$REPO" branch --show-current)" \
  --arg head "$(git -C "$REPO" rev-parse HEAD)" --arg command_hash "$REPEAT_COMMAND_HASH" \
  --arg scope "$REPEAT_SCOPE" --argjson owner_pid "$$" --arg owner_token "$REPEAT_OWNER_TOKEN" \
  '{branch:$branch,head:$head,command_kind:"push",diff_hash:"fixture",command_hash:$command_hash,
    owner:{pid:$owner_pid,start_token:$owner_token},override:null,
    lifecycle:{session_scope:$scope,prompt_epoch:"1-1-0"}}' \
  > "$REPO/.agents/state/last-audit-handoff.json"
(cd "$REPO" && printf 'refs/heads/local %s refs/heads/%s %s\n' \
    "$SHA" "$REPEAT_BRANCH" "$ZERO" \
  | CLAUDECODE=1 bash "$PREPUSH" origin "$TMP/origin.git" >/dev/null 2>&1)
REPEAT_MANIFEST="$REPO/.git/pr-watch/${REPEAT_KEY}.json"
REPEAT_MANIFEST_ID="$(jq -r '.entries[0].watch_id // empty' "$REPEAT_MANIFEST" 2>/dev/null)"
REPEAT_MANIFEST_IS_LIVE="$(jq -e --arg id "$REPEAT_MANIFEST_ID" \
  'select(.kind == "watch_start" and .watch_id == $id)' "$REPEAT_LOG" \
  >/dev/null 2>&1 \
  && [[ "$REPEAT_READY_ID" == "$REPEAT_ACTIVE_ID" ]] \
  && echo yes || echo no)"
check "repeat push manifest names a generation that published watch_start" \
  "$REPEAT_MANIFEST_IS_LIVE" "yes"
kill_watchers

# The real pre-push arm routes the producer through the stable daemon-log
# helper. Its descriptor must not prevent a later arm from reaching the live
# branch lock, receiving the existing ready generation, and publishing the
# matching attachment manifest.
kill_watchers
reset_state
LOG_LOCK_REPEAT_BRANCH="repeat-held-daemon-log"
LOG_LOCK_REPEAT_ACTIVE_ID="watch-abababababababababababab"
LOG_LOCK_REPEAT_KEY="$(pr_watch_branch_key "$LOG_LOCK_REPEAT_BRANCH")"
LOG_LOCK_REPEAT_DAEMON="$REPO/.git/pr-watch/${LOG_LOCK_REPEAT_KEY}.daemon.log"
LOG_LOCK_REPEAT_LOCK="$REPO/.git/pr-watch/${LOG_LOCK_REPEAT_KEY}.lock/owner.json"
mkdir -p "$REPO/.git/pr-watch"
LOG_LOCK_REPEAT_DIR_ID="$(pr_watch_state_directory_identity "$REPO/.git/pr-watch")"
(
  cd "$REPO" || exit 1
  exec env PR_WATCH_INTERVAL=1 PR_WATCH_IDLE_TIMEOUT=30 \
    PR_WATCH_MAX_LIFETIME=60 bash -c '
      source "$1" || exit 127
      shift
      pr_watch_exec_with_regular_log "$@"
    ' -- "$PIN/.agents/lib/pr-watch-state.sh" \
      "$LOG_LOCK_REPEAT_DAEMON" "$LOG_LOCK_REPEAT_DIR_ID" \
      bash "$SCRATCH_WATCHER" --branch "$LOG_LOCK_REPEAT_BRANCH" --pr 42 \
      --watch-id "$LOG_LOCK_REPEAT_ACTIVE_ID"
) >/dev/null 2>&1 &
LOG_LOCK_REPEAT_HELPER_PID=$!
LOG_LOCK_REPEAT_DEADLINE=$(( SECONDS + 10 ))
while (( SECONDS < LOG_LOCK_REPEAT_DEADLINE )); do
  [[ "$(jq -r 'select(.ready == true) | .watch_id // empty' \
      "$LOG_LOCK_REPEAT_LOCK" 2>/dev/null)" == "$LOG_LOCK_REPEAT_ACTIVE_ID" ]] \
    && break
  kill -0 "$LOG_LOCK_REPEAT_HELPER_PID" 2>/dev/null || break
  sleep 0.1
done
LOG_LOCK_REPEAT_SENTINEL="active-daemon-diagnostic-must-survive"
printf '%s\n' "$LOG_LOCK_REPEAT_SENTINEL" >> "$LOG_LOCK_REPEAT_DAEMON"
LOG_LOCK_REPEAT_COMMAND="git push origin refs/heads/local:refs/heads/$LOG_LOCK_REPEAT_BRANCH"
LOG_LOCK_REPEAT_SESSION="session-repeat-held-daemon-log"
LOG_LOCK_REPEAT_SCOPE="git-$(printf '%s' "$LOG_LOCK_REPEAT_SESSION" \
  | git -C "$REPO" hash-object --stdin)"
LOG_LOCK_REPEAT_COMMAND_HASH="$(printf '%s' "$LOG_LOCK_REPEAT_COMMAND" \
  | shasum -a 256 | awk '{print $1}')"
LOG_LOCK_REPEAT_MANIFEST_KEY="$(attachment_key_for \
  "$LOG_LOCK_REPEAT_SCOPE" "$LOG_LOCK_REPEAT_COMMAND_HASH")"
LOG_LOCK_REPEAT_OWNER_TOKEN="$(verdict_audit_process_start_token "$$")"
jq -nc --arg branch "$(git -C "$REPO" branch --show-current)" \
  --arg head "$(git -C "$REPO" rev-parse HEAD)" \
  --arg command_hash "$LOG_LOCK_REPEAT_COMMAND_HASH" \
  --arg scope "$LOG_LOCK_REPEAT_SCOPE" --argjson owner_pid "$$" \
  --arg owner_token "$LOG_LOCK_REPEAT_OWNER_TOKEN" \
  '{branch:$branch,head:$head,command_kind:"push",diff_hash:"fixture",command_hash:$command_hash,
    owner:{pid:$owner_pid,start_token:$owner_token},override:null,
    lifecycle:{session_scope:$scope,prompt_epoch:"1-1-0"}}' \
  > "$REPO/.agents/state/last-audit-handoff.json"
(cd "$REPO" && printf 'refs/heads/local %s refs/heads/%s %s\n' \
    "$SHA" "$LOG_LOCK_REPEAT_BRANCH" "$ZERO" \
  | CLAUDECODE=1 bash "$PREPUSH" origin "$TMP/origin.git" >/dev/null 2>&1)
LOG_LOCK_REPEAT_MANIFEST="$REPO/.git/pr-watch/${LOG_LOCK_REPEAT_MANIFEST_KEY}.json"
LOG_LOCK_REPEAT_READY_ID="$(jq -r \
  'select(.ready == true) | .watch_id // empty' \
  "$LOG_LOCK_REPEAT_LOCK" 2>/dev/null)"
LOG_LOCK_REPEAT_MANIFEST_ID="$(jq -r '.entries[0].watch_id // empty' \
  "$LOG_LOCK_REPEAT_MANIFEST" 2>/dev/null)"
if grep -Fxq "$LOG_LOCK_REPEAT_SENTINEL" \
    "$LOG_LOCK_REPEAT_DAEMON" 2>/dev/null; then
  LOG_LOCK_REPEAT_DIAGNOSTIC_STATE=preserved
else
  LOG_LOCK_REPEAT_DIAGNOSTIC_STATE=truncated
fi
if perl -MFcntl=:DEFAULT,:flock -e '
    sysopen(my $fh, $ARGV[0], O_RDWR | O_NONBLOCK) or exit 2;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
  ' "$LOG_LOCK_REPEAT_DAEMON" 2>/dev/null; then
  LOG_LOCK_REPEAT_DAEMON_STATE=available
else
  LOG_LOCK_REPEAT_DAEMON_STATE=held
fi
if [[ "$LOG_LOCK_REPEAT_READY_ID" == "$LOG_LOCK_REPEAT_ACTIVE_ID" \
   && "$LOG_LOCK_REPEAT_MANIFEST_ID" == "$LOG_LOCK_REPEAT_ACTIVE_ID" \
   && "$LOG_LOCK_REPEAT_DIAGNOSTIC_STATE" == preserved ]]; then
  ok "repeat push reuses a ready generation behind the real daemon-log boundary"
else
  no "repeat push reuses a ready generation behind the real daemon-log boundary" \
    "ready=[$LOG_LOCK_REPEAT_READY_ID] daemon_log=[$LOG_LOCK_REPEAT_DAEMON_STATE] manifest=[$LOG_LOCK_REPEAT_MANIFEST_ID] diagnostic=[$LOG_LOCK_REPEAT_DIAGNOSTIC_STATE]"
fi
kill_watchers
wait "$LOG_LOCK_REPEAT_HELPER_PID" 2>/dev/null || true

check "daemon dies on SIGTERM (traps must exit, not resume)" \
  "$(term_kills_daemon)" "died"

check "TERM tears down a stuck TERM-ignoring gh process group" \
  "$(term_kills_stuck_gh)" "watcher=dead gh=dead descendant=dead"

check "TERM at external-command PID publication reaps the owned group" \
  "$(term_at_external_launch_publication)" "rc=143 child=dead"

check "TERM cleanup reaps a TERM-ignoring output monitor" \
  "$(term_at_external_launch_publication ignoring-monitor)" "rc=143 child=dead monitor=dead"

check "TERM cleanup reaps a TERM-ignoring timeout monitor" \
  "$(term_at_external_launch_publication ignoring-timeout)" "rc=143 child=dead monitor=dead"

LAUNCH_TIMEOUT_RESULT="$(term_at_external_launch_publication stopped-watcher \
  2>"$TMP/launch-timeout-diagnostic")"
check "launch cleanup watchdog fails a stalled watcher" \
  "$LAUNCH_TIMEOUT_RESULT" "rc=124 child=dead"
if grep -Eq 'timeout=8s watcher=[1-9][0-9]* child=[1-9][0-9]*' \
     "$TMP/launch-timeout-diagnostic" \
   && grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+T' \
     "$TMP/launch-timeout-diagnostic"; then
  ok "launch timeout reports owned process identities and stopped state"
else
  no "launch timeout reports owned process identities and stopped state" \
    "$(cat "$TMP/launch-timeout-diagnostic")"
fi

check "command deadline tears down a stuck TERM-ignoring gh process group" \
  "$(timeout_kills_stuck_gh)" "watcher=dead gh=dead descendant=dead"

check "stale timeout monitor refuses a changed process generation" \
  "$(timeout_rejects_reused_generation)" "rc=0 term=absent completed=present"

check "external output is capped during writes and the process group is reaped" \
  "$(output_cap_kills_flooding_gh)" \
  "completed=absent watcher=dead rc=0 gh=dead descendant=dead"

# The gate's own exit code must be untouched by the arm.
reset_state
(cd "$REPO" && printf 'refs/heads/feat %s refs/heads/feat %s\n' "$SHA" "$ZERO" \
  | env -u CLAUDECODE -u CODEX_SANDBOX -u AGENT_GATED bash "$PREPUSH" origin url >/dev/null 2>&1)
check "hook still exits 0 after arming" "$?" "0"
kill_watchers

# A missing watcher must not break pushes for checkouts that predate this file.
reset_state
mv "$SCRATCH_WATCHER" "$TMP/moved-watcher.sh"
(cd "$REPO" && printf 'refs/heads/feat %s refs/heads/feat %s\n' "$SHA" "$ZERO" \
  | env -u CLAUDECODE -u CODEX_SANDBOX -u AGENT_GATED bash "$PREPUSH" origin url >/dev/null 2>&1)
check "absent watcher does not fail the push" "$?" "0"
mv "$TMP/moved-watcher.sh" "$SCRATCH_WATCHER"

# ── 9. argument parsing ──────────────────────────────────────────────────────
#
# `shift 2` on a flag with no value shifts nothing and leaves $1 in place, so the
# same case branch matches forever — the process spins instead of erroring.

echo
echo "## Argument parsing"

arg_result() {
  local out
  out="$(with_deadline 10 bash "$WATCHER" "$@" 2>&1)"
  if printf '%s' "$out" | grep -q "requires a value"; then echo "rejected"
  elif [[ -z "$out" ]]; then echo "hung-or-silent"
  else echo "other"; fi
}

check "--branch with no value is rejected, not spun on" "$(arg_result --branch)" "rejected"
check "--sha with no value is rejected"                 "$(arg_result --sha)"    "rejected"
check "--pr with no value is rejected"                  "$(arg_result --pr)"     "rejected"

check "--help prints the whole Env section, not a truncated one" \
  "$(bash "$WATCHER" --help 2>&1 | grep -c 'PR_WATCH_INTERVAL\|PR_WATCH_IDLE_TIMEOUT\|PR_WATCH_MAX_LIFETIME')" "3"

# Bash recursively evaluates variable contents in arithmetic expressions. An
# unvalidated environment value can therefore execute command substitution when
# the polling loop compares its timers.
ARITHMETIC_MARKER="$TMP/arithmetic-env-executed"
# Literal command substitution is the hostile input under test.
# shellcheck disable=SC2016
ARITHMETIC_VALUE='slot[$(printf compromised > '"$ARITHMETIC_MARKER"')]'
(cd "$REPO" && env PR_WATCH_IDLE_TIMEOUT="$ARITHMETIC_VALUE" \
  PR_WATCH_INTERVAL=1 PR_WATCH_MAX_LIFETIME=1 \
  bash "$WATCHER" --branch arithmetic-env --pr 42 \
    --watch-id watch-777777777777777777777777 >/dev/null 2>&1)
ARITHMETIC_RC=$?
check "polling timing env rejects arithmetic command substitution" \
  "$([[ -e "$ARITHMETIC_MARKER" ]] && echo executed || echo absent)/$ARITHMETIC_RC" \
  "absent/2"

# Decimal syntax alone is not a safe Bash-arithmetic boundary. Values wider than
# signed 64-bit wrap before comparisons (2^64 + 2 becomes 2), which can turn a
# caller-supplied limit into a plausible accepted value. Every public numeric
# watcher input must reject the value before any arithmetic expansion.
DECIMAL_OVERFLOW_TWO=18446744073709551618
DECIMAL_OVERFLOW_513=18446744073709552129

for WATCH_LIMIT_NAME in \
    PR_WATCH_INTERVAL PR_WATCH_IDLE_TIMEOUT PR_WATCH_MAX_LIFETIME \
    PR_WATCH_COMMAND_TIMEOUT; do
  (cd "$REPO" && with_deadline 10 env "$WATCH_LIMIT_NAME=$DECIMAL_OVERFLOW_TWO" \
    bash "$WATCHER" --branch "overflow-${WATCH_LIMIT_NAME}" --pr 42 --once \
      >/dev/null 2>&1)
  check "$WATCH_LIMIT_NAME rejects a decimal wider than Bash arithmetic" "$?" "2"
done

# Canonical decimal syntax matters too: Bash interprets a leading zero as octal,
# so `08` raises an arithmetic error while `0600` silently becomes 384. Exercise
# every public watcher limit even though only the zero-capable lifetime setting
# has a distinct parser.
for WATCH_LIMIT_NAME in \
    PR_WATCH_INTERVAL PR_WATCH_IDLE_TIMEOUT PR_WATCH_MAX_LIFETIME \
    PR_WATCH_COMMAND_TIMEOUT; do
  (cd "$REPO" && with_deadline 10 env "$WATCH_LIMIT_NAME=08" \
    bash "$WATCHER" --branch "leading-zero-${WATCH_LIMIT_NAME}" --pr 42 --once \
      >/dev/null 2>&1)
  check "$WATCH_LIMIT_NAME rejects a leading-zero decimal" "$?" "2"
done

STREAM_OVERFLOW_LOG="$TMP/stream-overflow.jsonl"
printf '%s\n' \
  '{"kind":"watch_start","watch_id":"stream-overflow"}' \
  '{"kind":"watch_end","watch_id":"stream-overflow","reason":"done"}' \
  > "$STREAM_OVERFLOW_LOG"

with_deadline 5 bash "$STREAM" "$STREAM_OVERFLOW_LOG" \
  "$DECIMAL_OVERFLOW_TWO" >/dev/null 2>&1
check "stream poll rejects a decimal wider than Bash arithmetic" "$?" "2"

for STREAM_LIMIT_NAME in PR_WATCH_STREAM_WAIT PR_WATCH_STREAM_MAX_EVENTS; do
  with_deadline 5 env "$STREAM_LIMIT_NAME=$DECIMAL_OVERFLOW_TWO" \
    bash "$STREAM" "$STREAM_OVERFLOW_LOG" 1 >/dev/null 2>&1
  check "$STREAM_LIMIT_NAME rejects a decimal wider than Bash arithmetic" "$?" "2"
done
with_deadline 5 env PR_WATCH_STREAM_MAX_BYTES="$DECIMAL_OVERFLOW_513" \
  bash "$STREAM" "$STREAM_OVERFLOW_LOG" 1 >/dev/null 2>&1
check "PR_WATCH_STREAM_MAX_BYTES rejects a decimal wider than Bash arithmetic" "$?" "2"

with_deadline 5 bash "$STREAM" "$STREAM_OVERFLOW_LOG" 08 >/dev/null 2>&1
check "stream poll rejects a leading-zero decimal" "$?" "2"

# Numerically valid is not operationally bounded. A one-hour poll already
# exceeds every interactive attachment wait in this plugin; reject anything
# larger at the public boundary rather than accepting multi-day sleeps.
IMPRACTICAL_POLL=3601
with_deadline 5 bash "$STREAM" "$STREAM_OVERFLOW_LOG" \
  "$IMPRACTICAL_POLL" >/dev/null 2>&1
check "stream poll rejects an impractical interval above its hard maximum" "$?" "2"

# The initial event-log wait is caller-controlled too. A value can fit the
# arithmetic parser yet retain a consumer for decades, so reject it before an
# absent-log path enters its first sleep.
IMPRACTICAL_STREAM_WAIT=999999999999999999
IMPRACTICAL_STREAM_WAIT_LOG="$TMP/impractical-stream-wait-missing.jsonl"
rm -f "$IMPRACTICAL_STREAM_WAIT_LOG"
with_deadline 3 env PR_WATCH_STREAM_WAIT="$IMPRACTICAL_STREAM_WAIT" \
  bash "$STREAM" "$IMPRACTICAL_STREAM_WAIT_LOG" 1 >/dev/null 2>&1
check "stream wait rejects a value above its operational hard maximum" "$?" "2"

(cd "$REPO" && with_deadline 5 env PR_WATCH_INTERVAL="$IMPRACTICAL_POLL" \
  bash "$WATCHER" --branch impractical-interval --pr 42 --once \
    >/dev/null 2>&1)
check "producer poll rejects an impractical interval above its hard maximum" "$?" "2"

for STREAM_LIMIT_NAME in \
    PR_WATCH_STREAM_WAIT PR_WATCH_STREAM_MAX_EVENTS PR_WATCH_STREAM_MAX_BYTES; do
  with_deadline 5 env "$STREAM_LIMIT_NAME=08" \
    bash "$STREAM" "$STREAM_OVERFLOW_LOG" 1 >/dev/null 2>&1
  check "$STREAM_LIMIT_NAME rejects a leading-zero decimal" "$?" "2"
done

# The pre-push cases reset the shared scratch state after the earlier attach
# fixtures. Recreate a valid one-entry manifest boundary here so the red side
# reaches aggregate-limit arithmetic instead of failing on a missing pathname.
mkdir -p "$ATTACH_DIR"
jq -nc --arg id "$ATTACH_ONE_ID" '{kind:"watch_start",watch_id:$id}' \
  > "$ATTACH_ONE_LOG"
jq -nc --arg id "$ATTACH_ONE_ID" \
  '{kind:"watch_end",watch_id:$id,reason:"one done"}' >> "$ATTACH_ONE_LOG"
for ATTACH_LIMIT_NAME in PR_WATCH_ATTACH_MAX_EVENTS PR_WATCH_ATTACH_MAX_BYTES; do
  ATTACH_OVERFLOW_MANIFEST="$(attach_claim_path "overflow-${ATTACH_LIMIT_NAME}")"
  jq -nc --arg log "$ATTACH_ONE_LOG" --arg id "$ATTACH_ONE_ID" '
    {schema:1,omitted_refs:0,entries:[
      {remote_ref:"refs/heads/attach-one",branch:"attach-one",watch_id:$id,event_log:$log}]}' \
    > "$ATTACH_OVERFLOW_MANIFEST"
  if [[ "$ATTACH_LIMIT_NAME" == PR_WATCH_ATTACH_MAX_BYTES ]]; then
    ATTACH_LIMIT_VALUE="$DECIMAL_OVERFLOW_513"
  else
    ATTACH_LIMIT_VALUE="$DECIMAL_OVERFLOW_TWO"
  fi
  with_deadline 5 env "$ATTACH_LIMIT_NAME=$ATTACH_LIMIT_VALUE" \
    bash "$ATTACH" "$ATTACH_OVERFLOW_MANIFEST" >/dev/null 2>&1
  check "$ATTACH_LIMIT_NAME rejects a decimal wider than Bash arithmetic" "$?" "2"
done

for ATTACH_LIMIT_NAME in PR_WATCH_ATTACH_MAX_EVENTS PR_WATCH_ATTACH_MAX_BYTES; do
  ATTACH_LEADING_ZERO_MANIFEST="$(attach_claim_path "leading-zero-${ATTACH_LIMIT_NAME}")"
  jq -nc --arg log "$ATTACH_ONE_LOG" --arg id "$ATTACH_ONE_ID" '
    {schema:1,omitted_refs:0,entries:[
      {remote_ref:"refs/heads/attach-one",branch:"attach-one",watch_id:$id,event_log:$log}]}' \
    > "$ATTACH_LEADING_ZERO_MANIFEST"
  with_deadline 5 env "$ATTACH_LIMIT_NAME=08" \
    bash "$ATTACH" "$ATTACH_LEADING_ZERO_MANIFEST" >/dev/null 2>&1
  check "$ATTACH_LIMIT_NAME rejects a leading-zero decimal" "$?" "2"
done

echo
printf 'pr-watch: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
