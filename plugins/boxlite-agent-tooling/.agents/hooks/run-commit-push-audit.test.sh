#!/usr/bin/env bash
# Tests for .agents/hooks/run-commit-push-audit.sh — the headless commit/push audit
# producer, used when no agent runtime is available to spawn a subagent.
#
# This script was the largest untested surface in the plugin, and the risk is
# asymmetric: it is the thing that decides whether a blocked commit gets through, so
# every way it can produce a PASS matters far more than every way it can produce a
# FAIL. The suite is built around that. Most cases feed it output that is wrong in
# some specific way and assert the verdict lands on FAIL rather than being accepted —
# malformed JSON, a dossier bound to a different tree, PASS carrying findings, FAIL
# carrying none.
#
# The auditor itself is stubbed. What is under test is the CONTRACT around it: the
# sandbox flags it is invoked with, that the target command reaches it as JSON data
# rather than as instructions, and that its answer is checked before being written.
#
# Run with:  bash .agents/hooks/run-commit-push-audit.test.sh
# Exits non-zero on any failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/.agents/hooks/run-commit-push-audit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

with_deadline() { # seconds command [args...]
  local seconds="$1"; shift
  perl -MPOSIX -e '
    my $seconds = shift;
    my $pid = fork(); exit 125 unless defined $pid;
    if (!$pid) { POSIX::setpgid(0, 0); exec @ARGV; exit 125 }
    POSIX::setpgid($pid, $pid);
    $SIG{ALRM} = sub { kill 9, -$pid; waitpid($pid, 0); exit 124 };
    alarm $seconds; waitpid($pid, 0); alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$seconds" "$@"
}

command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }
SYSTEM_GIT="$(command -v git)"

# The subject has to satisfy the producer's OWN local pre-checks. run_agentic_audit
# calls run_local_checks first and short-circuits to FAIL on any finding, so a subject
# that breaks the Conventional Commit rule never reaches the auditor these tests are
# about — and every assertion below would pass for the wrong reason.
SUBJ='test(hooks): cover the audit producer'
CMD="git commit -m '$SUBJ'"

# A consumer-shaped repo with staged changes: the producer hashes `git diff --cached`
# into the dossier binding, so without a staged change every audit binds to the hash
# of nothing and the binding assertions below would pass vacuously.
setup() {  # [object format] -> repo path
  local object_format="${1:-sha1}" d; d="$(mktemp -d)"
  if [[ "$object_format" == "sha1" ]]; then
    git -C "$d" init -q
  else
    git -C "$d" init -q --object-format="$object_format"
  fi
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  mkdir -p "$d/.agents/hooks" "$d/.agents/state" "$d/.agents/lib" "$d/.agents/prompts" "$d/bin"
  cp "$RUNNER" "$REPO_ROOT/.agents/hooks/commit-push-audit.schema.json" \
    "$REPO_ROOT/.agents/hooks/auditor-control.sh" "$d/.agents/hooks/"
  cp "$REPO_ROOT/.agents/lib/subagent.sh" \
    "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
    "$REPO_ROOT/.agents/lib/auditor-override-state.sh" \
    "$REPO_ROOT/.agents/lib/auditor-control-state.sh" \
    "$REPO_ROOT/.agents/lib/hook-interactive-prompt.sh" \
    "$REPO_ROOT/.agents/lib/hook-host.sh" "$d/.agents/lib/"
  cp "$REPO_ROOT/.agents/prompts/"*.md "$d/.agents/prompts/"
  printf 'base\n' > "$d/f"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf 'change\n' >> "$d/f"
  git -C "$d" add -A
  printf '%s' "$d"
}

# Stub auditor. Echoes whatever CODEX_FAKE_OUTPUT holds into --output-last-message,
# and records the flags and the prompt it was handed so the contract can be asserted.
install_stub() {  # $1 = repo
  cat > "$1/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == "--version" ]] && { printf 'codex-cli fake\n'; exit 0; }
sandbox=""; disable_hooks=no; ephemeral=no; schema=""; out=""; approval=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ask-for-approval) approval="$2"; shift 2 ;;
    exec) shift ;;
    --disable) [[ "$2" == "hooks" ]] && disable_hooks=yes; shift 2 ;;
    --sandbox) sandbox="$2"; shift 2 ;;
    --cd) shift 2 ;;
    --ephemeral) ephemeral=yes; shift ;;
    --output-schema) schema="$2"; shift 2 ;;
    --output-last-message|-o) out="$2"; shift 2 ;;
    -) cat > "$FAKE_DIR/prompt.txt"; shift ;;
    *) shift ;;
  esac
done
evidence_path_json="$(sed -n 's/^Evidence path JSON: //p' "$FAKE_DIR/prompt.txt" | head -1)"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")' 2>/dev/null || true)"
evidence_expected_hash="$(sed -n 's/^Evidence SHA-256: //p' "$FAKE_DIR/prompt.txt" | head -1)"
evidence_readable=no
evidence_contains_marker=no
evidence_actual_hash=""
evidence_bytes=0
evidence_mode=""
evidence_dir_mode=""
if [[ -n "$evidence_path" && -r "$evidence_path" ]]; then
  evidence_readable=yes
  evidence_actual_hash="$(shasum -a 256 < "$evidence_path" | awk '{print $1}')"
  evidence_bytes="$(wc -c < "$evidence_path" | tr -d ' ')"
  rm -f "$FAKE_DIR/evidence-snapshot.txt"
  cp "$evidence_path" "$FAKE_DIR/evidence-snapshot.txt"
  chmod 600 "$FAKE_DIR/evidence-snapshot.txt"
  grep -q 'LARGE_DIFF_END' "$evidence_path" && evidence_contains_marker=yes
  if ! evidence_mode="$(stat -f '%Lp' "$evidence_path" 2>/dev/null)"; then
    evidence_mode="$(stat -c '%a' "$evidence_path" 2>/dev/null || true)"
  fi
  if ! evidence_dir_mode="$(stat -f '%Lp' "$(dirname "$evidence_path")" 2>/dev/null)"; then
    evidence_dir_mode="$(stat -c '%a' "$(dirname "$evidence_path")" 2>/dev/null || true)"
  fi
fi
{
  printf 'path_json=%s\n' "$evidence_path_json"
  printf 'expected_hash=%s\n' "$evidence_expected_hash"
  printf 'actual_hash=%s\n' "$evidence_actual_hash"
  printf 'readable=%s\n' "$evidence_readable"
  printf 'contains_marker=%s\n' "$evidence_contains_marker"
  printf 'bytes=%s\n' "$evidence_bytes"
  printf 'mode=%s\n' "$evidence_mode"
  printf 'dir_mode=%s\n' "$evidence_dir_mode"
} > "$FAKE_DIR/evidence-observation.txt"
{
  printf 'sandbox=%s\n' "$sandbox"
  printf 'disable_hooks=%s\n' "$disable_hooks"
  printf 'ephemeral=%s\n' "$ephemeral"
  printf 'approval=%s\n' "$approval"
  printf 'schema=%s\n' "$([[ -r "$schema" ]] && echo readable || echo MISSING)"
} > "$FAKE_DIR/flags.txt"
if [[ -n "${CODEX_FAKE_STDERR_KIB:-}" ]]; then
  # The CLI narrates its work on stderr, so this stream grows with the size of the
  # change being audited, not with the size of the answer. Written in one burst and
  # followed immediately by a normal exit, which is the shape the live poller cannot
  # catch: the status record lands before its next tick.
  perl -e 'print STDERR "s" x 1024 for 1 .. $ARGV[0]' "$CODEX_FAKE_STDERR_KIB"
fi
if [[ -n "${CODEX_FAKE_SCRATCH_KIB:-}" ]]; then
  # The real CLI writes its own stores (model cache, session state) while running.
  # `ulimit -f` is process-wide, so a ceiling sized for our evidence file strangles
  # those too — and the CLI then exits 0 having written NOTHING, output and stderr
  # alike. Reproduce that exact shape rather than a visible error.
  if ! dd if=/dev/zero of="$FAKE_DIR/cli-scratch.bin" bs=1024 \
       count="$CODEX_FAKE_SCRATCH_KIB" >/dev/null 2>&1; then
    exit 0
  fi
  rm -f "$FAKE_DIR/cli-scratch.bin"
fi
printf '%s' "${CODEX_FAKE_OUTPUT:-}" > "$out"
if [[ -n "${CODEX_FAKE_FIFO_SWAP:-}" ]]; then
  # Swap the result for a FIFO on the way out. Timing this against the live monitor is
  # deliberately not attempted: the case built on it asserts only that the gate reports
  # rather than stalls, and either layer satisfies that. The red-side proof lives in
  # verdict_audit_output_reason, where no monitor exists to race.
  rm -f "$out" && mkfifo "$out"
fi
if [[ -n "${CODEX_FAKE_MUTATE_FILE:-}" ]]; then
  printf '%s\n' "${CODEX_FAKE_MUTATE_CONTENT:-test(hooks): changed during audit}" \
    > "$CODEX_FAKE_MUTATE_FILE"
fi
if [[ -n "${CODEX_FAKE_DELAY:-}" ]]; then
  perl -e 'select(undef,undef,undef,$ARGV[0])' "$CODEX_FAKE_DELAY"
fi
exit "${CODEX_FAKE_RC:-0}"
STUB
  chmod +x "$1/bin/codex"
}

# A hostile headless auditor for lifecycle/resource-boundary tests. It accepts the
# discovery probe, then keeps both its result file and stderr live while a descendant
# does the same. Both processes record TERM but deliberately ignore it, so only a
# runner-owned TERM -> KILL escalation can finish before the outer test deadline.
install_resource_stub() {  # $1 = repo
  cat > "$1/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "--version" ]] && { printf 'codex-cli resource-test\n'; exit 0; }
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    --ask-for-approval|--disable|--sandbox|--cd|--output-schema) shift 2 ;;
    exec|--ephemeral) shift ;;
    -) cat >/dev/null; shift ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 125
: > "$out"
ln "$out" "$FAKE_DIR/observed-agent-output"
stderr_path="$(dirname "$out")/codex-stderr.log"
[[ ! -f "$stderr_path" ]] || ln "$stderr_path" "$FAKE_DIR/observed-agent-stderr"
printf '%s\n' "$$" > "$FAKE_DIR/resource-parent.pid"
mode="${CODEX_RESOURCE_MODE:-timeout}"
perl -MIO::Handle -e '
  my ($pid_path, $term_path, $mode) = @ARGV;
  open(my $pid_file, ">", $pid_path) or die $!;
  print {$pid_file} "$$\n"; close($pid_file);
  $SIG{TERM} = sub {
    open(my $term_file, ">>", $term_path) or return;
    print {$term_file} "descendant\n"; close($term_file);
  };
  $SIG{INT} = "IGNORE";
  STDERR->autoflush(1);
  # A cap case must actually REACH the ceiling it names inside the case window, and
  # only that one: at a few KiB per tick it reached neither and stopped on the
  # deadline instead, so the assertion held on a bound it could not have crossed.
  # Rates are chosen to cross in well under a second while keeping the overshoot to
  # roughly one poll interval, so the case stays fast and does not churn the disk.
  my $bytes = $mode eq "timeout" ? 128 : 32768;
  my $delay = $mode eq "timeout" ? 0.10 : 0.005;
  my $chunk = "d" x $bytes;
  # `capresult` holds stderr still so the RESULT ceiling is the only one reachable.
  exit 0 if $mode eq "capresult";
  while (1) { print STDERR $chunk; select(undef, undef, undef, $delay); }
' "$FAKE_DIR/resource-descendant.pid" "$FAKE_DIR/resource-term.log" "$mode" &
exec perl -MIO::Handle -e '
  my ($out_path, $term_path, $mode) = @ARGV;
  open(my $out_file, ">>", $out_path) or die $!;
  $out_file->autoflush(1); STDERR->autoflush(1);
  $SIG{TERM} = sub {
    open(my $term_file, ">>", $term_path) or return;
    print {$term_file} "parent\n"; close($term_file);
  };
  $SIG{INT} = "IGNORE";
  my $bytes = $mode eq "timeout" ? 128 : 32768;
  my $delay = $mode eq "timeout" ? 0.10 : 0.005;
  my $chunk = "p" x $bytes;
  # `capstderr` leaves the result untouched so only the stderr ceiling can be the one
  # that fires. Growing both would let the result cap — 64 times tighter — trip first
  # every time, which is how a single case ended up proving neither.
  my $grow_result = $mode ne "capstderr";
  my $grow_stderr = $mode ne "capresult";
  while (1) {
    print {$out_file} $chunk if $grow_result;
    print STDERR $chunk if $grow_stderr;
    select(undef, undef, undef, $delay);
  }
' "$out" "$FAKE_DIR/resource-term.log" "$mode"
STUB
  chmod +x "$1/bin/codex"

  cat > "$1/bin/run-resource-case" <<'CASE'
#!/usr/bin/env bash
set -u
cd "$CASE_REPO" || exit 125
exec env PATH="$CASE_REPO/bin:$PATH" \
  TMPDIR="$CASE_REPO/audit-tmp" \
  CLAUDE_PROJECT_DIR="$CASE_REPO" FAKE_DIR="$CASE_REPO" \
  CODEX_BIN="$CASE_REPO/bin/codex" CODEX_RESOURCE_MODE="$CASE_MODE" \
  COMMIT_PUSH_AUDITOR_TIMEOUT="$CASE_TIMEOUT" \
  CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
  bash "$CASE_REPO/.agents/hooks/run-commit-push-audit.sh" commit "$CASE_COMMAND"
CASE
  chmod +x "$1/bin/run-resource-case"
}

process_is_live() {  # pid
  local state
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -n "$state" && "$state" != Z* ]]
}

wait_for_process_exit() {  # pid
  local i
  for (( i = 0; i < 150; i++ )); do
    process_is_live "$1" || return 0
    perl -e 'select undef, undef, undef, 0.02'
  done
  return 1
}

run_resource_case() {  # repo, mode, configured timeout, outer deadline
  local repo="$1" mode="$2" configured_timeout="$3" outer_deadline="$4"
  local started ended pid descendant output_path stderr_path
  mkdir -p "$repo/audit-tmp"
  started="$(date +%s)"
  ( export CASE_REPO="$repo" CASE_MODE="$mode" CASE_TIMEOUT="$configured_timeout" \
      CASE_COMMAND="$CMD"
    with_deadline "$outer_deadline" "$repo/bin/run-resource-case"
  ) > "$repo/resource-runner.out" 2> "$repo/resource-runner.err"
  resource_case_rc=$?
  ended="$(date +%s)"
  resource_case_elapsed=$(( ended - started ))
  resource_case_verdict="$(jq -r '.verdict // "NONE"' \
    "$repo/.agents/state/last-audit.json" 2>/dev/null || printf 'NONE')"
  resource_case_finding="$(jq -r '.findings[0] // ""' \
    "$repo/.agents/state/last-audit.json" 2>/dev/null || true)"
  pid="$(cat "$repo/resource-parent.pid" 2>/dev/null || true)"
  descendant="$(cat "$repo/resource-descendant.pid" 2>/dev/null || true)"
  resource_case_processes_gone=yes
  wait_for_process_exit "$pid" || resource_case_processes_gone=no
  wait_for_process_exit "$descendant" || resource_case_processes_gone=no
  if [[ "$resource_case_processes_gone" != yes ]]; then
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$pid" 2>/dev/null || true
    [[ "$descendant" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$descendant" 2>/dev/null || true
  fi
  resource_case_term="$(sort -u "$repo/resource-term.log" 2>/dev/null | tr '\n' ',' || true)"
  output_path="$repo/observed-agent-output"
  stderr_path="$repo/observed-agent-stderr"
  resource_case_output_bytes=-1
  resource_case_stderr_bytes=-1
  [[ ! -f "$output_path" ]] \
    || resource_case_output_bytes="$(LC_ALL=C wc -c < "$output_path" | tr -d ' ')"
  [[ ! -f "$stderr_path" ]] \
    || resource_case_stderr_bytes="$(LC_ALL=C wc -c < "$stderr_path" | tr -d ' ')"
}

# Run the producer and echo the dossier it left behind ("" when it wrote none).
audit() {  # $1 = repo, $2 = fake auditor output, [$3 = mode], [$4 = command]
  local repo="$1" out="$2" mode="${3:-agentic}" target_command="${4:-$CMD}" real_mktemp
  ( cd "$repo" || exit
    if [[ -n "${AUDIT_TEST_TMPDIR:-}" ]]; then
      export TMPDIR="$AUDIT_TEST_TMPDIR"
      real_mktemp="$(command -v mktemp)"
      export AUDIT_TEST_REAL_MKTEMP="$real_mktemp"
      export PATH="$repo/bin:$PATH"
    fi
    PATH="$repo/bin:$PATH" CLAUDE_PROJECT_DIR="$repo" FAKE_DIR="$repo" \
      AUDIT_TEST_REAL_GIT="$SYSTEM_GIT" \
      AUDIT_TEST_REAL_SED="${AUDIT_TEST_REAL_SED:-}" \
      BASH_ENV="${BASH_ENV:-}" \
      AUDIT_TEST_SWAP_DIFF_ON_CALL="${AUDIT_TEST_SWAP_DIFF_ON_CALL:-}" \
      AUDIT_TEST_SWAP_DIFF_FILE="${AUDIT_TEST_SWAP_DIFF_FILE:-}" \
      CODEX_BIN="$repo/bin/codex" CODEX_FAKE_OUTPUT="$out" \
      CODEX_FAKE_SCRATCH_KIB="${CODEX_FAKE_SCRATCH_KIB:-}" \
      CODEX_FAKE_STDERR_KIB="${CODEX_FAKE_STDERR_KIB:-}" \
      CODEX_FAKE_FIFO_SWAP="${CODEX_FAKE_FIFO_SWAP:-}" \
      CODEX_FAKE_MUTATE_FILE="${CODEX_FAKE_MUTATE_FILE:-}" \
      CODEX_FAKE_MUTATE_CONTENT="${CODEX_FAKE_MUTATE_CONTENT:-}" \
      CODEX_COMMIT_PUSH_AUDIT_MODE="$mode" \
      bash "$repo/.agents/hooks/run-commit-push-audit.sh" commit "$target_command" \
  ) >/dev/null 2>&1
  cat "$repo/.agents/state/last-audit.json" 2>/dev/null || true
}

# A dossier that binds correctly to the repo, so only the field under test is wrong.
bound_output() {  # $1 = repo, $2 = verdict, $3 = findings JSON
  bound_output_for "$1" "$CMD" "$SUBJ" "$2" "$3"
}

bound_output_for() {  # repo, command, subject, verdict, findings JSON
  local repo="$1" target_command="$2" subject="$3" verdict="$4" findings="$5"
  local diff_hash cmd_hash subj_hash br hd
  br="$(git -C "$repo" branch --show-current)"
  hd="$(git -C "$repo" rev-parse HEAD)"
  diff_hash="$(git -C "$repo" diff --cached --no-ext-diff | shasum -a 256 | awk '{print $1}')"
  cmd_hash="$(printf '%s' "$target_command" | shasum -a 256 | awk '{print $1}')"
  subj_hash="$(printf '%s' "$subject" | shasum -a 256 | awk '{print $1}')"
  jq -nc --arg b "$br" --arg h "$hd" --arg d "$diff_hash" --arg c "$cmd_hash" \
         --arg s "$subj_hash" --arg v "$verdict" --argjson f "$findings" \
    '{branch:$b, head:$h, command_kind:"commit", diff_hash:$d, command_hash:$c,
      commit_subject_hash:$s, verdict:$v, findings:$f, advisories:[]}'
}

verdict_of() { printf '%s' "$1" | jq -r '.verdict // "NONE"' 2>/dev/null || printf 'NONE'; }
finding_of() { printf '%s' "$1" | jq -r '.findings[0] // ""' 2>/dev/null || printf ''; }

expect_fail() {  # $1 = label, $2 = dossier, $3 = substring the finding should contain
  local v; v="$(verdict_of "$2")"
  if [[ "$v" == "FAIL" ]] && [[ "$(finding_of "$2")" == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1  (verdict=$v finding=$(finding_of "$2"))"
  fi
}

echo "## Bad auditor output never becomes a PASS"
# Everything here is a way the auditor can answer wrongly. None may reach the gate as
# an allow — a producer that trusts its own subagent is not a gate, it is a rubber stamp.
R="$(setup)"; install_stub "$R"
expect_fail "not JSON at all → FAIL"            "$(audit "$R" 'this is not json')"        "malformed"
expect_fail "valid JSON, wrong shape → FAIL"    "$(audit "$R" '{"verdict":"PASS"}')"      "malformed"
expect_fail "verdict outside the enum → FAIL"   "$(audit "$R" "$(bound_output "$R" MAYBE '[]')")" "malformed"

echo
echo "## Headless timing follows the actual auditor process"
R_LIFECYCLE="$(setup)"; install_stub "$R_LIFECYCLE"
lifecycle_session=session-lifecycle
lifecycle_scope="git-$(printf '%s' "$lifecycle_session" | git -C "$R_LIFECYCLE" hash-object --stdin)"
lifecycle_epoch=1101-1102-11
printf '%s\n' "$lifecycle_epoch" \
  > "$R_LIFECYCLE/.agents/state/verdict-prompt-epoch.$lifecycle_scope"
lifecycle_output="$(bound_output "$R_LIFECYCLE" PASS '[]')"
( cd "$R_LIFECYCLE" && CLAUDE_PROJECT_DIR="$R_LIFECYCLE" FAKE_DIR="$R_LIFECYCLE" \
    CODEX_BIN="$R_LIFECYCLE/bin/codex" CODEX_FAKE_OUTPUT="$lifecycle_output" \
    CODEX_FAKE_DELAY=0.2 CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
    AUDITOR_SESSION_SCOPE="$lifecycle_scope" AUDITOR_PROMPT_EPOCH="$lifecycle_epoch" \
    AUDITOR_PROMPT_AFTER_SECONDS=0 \
    bash "$R_LIFECYCLE/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" \
) >/dev/null 2>&1
lifecycle_rc=$?
lifecycle_generation="$(printf '%s' "$CMD" | shasum -a 256 | awk '{print $1}')"
lifecycle_escalation="$R_LIFECYCLE/.agents/state/auditor-control/escalation.$lifecycle_scope.commit-push-auditor.$lifecycle_generation.json"
lifecycle_state="rc=$lifecycle_rc state=$(jq -r '.state // "missing"' "$lifecycle_escalation" 2>/dev/null) terminal=$(jq -r '.terminal // "missing"' "$lifecycle_escalation" 2>/dev/null)"
if [[ "$lifecycle_state" == "rc=0 state=closed terminal=PASS" ]]; then
  ok "the headless runner opens and closes escalation around the real Codex audit"
else
  bad "the headless runner opens and closes escalation around the real Codex audit ($lifecycle_state)"
fi
rm -rf "$R_LIFECYCLE"

echo
echo "## Headless auditor execution owns its deadline, process group, and live streams"
R_RESOURCE_TIMEOUT="$(setup)"; install_resource_stub "$R_RESOURCE_TIMEOUT"
run_resource_case "$R_RESOURCE_TIMEOUT" timeout 1 7
timeout_resource_state="rc=$resource_case_rc elapsed=$resource_case_elapsed verdict=$resource_case_verdict"
timeout_resource_state="$timeout_resource_state gone=$resource_case_processes_gone term=$resource_case_term"
timeout_finding_lower="$(printf '%s' "$resource_case_finding" | tr '[:upper:]' '[:lower:]')"
if [[ "$resource_case_rc" != 0 && "$resource_case_rc" != 124 ]] \
   && (( resource_case_elapsed < 7 )) \
   && [[ "$resource_case_verdict" == FAIL ]] \
   && [[ "$timeout_finding_lower" == *timeout* || "$timeout_finding_lower" == *timed\ out* ]] \
   && [[ "$resource_case_processes_gone" == yes ]] \
   && [[ "$resource_case_term" == *parent* && "$resource_case_term" == *descendant* ]]; then
  ok "configured headless timeout performs owned TERM-to-KILL teardown ($timeout_resource_state)"
else
  bad "configured headless timeout performs owned TERM-to-KILL teardown ($timeout_resource_state finding=$resource_case_finding)"
fi
rm -rf "$R_RESOURCE_TIMEOUT"

# The monitors are what bound a hostile auditor's two streams; the process-wide file
# ceiling is a runaway-disk guard three orders of magnitude above them, so it is no
# longer the first thing to bite. The byte bound below is therefore not the assertion
# that matters — the STOP REASON is. A case that merely stayed under a ceiling it was
# too slow to reach would pass while proving nothing, so the finding must name the
# active limit rather than the deadline.
R_RESOURCE_CAP="$(setup)"; install_resource_stub "$R_RESOURCE_CAP"
run_resource_case "$R_RESOURCE_CAP" cap 30 40
cap_finding_lower="$(printf '%s' "$resource_case_finding" | tr '[:upper:]' '[:lower:]')"
cap_resource_state="rc=$resource_case_rc elapsed=$resource_case_elapsed verdict=$resource_case_verdict"
cap_resource_state="$cap_resource_state output=$resource_case_output_bytes stderr=$resource_case_stderr_bytes"
cap_resource_state="$cap_resource_state gone=$resource_case_processes_gone term=$resource_case_term"
if [[ "$resource_case_rc" != 0 && "$resource_case_rc" != 124 ]] \
   && (( resource_case_elapsed < 30 )) \
   && [[ "$resource_case_verdict" == FAIL ]] \
   && [[ "$cap_finding_lower" == *"active limit"* ]] \
   && [[ "$cap_finding_lower" != *timeout* && "$cap_finding_lower" != *timed\ out* ]] \
   && (( resource_case_output_bytes >= 0 && resource_case_output_bytes <= 33554432 )) \
   && (( resource_case_stderr_bytes >= 0 && resource_case_stderr_bytes <= 33554432 )) \
   && [[ "$resource_case_processes_gone" == yes ]] \
   && [[ "$resource_case_term" == *parent* && "$resource_case_term" == *descendant* ]]; then
  ok "live result and stderr ceilings terminate and reap the hostile auditor ($cap_resource_state)"
else
  bad "live result and stderr ceilings terminate and reap the hostile auditor ($cap_resource_state finding=$resource_case_finding)"
fi
rm -rf "$R_RESOURCE_CAP"

# The case above grows BOTH streams, so it cannot name which ceiling stopped the
# writer: with a wide byte bound it still passes when only the stderr monitor works.
# This one holds stderr still, leaving the result ceiling as the only limit reachable,
# and bounds the result tightly enough that reaching it is the only way to pass.
R_RESOURCE_RESULT="$(setup)"; install_resource_stub "$R_RESOURCE_RESULT"
run_resource_case "$R_RESOURCE_RESULT" capresult 30 40
result_cap_state="rc=$resource_case_rc elapsed=$resource_case_elapsed verdict=$resource_case_verdict"
result_cap_state="$result_cap_state output=$resource_case_output_bytes stderr=$resource_case_stderr_bytes"
result_cap_state="$result_cap_state gone=$resource_case_processes_gone term=$resource_case_term"
result_finding_lower="$(printf '%s' "$resource_case_finding" | tr '[:upper:]' '[:lower:]')"
if [[ "$resource_case_rc" != 0 && "$resource_case_rc" != 124 ]] \
   && (( resource_case_elapsed < 30 )) \
   && [[ "$resource_case_verdict" == FAIL ]] \
   && [[ "$result_finding_lower" == *"active limit"* ]] \
   && [[ "$result_finding_lower" != *timeout* && "$result_finding_lower" != *timed\ out* ]] \
   && (( resource_case_output_bytes >= 65536 )) \
   && (( resource_case_stderr_bytes < 4194304 )) \
   && [[ "$resource_case_processes_gone" == yes ]] \
   && [[ "$resource_case_term" == *parent* ]]; then
  ok "the result ceiling alone stops an auditor whose stderr stays quiet ($result_cap_state)"
else
  bad "the result ceiling alone stops an auditor whose stderr stays quiet ($result_cap_state finding=$resource_case_finding)"
fi
rm -rf "$R_RESOURCE_RESULT"

# ...and the mirror: the result held still, leaving the stderr ceiling as the only
# limit that can stop the auditor.
R_RESOURCE_STDERR="$(setup)"; install_resource_stub "$R_RESOURCE_STDERR"
run_resource_case "$R_RESOURCE_STDERR" capstderr 30 40
stderr_cap_state="rc=$resource_case_rc elapsed=$resource_case_elapsed verdict=$resource_case_verdict"
stderr_cap_state="$stderr_cap_state output=$resource_case_output_bytes stderr=$resource_case_stderr_bytes"
stderr_cap_state="$stderr_cap_state gone=$resource_case_processes_gone term=$resource_case_term"
stderr_finding_lower="$(printf '%s' "$resource_case_finding" | tr '[:upper:]' '[:lower:]')"
if [[ "$resource_case_rc" != 0 && "$resource_case_rc" != 124 ]] \
   && (( resource_case_elapsed < 30 )) \
   && [[ "$resource_case_verdict" == FAIL ]] \
   && [[ "$stderr_finding_lower" == *"active limit"* ]] \
   && [[ "$stderr_finding_lower" != *timeout* && "$stderr_finding_lower" != *timed\ out* ]] \
   && (( resource_case_output_bytes == 0 )) \
   && (( resource_case_stderr_bytes >= 4194304 )) \
   && [[ "$resource_case_processes_gone" == yes ]] \
   && [[ "$resource_case_term" == *parent* && "$resource_case_term" == *descendant* ]]; then
  ok "the stderr ceiling alone stops an auditor whose result stays small ($stderr_cap_state)"
else
  bad "the stderr ceiling alone stops an auditor whose result stays small ($stderr_cap_state finding=$resource_case_finding)"
fi
rm -rf "$R_RESOURCE_STDERR"

# Deliver TERM from Bash's DEBUG hook after the model process group is forked
# but before the `$!` assignment publishes its PGID. The hostile stub keeps the
# group alive, so a missing ownership handoff is observed as a real leaked group.
R_LAUNCH_RACE="$(setup)"; install_resource_stub "$R_LAUNCH_RACE"
LAUNCH_RACE_ENV="$R_LAUNCH_RACE/launch-race.env"
LAUNCH_RACE_MARKER="$R_LAUNCH_RACE/launch-race"
mkdir -p "$R_LAUNCH_RACE/audit-tmp"
printf '%s\n' \
  'set -T' \
  'if [[ -n "${AUDIT_LAUNCH_RACE_MARKER:-}" && -z "${AUDIT_LAUNCH_RACE_OWNER_PID:-}" ]]; then' \
  '  export AUDIT_LAUNCH_RACE_OWNER_PID="$$"' \
  'fi' \
  '_audit_launch_debug() {' \
  '  [[ "$1" == '\''active_audit_pgid=$!'\'' ]] || return 0' \
  '  [[ -n "${AUDIT_LAUNCH_RACE_MARKER:-}" ]] || return 0' \
  '  mkdir "${AUDIT_LAUNCH_RACE_MARKER}.once" 2>/dev/null || return 0' \
  '  trap - DEBUG' \
  '  printf '\''%s\n'\'' "$!" > "${AUDIT_LAUNCH_RACE_MARKER}.pgid"' \
  '  kill -TERM "$AUDIT_LAUNCH_RACE_OWNER_PID"' \
  '}' \
  'trap '\''_audit_launch_debug "$BASH_COMMAND"'\'' DEBUG' \
  > "$LAUNCH_RACE_ENV"
(
  cd "$R_LAUNCH_RACE" || exit 125
  with_deadline 6 env BASH_ENV="$LAUNCH_RACE_ENV" \
    AUDIT_LAUNCH_RACE_MARKER="$LAUNCH_RACE_MARKER" \
    PATH="$R_LAUNCH_RACE/bin:$PATH" TMPDIR="$R_LAUNCH_RACE/audit-tmp" \
    CLAUDE_PROJECT_DIR="$R_LAUNCH_RACE" FAKE_DIR="$R_LAUNCH_RACE" \
    CODEX_BIN="$R_LAUNCH_RACE/bin/codex" CODEX_RESOURCE_MODE=timeout \
    COMMIT_PUSH_AUDITOR_TIMEOUT=20 CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
    bash "$R_LAUNCH_RACE/.agents/hooks/run-commit-push-audit.sh" commit "$CMD"
) > "$R_LAUNCH_RACE/launch-race.out" 2> "$R_LAUNCH_RACE/launch-race.err"
launch_race_rc=$?
launch_race_pgid="$(cat "${LAUNCH_RACE_MARKER}.pgid" 2>/dev/null || true)"
launch_race_deadline=$(( SECONDS + 2 ))
while [[ "$launch_race_pgid" =~ ^[1-9][0-9]*$ ]] \
      && kill -0 -- "-$launch_race_pgid" 2>/dev/null \
      && (( SECONDS < launch_race_deadline )); do
  perl -e 'select undef, undef, undef, 0.02'
done
if [[ "$launch_race_pgid" =~ ^[1-9][0-9]*$ ]] \
   && kill -0 -- "-$launch_race_pgid" 2>/dev/null; then
  launch_race_group=alive
  kill -KILL -- "-$launch_race_pgid" 2>/dev/null || true
else
  launch_race_group=dead
fi
if [[ "$launch_race_rc" == 143 && "$launch_race_group" == dead ]]; then
  ok "TERM at model-group publication reaps the owned group"
else
  bad "TERM at model-group publication reaps the owned group (rc=$launch_race_rc group=$launch_race_group pgid=$launch_race_pgid)"
fi
rm -rf "$R_LAUNCH_RACE"

echo
echo "## A dossier must bind to the tree it claims to have audited"
# The binding is what stops an audit of one change authorising a different one.
wrong_branch="$(bound_output "$R" PASS '[]' | jq -c '.branch = "some-other-branch"')"
expect_fail "wrong branch → FAIL"  "$(audit "$R" "$wrong_branch")"  "did not bind"
wrong_head="$(bound_output "$R" PASS '[]' | jq -c '.head = "0000000000000000000000000000000000000000"')"
expect_fail "wrong HEAD → FAIL"    "$(audit "$R" "$wrong_head")"    "did not bind"
wrong_diff="$(bound_output "$R" PASS '[]' | jq -c '.diff_hash = "'"$(printf 'x' | shasum -a 256 | awk '{print $1}')"'"')"
expect_fail "wrong diff hash → FAIL" "$(audit "$R" "$wrong_diff")"  "did not bind"
wrong_cmd="$(bound_output "$R" PASS '[]' | jq -c '.command_hash = "'"$(printf 'y' | shasum -a 256 | awk '{print $1}')"'"')"
expect_fail "wrong command hash → FAIL" "$(audit "$R" "$wrong_cmd")" "did not bind"

R_SWAP="$(setup)"; install_stub "$R_SWAP"
cat > "$R_SWAP/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -eu
joined=" $* "
if [[ "$joined" == *" diff --cached --no-ext-diff "* ]]; then
  count_file="$FAKE_DIR/git-diff-count"
  count="$(cat "$count_file" 2>/dev/null || printf '0')"
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [[ "$count" == "${AUDIT_TEST_SWAP_DIFF_ON_CALL:-}" ]]; then
    cat "$AUDIT_TEST_SWAP_DIFF_FILE"
    exit 0
  fi
fi
exec "$AUDIT_TEST_REAL_GIT" "$@"
GIT_STUB
chmod +x "$R_SWAP/bin/git"
cat > "$R_SWAP/swapped.diff" <<'SWAPPED_DIFF'
diff --git a/not-the-staged-source b/not-the-staged-source
--- a/not-the-staged-source
+++ b/not-the-staged-source
@@ -0,0 +1 @@
+SWAPPED_ONLY_DURING_CAPTURE
SWAPPED_DIFF
swap_out="$(AUDIT_TEST_SWAP_DIFF_ON_CALL=3 AUDIT_TEST_SWAP_DIFF_FILE="$R_SWAP/swapped.diff" \
  audit "$R_SWAP" "$(bound_output "$R_SWAP" PASS '[]')")"
expect_fail "swap-and-restore during capture cannot bind foreign evidence → FAIL" \
  "$swap_out" "source snapshot did not match"
rm -rf "$R_SWAP"

echo
echo "## Verdict and findings must agree"
# A self-contradictory answer is not a judgement, and resolving it either way would be
# the producer inventing one.
expect_fail "PASS carrying findings → FAIL" \
  "$(audit "$R" "$(bound_output "$R" PASS '["scope: unrelated change"]')")" "PASS with findings"
expect_fail "FAIL carrying no findings → FAIL" \
  "$(audit "$R" "$(bound_output "$R" FAIL '[]')")" "FAIL"
oversized_finding="$(awk 'BEGIN { for (i = 0; i < 1100; i++) printf "f" }')"
oversized_output="$(bound_output "$R" FAIL '["placeholder"]' \
  | jq -c --arg finding "$oversized_finding" '.findings = [$finding]')"
expect_fail "oversized finding string → FAIL" \
  "$(audit "$R" "$oversized_output")" "malformed"
too_many_output="$(bound_output "$R" PASS '[]' \
  | jq -c '.advisories = [range(0;33) | "advisory"]')"
expect_fail "too many advisory items → FAIL" \
  "$(audit "$R" "$too_many_output")" "malformed"

# Older native/headless fixtures predate the advisory channel. Absence means no
# advisory; it must not invalidate an otherwise exact, bound dossier. Unknown fields,
# wrong types, and over-budget arrays remain malformed above and below this boundary.
legacy_without_advisories="$(bound_output "$R" PASS '[]' | jq -c 'del(.advisories)')"
legacy_out="$(audit "$R" "$legacy_without_advisories")"
if [[ "$(verdict_of "$legacy_out")" == PASS ]] \
   && [[ "$(printf '%s' "$legacy_out" | jq -c '.advisories')" == '[]' ]]; then
  ok "missing legacy advisories normalize to an empty bounded array"
else
  bad "missing legacy advisories normalize to an empty bounded array (output=$legacy_out)"
fi
expect_fail "explicit null advisories remain malformed" \
  "$(audit "$R" "$(bound_output "$R" PASS '[]' | jq -c '.advisories = null')")" \
  "malformed"
expect_fail "unknown output fields remain malformed" \
  "$(audit "$R" "$(bound_output "$R" PASS '[]' | jq -c '.unexpected = true')")" \
  "malformed"

echo
echo "## A correct dossier is accepted"
# The one path that may produce an allow. Without this the suite could pass by making
# everything fail.
good="$(audit "$R" "$(bound_output "$R" PASS '[]')")"
[[ "$(verdict_of "$good")" == "PASS" ]] && ok "well-formed, bound, PASS → written as PASS" \
                                        || bad "well-formed, bound, PASS → written as PASS (verdict=$(verdict_of "$good"))"

echo
echo "## The process-wide file ceiling does not strangle the CLI itself"
# `ulimit -f` bounds EVERY file the auditor process writes, not just the two this
# runner caps. A ceiling sized for the evidence file also blocks the CLI's own
# stores, and the CLI then exits 0 having written no output and no stderr — which
# reaches validation as "malformed JSON" and names nothing that would locate it.
# 1 MiB of scratch stands in for those stores: comfortably past a 256 KiB ceiling,
# far under one that leaves the CLI room to run.
scratch_out="$(CODEX_FAKE_SCRATCH_KIB=1024 audit "$R" "$(bound_output "$R" PASS '[]')")"
[[ "$(verdict_of "$scratch_out")" == "PASS" ]] \
  && ok "an auditor writing its own 1 MiB store still returns a verdict" \
  || bad "an auditor writing its own 1 MiB store still returns a verdict (verdict=$(verdict_of "$scratch_out") findings=$(printf '%s' "$scratch_out" | jq -c '.findings' 2>/dev/null))"

# The result and the transcript are bounded separately. 256 KiB of stderr is four
# times the result ceiling and would have killed this audit while it was still
# working; a real audit of an ordinary commit narrates well past 64 KiB.
verbose_out="$(CODEX_FAKE_STDERR_KIB=256 audit "$R" "$(bound_output "$R" PASS '[]')")"
[[ "$(verdict_of "$verbose_out")" == "PASS" ]] \
  && ok "a verbose auditor transcript does not cap the audit" \
  || bad "a verbose auditor transcript does not cap the audit (verdict=$(verdict_of "$verbose_out") findings=$(printf '%s' "$verbose_out" | jq -c '.findings' 2>/dev/null))"

# A burst past the ceiling followed by a clean exit is the case the live poller cannot
# see: the status record exists before its next tick, so its loop ends without ever
# measuring the file. Only the check taken after the group is reaped catches this, and
# stderr has no second line of defence downstream the way the result does.
burst_out="$(CODEX_FAKE_STDERR_KIB=5120 audit "$R" "$(bound_output "$R" PASS '[]')")"
if printf '%s' "$burst_out" | jq -e '.verdict == "FAIL"' >/dev/null 2>&1 \
   && printf '%s' "$burst_out" | jq -e '.findings[0] | test("active limit")' >/dev/null 2>&1; then
  ok "a fast auditor that bursts past the stderr ceiling is still caught"
else
  bad "a fast auditor that bursts past the stderr ceiling is still caught (verdict=$(verdict_of "$burst_out") findings=$(printf '%s' "$burst_out" | jq -c '.findings' 2>/dev/null))"
fi

# Four cases cover the post-exit measurement, and only ONE of them is the red-side
# proof. Which one matters, because three of them look sufficient and are not:
#
#   * verdict_audit_output_reason, below — the reproducer, demonstrated under a FULL
#     revert of production to 29d39e5 rather than an internals swap. That revert leaves
#     no post-exit measurement at all, so the case reaches its defect check through the
#     smallest test-only adapter that supplies the old contract: both paths measured
#     with plain `<` redirection, implementing none of the fix. Observed there:
#
#       PASS  two healthy output files give no reason to stop
#       FAIL  a result that became a FIFO is reported, not waited on
#             (blocked until the deadline)
#       PASS  an oversized result is reported as a limit, not a state failure
#
#     Its two neighbours passing is what shows the adapter is faithful rather than
#     itself the failure signal. Nothing polls these paths, so no second layer can
#     answer first — unlike the end-to-end case, which is why that one claims less.
#   * verdict_audit_regular_file_bytes, below — the input contract underneath it
#     (regular, FIFO, symlink, directory, missing). Deterministic, but a contract test:
#     deleting the helper fails these on the missing symbol rather than on the defect.
#   * the burst case above — reaches the post-exit branch through the real runner;
#     removing that branch turns it from FAIL into a clean PASS.
#   * the end-to-end FIFO case at the end — integration only. It proves the gate
#     REPORTS rather than stalls, and deliberately claims nothing more: its FIFO
#     appears while the live monitor may still be polling, and that monitor emits the
#     same failure, so on any given run either layer may be the one that caught it.
# shellcheck source=../lib/verdict-audit-state.sh
source "$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
probe_dir="$(mktemp -d)"
printf 'hello' > "$probe_dir/regular"
mkfifo "$probe_dir/fifo"
ln -s "$probe_dir/regular" "$probe_dir/link"
probe_bytes="$(verdict_audit_regular_file_bytes "$probe_dir/regular" 2>/dev/null || printf 'refused')"
[[ "$probe_bytes" == 5 ]] \
  && ok "the post-exit measurement sizes a regular file" \
  || bad "the post-exit measurement sizes a regular file (got=$probe_bytes)"
# A FIFO must be REFUSED, not read: an ordinary open on one never returns.
probe_started="$SECONDS"
if verdict_audit_regular_file_bytes "$probe_dir/fifo" >/dev/null 2>&1; then
  bad "the post-exit measurement refuses a FIFO"
elif (( SECONDS - probe_started < 5 )); then
  ok "the post-exit measurement refuses a FIFO without blocking"
else
  bad "the post-exit measurement refuses a FIFO without blocking ($(( SECONDS - probe_started ))s)"
fi
if verdict_audit_regular_file_bytes "$probe_dir/link" >/dev/null 2>&1; then
  bad "the post-exit measurement refuses a symlink"
else
  ok "the post-exit measurement refuses a symlink"
fi
if verdict_audit_regular_file_bytes "$probe_dir/missing" >/dev/null 2>&1; then
  bad "the post-exit measurement refuses a missing path"
else
  ok "the post-exit measurement refuses a missing path"
fi
# A directory is the non-regular input that does NOT block: opening one can succeed,
# so only the `-f` check on the opened descriptor rejects it, and it would otherwise
# report a size that means nothing.
mkdir -p "$probe_dir/subdir"
if verdict_audit_regular_file_bytes "$probe_dir/subdir" >/dev/null 2>&1; then
  bad "the post-exit measurement refuses a directory"
else
  ok "the post-exit measurement refuses a directory"
fi

# The post-exit DECISION, called the way the runner calls it. This is the deterministic
# pre-fix reproducer the end-to-end case cannot be: no poller exists here to answer
# first, so the FIFO can only be seen by the code under test. Under a blocking read the
# call never returns, so it runs behind a deadline — rc=124 is the pre-fix hang, and it
# survives that change because the symbol stays put while its internals move.
printf 'small' > "$probe_dir/ok-result"
printf 'small' > "$probe_dir/ok-stderr"
reason_ok="$(with_deadline 10 bash -c '
  source "$1"; verdict_audit_output_reason "$2" 65536 "$3" 4194304' \
  x "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
  "$probe_dir/ok-result" "$probe_dir/ok-stderr" 2>/dev/null)"
reason_ok_rc=$?
[[ "$reason_ok_rc" != 124 && -z "$reason_ok" ]] \
  && ok "two healthy output files give no reason to stop" \
  || bad "two healthy output files give no reason to stop (rc=$reason_ok_rc reason=$reason_ok)"

reason_fifo="$(with_deadline 10 bash -c '
  source "$1"; verdict_audit_output_reason "$2" 65536 "$3" 4194304' \
  x "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
  "$probe_dir/fifo" "$probe_dir/ok-stderr" 2>/dev/null)"
reason_fifo_rc=$?
if (( reason_fifo_rc == 124 )); then
  bad "a result that became a FIFO is reported, not waited on (blocked until the deadline)"
elif [[ "$reason_fifo" == "output-state" ]]; then
  ok "a result that became a FIFO is reported, not waited on"
else
  bad "a result that became a FIFO is reported, not waited on (rc=$reason_fifo_rc reason=$reason_fifo)"
fi

# ...and the same call still reports an oversized stream rather than an unsafe one.
head -c 70000 /dev/zero > "$probe_dir/big-result"
reason_big="$(with_deadline 10 bash -c '
  source "$1"; verdict_audit_output_reason "$2" 65536 "$3" 4194304' \
  x "$REPO_ROOT/.agents/lib/verdict-audit-state.sh" \
  "$probe_dir/big-result" "$probe_dir/ok-stderr" 2>/dev/null)"
[[ "$reason_big" == "output-limit" ]] \
  && ok "an oversized result is reported as a limit, not a state failure" \
  || bad "an oversized result is reported as a limit, not a state failure (reason=$reason_big)"

rm -rf "$probe_dir"

# End to end: a result that stops being a regular file must make the gate REPORT, not
# stall. That is the whole claim — either the live monitor or the post-exit measurement
# may be what noticed, and this case cannot tell them apart, so it is not the red-side
# proof for either (verdict_audit_output_reason above is). The deadline still sits
# outside the call because a blocking read never returns, and an assertion inside a
# hung call is never reached.
fifo_repo="$(setup)"; install_stub "$fifo_repo"
fifo_dossier="$fifo_repo/.agents/state/last-audit.json"
rm -f "$fifo_dossier"
fifo_started="$SECONDS"
# Run INSIDE the fixture. The producer resolves its repo from the working directory, so
# without this it audits whatever repository the suite itself is running in — passing or
# failing on that tree's staged changes rather than on anything this case set up.
( cd "$fifo_repo" && with_deadline 60 env PATH="$fifo_repo/bin:$PATH" \
    CLAUDE_PROJECT_DIR="$fifo_repo" FAKE_DIR="$fifo_repo" \
    AUDIT_TEST_REAL_GIT="$SYSTEM_GIT" \
    CODEX_BIN="$fifo_repo/bin/codex" \
    CODEX_FAKE_OUTPUT="$(bound_output "$fifo_repo" PASS '[]')" \
    CODEX_FAKE_FIFO_SWAP=1 CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
    bash "$fifo_repo/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" \
  >/dev/null 2>&1 )
fifo_rc=$?
fifo_elapsed=$(( SECONDS - fifo_started ))
fifo_out="$(cat "$fifo_dossier" 2>/dev/null || true)"
# 124 is the deadline's own kill: reaching it means the audit hung, which is the bug.
# The finding must also name THIS failure — any quick FAIL would otherwise satisfy a
# regression that is specifically about unsafe output paths.
if (( fifo_rc != 124 )) && (( fifo_elapsed < 60 )) \
   && printf '%s' "$fifo_out" | jq -e '.verdict == "FAIL"' >/dev/null 2>&1 \
   && printf '%s' "$fifo_out" | jq -e '.findings[0] | test("stopped being regular files")' >/dev/null 2>&1; then
  ok "a result swapped for a FIFO fails as an unsafe output path, without hanging (${fifo_elapsed}s)"
else
  bad "a result swapped for a FIFO fails as an unsafe output path, without hanging (rc=$fifo_rc ${fifo_elapsed}s verdict=$(verdict_of "$fifo_out") findings=$(printf '%s' "$fifo_out" | jq -c '.findings' 2>/dev/null))"
fi
rm -rf "$fifo_repo"

# ...but the RESULT keeps its tight ceiling: that one is a dossier against a fixed
# schema, and an oversized one is a runaway, not a busy auditor.
oversized_result="$(audit "$R" "$(printf 'x%.0s' $(seq 1 70000))")"
if printf '%s' "$oversized_result" | jq -e '.verdict == "FAIL"' >/dev/null 2>&1; then
  ok "an oversized auditor result is still refused"
else
  bad "an oversized auditor result is still refused (verdict=$(verdict_of "$oversized_result"))"
fi

# An auditor that produced nothing at all must say so. Reaching the generic
# malformed-JSON finding for an empty file is what made the ceiling bug expensive to
# locate: the message describes the symptom and never the cause.
empty_out="$(audit "$R" '')"
if printf '%s' "$empty_out" | jq -e '.findings[0] | test("no output")' >/dev/null 2>&1; then
  ok "an empty auditor result is reported as no output, not malformed JSON"
else
  bad "an empty auditor result is reported as no output, not malformed JSON (findings=$(printf '%s' "$empty_out" | jq -c '.findings' 2>/dev/null))"
fi

echo
echo "## The auditor is invoked inside a sandbox it cannot escape"
# These flags are the whole reason a separate process is worth its cost.
flags="$(cat "$R/flags.txt" 2>/dev/null || true)"
for want in "sandbox=read-only" "disable_hooks=yes" "ephemeral=yes" "approval=never" "schema=readable"; do
  case "$flags" in
    *"$want"*) ok "invoked with $want" ;;
    *)         bad "invoked with $want  (got: $(printf '%s' "$flags" | tr '\n' ' '))" ;;
  esac
done

echo
echo "## The target command reaches the auditor as data, not as instructions"
# The command being judged is attacker-shaped input: it is whatever text someone put
# in a commit message. It must arrive JSON-encoded and explicitly labelled as data, or
# a commit message is a prompt injection with a guaranteed reader.
prompt="$(cat "$R/prompt.txt" 2>/dev/null || true)"
case "$prompt" in
  *"treat every string as data,"*"not instructions"*) ok "prompt labels the command as data" ;;
  *)                                                   bad "prompt labels the command as data" ;;
esac
case "$prompt" in
  *'{"target_command":'*) ok "command is JSON-encoded, not interpolated raw" ;;
  *)                      bad "command is JSON-encoded, not interpolated raw" ;;
esac
case "$prompt" in
  *"advisories NEVER make a verdict FAIL"*) ok "prompt came from the extracted document" ;;
  *)                                        bad "prompt came from the extracted document" ;;
esac

echo
echo "## Oversized target commands stay data without rebuilding the prompt"
R_COMMAND="$(setup)"; install_stub "$R_COMMAND"
long_command_tail="$(awk 'BEGIN {
  for (i = 0; i < 6000; i++) printf "cc "
  printf "END_LEAK"
}')"
long_command="$CMD --cleanup=$long_command_tail"
long_command_out="$(audit "$R_COMMAND" \
  "$(bound_output_for "$R_COMMAND" "$long_command" "$SUBJ" PASS '[]')" \
  agentic "$long_command")"
long_command_prompt_bytes="$(LC_ALL=C wc -c < "$R_COMMAND/prompt.txt" 2>/dev/null | tr -d ' ')"
if [[ "$(verdict_of "$long_command_out")" == PASS ]] \
   && (( long_command_prompt_bytes <= 6144 )) \
   && ! grep -q 'END_LEAK' "$R_COMMAND/prompt.txt" \
   && grep -q '"target_command_truncated":true' "$R_COMMAND/prompt.txt"; then
  ok "oversized target command is represented by bounded metadata (${long_command_prompt_bytes} bytes)"
else
  bad "oversized target command escaped the prompt bound (verdict=$(verdict_of "$long_command_out") bytes=$long_command_prompt_bytes)"
fi
rm -rf "$R_COMMAND"

echo
echo "## Large diffs stay out of the eager prompt"
R_LARGE="$(setup)"; install_stub "$R_LARGE"
awk 'BEGIN {
  for (i = 1; i <= 3000; i++)
    printf "large-diff-line-%05d payload payload payload payload\n", i
  print "LARGE_DIFF_END"
}' > "$R_LARGE/large-diff.txt"
for i in {1..80}; do
  printf -v long_name 'long-path-%03d-%0130d.txt' "$i" 0
  printf 'path %s\n' "$i" > "$R_LARGE/$long_name"
done
git -C "$R_LARGE" add -A
git -C "$R_LARGE" reset -q -- bin/codex
large_out="$(audit "$R_LARGE" "$(bound_output "$R_LARGE" PASS '[]')")"
large_prompt_bytes="$(wc -c < "$R_LARGE/prompt.txt" | tr -d ' ')"
if [[ "$(verdict_of "$large_out")" == PASS ]] && (( large_prompt_bytes <= 6144 )) \
    && ! grep -q 'LARGE_DIFF_END' "$R_LARGE/prompt.txt"; then
  ok "large diff and many long paths stay within the 6 KiB prompt ceiling (${large_prompt_bytes} bytes)"
else
  bad "large diff and many long paths stay within the 6 KiB prompt ceiling (verdict=$(verdict_of "$large_out") bytes=$large_prompt_bytes)"
fi
case "$(cat "$R_LARGE/prompt.txt")" in
  *"Evidence stat: bytes="*"changed_paths=82"*"Changed paths ("*"large-diff.txt"*"Changed paths truncated: yes"*)
    ok "bounded prompt carries evidence stat and changed paths" ;;
  *)
    bad "bounded prompt carries evidence stat and changed paths (metadata=$(grep -E '^Evidence stat:|^Changed paths' "$R_LARGE/prompt.txt" | tr '\n' ' '))" ;;
esac
evidence_observation="$(cat "$R_LARGE/evidence-observation.txt" 2>/dev/null || true)"
case "$evidence_observation" in
  *"readable=yes"*"contains_marker=yes"*)
    ok "sanitized evidence remains readable for the Codex process" ;;
  *)
    bad "sanitized evidence remains readable for the Codex process (got: $(printf '%s' "$evidence_observation" | tr '\n' ' '))" ;;
esac
case "$evidence_observation" in
  *"mode=400"*"dir_mode=700"*)
    ok "sanitized evidence is private to the audit process owner" ;;
  *)
    bad "sanitized evidence is private to the audit process owner (got: $(printf '%s' "$evidence_observation" | tr '\n' ' '))" ;;
esac
evidence_expected_hash="$(printf '%s\n' "$evidence_observation" | sed -n 's/^expected_hash=//p')"
evidence_actual_hash="$(printf '%s\n' "$evidence_observation" | sed -n 's/^actual_hash=//p')"
if [[ "$evidence_expected_hash" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$evidence_actual_hash" == "$evidence_expected_hash" ]]; then
  ok "prompt binds the private evidence file by SHA-256"
else
  bad "prompt binds the private evidence file by SHA-256 (expected=$evidence_expected_hash actual=$evidence_actual_hash)"
fi
evidence_path_json="$(printf '%s\n' "$evidence_observation" | sed -n 's/^path_json=//p')"
evidence_path="$(printf '%s' "$evidence_path_json" | jq -er 'select(type == "string")' 2>/dev/null || true)"
if [[ -n "$evidence_path" && ! -e "$evidence_path" ]]; then
  ok "private evidence is removed when the audit process exits"
else
  bad "private evidence is removed when the audit process exits (path=$evidence_path)"
fi
rm -rf "$R_LARGE"

echo
echo "## Lazy evidence has a hard consumption ceiling"
R_OVERSIZED_EVIDENCE="$(setup)"; install_stub "$R_OVERSIZED_EVIDENCE"
awk 'BEGIN {
  for (i = 1; i <= 7000; i++)
    printf "oversized-evidence-line-%05d payload payload payload payload\n", i
  print "END_UNBOUNDED_EVIDENCE"
}' > "$R_OVERSIZED_EVIDENCE/oversized-evidence.txt"
git -C "$R_OVERSIZED_EVIDENCE" add -A
git -C "$R_OVERSIZED_EVIDENCE" reset -q -- bin/codex
oversized_evidence_out="$(audit "$R_OVERSIZED_EVIDENCE" \
  "$(bound_output "$R_OVERSIZED_EVIDENCE" PASS '[]')")"
if [[ "$(verdict_of "$oversized_evidence_out")" == FAIL ]] \
   && [[ "$(finding_of "$oversized_evidence_out")" == *"262144-byte evidence limit"* ]] \
   && [[ ! -e "$R_OVERSIZED_EVIDENCE/prompt.txt" ]]; then
  ok "oversized sanitized evidence fails before Codex can read it"
else
  bad "oversized sanitized evidence reached Codex (verdict=$(verdict_of "$oversized_evidence_out") finding=$(finding_of "$oversized_evidence_out") prompt=$([[ -e "$R_OVERSIZED_EVIDENCE/prompt.txt" ]] && echo yes || echo no))"
fi
rm -rf "$R_OVERSIZED_EVIDENCE"

echo
echo "## Sanitization keeps paths but removes complete URL credentials"
R_REDACT="$(setup)"; install_stub "$R_REDACT"
long_path='ordinary-component-with-more-than-twenty-four-characters/configuration.txt'
mkdir -p "$R_REDACT/${long_path%/*}"
printf '%s\n' 'endpoint=https://averylongusername123456789:shortpass@db.example/service' \
  > "$R_REDACT/$long_path"
git -C "$R_REDACT" add "$long_path"
redact_out="$(audit "$R_REDACT" "$(bound_output "$R_REDACT" PASS '[]')")"
redacted_evidence="$(cat "$R_REDACT/evidence-snapshot.txt" 2>/dev/null || true)"
if [[ "$(verdict_of "$redact_out")" == PASS ]] \
    && [[ "$redacted_evidence" == *'<redacted-url-credentials>@db.example/service'* ]] \
    && [[ "$redacted_evidence" != *'shortpass'* ]]; then
  ok "long-user URL credentials are fully redacted"
else
  bad "long-user URL credentials are fully redacted"
fi
if [[ "$redacted_evidence" == *"diff --git a/$long_path b/$long_path"* ]] \
    && [[ "$redacted_evidence" != *'diff --git a/<redacted-token>'* ]]; then
  ok "ordinary long paths remain reviewable"
else
  bad "ordinary long paths remain reviewable"
fi
rm -rf "$R_REDACT"

R_PATH_SECRET="$(setup)"; install_stub "$R_PATH_SECRET"
secret_filename='ghp_ThisLooksLikeAToken12345678901234567890.txt'
printf '%s\n' 'ordinary content' > "$R_PATH_SECRET/$secret_filename"
git -C "$R_PATH_SECRET" add "$secret_filename"
path_secret_out="$(audit "$R_PATH_SECRET" "$(bound_output "$R_PATH_SECRET" PASS '[]')")"
if [[ "$(verdict_of "$path_secret_out")" == FAIL ]] \
    && [[ "$(finding_of "$path_secret_out")" == *'secret-like token'* ]] \
    && [[ ! -e "$R_PATH_SECRET/prompt.txt" ]]; then
  ok "secret-like filenames fail locally before any model-visible evidence"
else
  bad "secret-like filenames fail locally before any model-visible evidence"
fi
rm -rf "$R_PATH_SECRET"

echo
echo "## Commit message files bind the same subject the commit-msg hook sees"
R_FILE="$(setup)"; install_stub "$R_FILE"
file_subject='test(hooks): read subject from message file'
printf '%s\n%s\n' "$file_subject" 'body remains outside the subject hash' > "$R_FILE/message.txt"
file_command='git commit -F message.txt'
file_output="$(bound_output_for "$R_FILE" "$file_command" "$file_subject" PASS '[]')"
file_out="$(audit "$R_FILE" "$file_output" agentic "$file_command")"
file_expected_hash="$(printf '%s' "$file_subject" | shasum -a 256 | awk '{print $1}')"
file_prompt_hash="$(sed -n 's/^Expected commit subject hash: //p' "$R_FILE/prompt.txt" 2>/dev/null | head -1)"
if [[ "$(verdict_of "$file_out")" == PASS ]] && [[ "$file_prompt_hash" == "$file_expected_hash" ]]; then
  ok "git commit -F binds the message file first line"
else
  bad "git commit -F binds the message file first line (verdict=$(verdict_of "$file_out") prompt_hash=$file_prompt_hash)"
fi
rm -rf "$R_FILE"

R_FILE_ATTACHED="$(setup)"; install_stub "$R_FILE_ATTACHED"
printf '%s\n%s\n' "$file_subject" 'body remains outside the subject hash' \
  > "$R_FILE_ATTACHED/message.txt"
attached_file_command='git commit -Fmessage.txt'
attached_file_output="$(bound_output_for "$R_FILE_ATTACHED" \
  "$attached_file_command" "$file_subject" PASS '[]')"
attached_file_out="$(audit "$R_FILE_ATTACHED" "$attached_file_output" \
  agentic "$attached_file_command")"
attached_file_prompt_hash="$(sed -n 's/^Expected commit subject hash: //p' \
  "$R_FILE_ATTACHED/prompt.txt" 2>/dev/null | head -1)"
if [[ "$(verdict_of "$attached_file_out")" == PASS ]] \
   && [[ "$attached_file_prompt_hash" == "$file_expected_hash" ]]; then
  ok "git commit -Ffile binds the message file first line"
else
  bad "git commit -Ffile binds the message file first line (verdict=$(verdict_of "$attached_file_out") prompt_hash=$attached_file_prompt_hash)"
fi
rm -rf "$R_FILE_ATTACHED"

R_FILE_CHANGE="$(setup)"; install_stub "$R_FILE_CHANGE"
printf '%s\n' "$file_subject" > "$R_FILE_CHANGE/message.txt"
file_change_output="$(bound_output_for "$R_FILE_CHANGE" "$file_command" "$file_subject" PASS '[]')"
file_change_out="$(CODEX_FAKE_MUTATE_FILE="$R_FILE_CHANGE/message.txt" \
  audit "$R_FILE_CHANGE" "$file_change_output" agentic "$file_command")"
expect_fail "message file changing during audit → FAIL" "$file_change_out" "source changed"
rm -rf "$R_FILE_CHANGE"

echo
echo "## Commit message and staged-diff reads are bounded before Bash materializes them"
R_HUGE_SUBJECT="$(setup)"; install_stub "$R_HUGE_SUBJECT"
awk 'BEGIN { for (i = 0; i < 1048576; i++) printf "s" }' \
  > "$R_HUGE_SUBJECT/huge-message.txt"
cat > "$R_HUGE_SUBJECT/bin/subject-read-guard.bash" <<'SED_STUB'
sed() {
  local argument
for argument in "$@"; do
  if [[ "$argument" == */huge-message.txt ]]; then
    printf 'unbounded first-line read attempted\n' > "$FAKE_DIR/unbounded-subject-read"
    return 86
  fi
done
command "$AUDIT_TEST_REAL_SED" "$@"
}
SED_STUB
huge_subject_command='git commit -F huge-message.txt'
huge_subject_out="$(BASH_ENV="$R_HUGE_SUBJECT/bin/subject-read-guard.bash" \
  AUDIT_TEST_REAL_SED="$(command -v sed)" \
  audit "$R_HUGE_SUBJECT" '' local "$huge_subject_command")"
huge_subject_unbounded=no
[[ ! -e "$R_HUGE_SUBJECT/unbounded-subject-read" ]] || huge_subject_unbounded=yes
if [[ "$(verdict_of "$huge_subject_out")" == FAIL ]] \
   && [[ "$(finding_of "$huge_subject_out")" == *'subject exceeds 72 characters'* ]] \
   && [[ "$huge_subject_unbounded" == no ]]; then
  ok "newline-free -F subject is rejected through a bounded read"
else
  bad "newline-free -F subject is rejected through a bounded read (verdict=$(verdict_of "$huge_subject_out") finding=$(finding_of "$huge_subject_out") unbounded_read=$huge_subject_unbounded)"
fi
rm -rf "$R_HUGE_SUBJECT"

R_DIFF_MEMORY="$(setup)"; install_stub "$R_DIFF_MEMORY"
awk 'BEGIN {
  for (i = 0; i < 131072; i++)
    printf "bounded-diff-line-%06d payload payload payload payload payload payload\n", i
}' > "$R_DIFF_MEMORY/huge-staged-diff.txt"
git -C "$R_DIFF_MEMORY" add huge-staged-diff.txt
diff_memory_output="$(bound_output "$R_DIFF_MEMORY" PASS '[]')"
cat > "$R_DIFF_MEMORY/bin/git" <<'GIT_MEMORY_STUB'
#!/usr/bin/env bash
set -u
joined=" $* "
if [[ "$joined" == *" diff --cached --no-ext-diff "* \
   && ! -e "$FAKE_DIR/diff-memory-probe-armed" ]]; then
  : > "$FAKE_DIR/diff-memory-probe-armed"
  printf '%s\n' "$PPID" > "$FAKE_DIR/diff-memory-git-parent"
  while [[ ! -e "$FAKE_DIR/diff-memory-go" ]]; do
    perl -e 'select undef, undef, undef, 0.01'
  done
fi
exec "$AUDIT_TEST_REAL_GIT" "$@"
GIT_MEMORY_STUB
chmod +x "$R_DIFF_MEMORY/bin/git"
cat > "$R_DIFF_MEMORY/bin/run-diff-memory-case" <<'DIFF_MEMORY_CASE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$CASE_REPO/diff-memory-runner.pid"
cd "$CASE_REPO" || exit 125
exec env PATH="$CASE_REPO/bin:$PATH" CLAUDE_PROJECT_DIR="$CASE_REPO" \
  FAKE_DIR="$CASE_REPO" AUDIT_TEST_REAL_GIT="$CASE_REAL_GIT" \
  CODEX_BIN="$CASE_REPO/bin/codex" CODEX_FAKE_OUTPUT="$CASE_OUTPUT" \
  CODEX_COMMIT_PUSH_AUDIT_MODE=agentic \
  bash "$CASE_REPO/.agents/hooks/run-commit-push-audit.sh" commit "$CASE_COMMAND"
DIFF_MEMORY_CASE
chmod +x "$R_DIFF_MEMORY/bin/run-diff-memory-case"
(
  export CASE_REPO="$R_DIFF_MEMORY" CASE_REAL_GIT="$SYSTEM_GIT" \
    CASE_OUTPUT="$diff_memory_output" CASE_COMMAND="$CMD"
  with_deadline 12 "$R_DIFF_MEMORY/bin/run-diff-memory-case"
) > "$R_DIFF_MEMORY/diff-memory.out" 2> "$R_DIFF_MEMORY/diff-memory.err" &
diff_memory_controller=$!
for (( diff_memory_poll = 0; diff_memory_poll < 500; diff_memory_poll++ )); do
  [[ -e "$R_DIFF_MEMORY/diff-memory-probe-armed" ]] && break
  perl -e 'select undef, undef, undef, 0.01'
done
diff_memory_pid="$(cat "$R_DIFF_MEMORY/diff-memory-runner.pid" 2>/dev/null || true)"
diff_memory_base="$(ps -o rss= -p "$diff_memory_pid" 2>/dev/null | tr -d ' ' || true)"
: > "$R_DIFF_MEMORY/diff-memory-go"
diff_memory_peak="$diff_memory_base"
while process_is_live "$diff_memory_pid"; do
  diff_memory_rss="$(ps -o rss= -p "$diff_memory_pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ "$diff_memory_rss" =~ ^[0-9]+$ \
     && ( ! "$diff_memory_peak" =~ ^[0-9]+$ || diff_memory_rss -gt diff_memory_peak ) ]]; then
    diff_memory_peak="$diff_memory_rss"
  fi
  perl -e 'select undef, undef, undef, 0.01'
done
wait "$diff_memory_controller" 2>/dev/null
diff_memory_rc=$?
diff_memory_verdict="$(jq -r '.verdict // "NONE"' \
  "$R_DIFF_MEMORY/.agents/state/last-audit.json" 2>/dev/null || printf 'NONE')"
diff_memory_finding="$(jq -r '.findings[0] // ""' \
  "$R_DIFF_MEMORY/.agents/state/last-audit.json" 2>/dev/null || true)"
diff_memory_delta=-1
if [[ "$diff_memory_base" =~ ^[0-9]+$ && "$diff_memory_peak" =~ ^[0-9]+$ ]]; then
  diff_memory_delta=$(( diff_memory_peak - diff_memory_base ))
fi
if [[ "$diff_memory_rc" != 124 && "$diff_memory_verdict" == FAIL ]] \
   && [[ "$diff_memory_finding" == *'262144-byte evidence limit'* ]] \
   && (( diff_memory_delta >= 0 && diff_memory_delta <= 4096 )); then
  ok "huge staged diff reaches its file ceiling without growing the Bash heap (delta=${diff_memory_delta}KiB)"
else
  bad "huge staged diff reaches its file ceiling without growing the Bash heap (rc=$diff_memory_rc verdict=$diff_memory_verdict finding=$diff_memory_finding base=${diff_memory_base:-missing}KiB peak=${diff_memory_peak:-missing}KiB delta=${diff_memory_delta}KiB)"
fi
rm -rf "$R_DIFF_MEMORY"

R_PATH="$(setup)"; install_stub "$R_PATH"
special_tmp="$R_PATH/tmp-\"quoted"$'\n'"newline"
mkdir -p "$special_tmp"
cat > "$R_PATH/bin/mktemp" <<'MKTEMP_STUB'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == -d && -n "${AUDIT_TEST_TMPDIR:-}" ]]; then
  exec "$AUDIT_TEST_REAL_MKTEMP" -d "$AUDIT_TEST_TMPDIR/audit.XXXXXX"
fi
exec "$AUDIT_TEST_REAL_MKTEMP" "$@"
MKTEMP_STUB
chmod +x "$R_PATH/bin/mktemp"
path_out="$(AUDIT_TEST_TMPDIR="$special_tmp" audit \
  "$R_PATH" "$(bound_output "$R_PATH" PASS '[]')")"
path_json="$(sed -n 's/^Evidence path JSON: //p' "$R_PATH/prompt.txt" | head -1)"
decoded_path="$(printf '%s' "$path_json" | jq -er 'select(type == "string")' 2>/dev/null || true)"
path_observation="$(cat "$R_PATH/evidence-observation.txt" 2>/dev/null || true)"
if [[ "$(verdict_of "$path_out")" == PASS ]] \
    && [[ "$decoded_path" == "$special_tmp"/* ]] \
    && [[ "$(grep -c '^Evidence path JSON: ' "$R_PATH/prompt.txt")" == 1 ]] \
    && [[ "$path_observation" == *"readable=yes"* ]] \
    && [[ ! -e "$decoded_path" ]]; then
  ok "quoted and newline-containing TMPDIR is carried as one JSON path and cleaned"
else
  path_prefix=no
  [[ "$decoded_path" == "$special_tmp"/* ]] && path_prefix=yes
  bad "quoted and newline-containing TMPDIR is carried as one JSON path and cleaned (verdict=$(verdict_of "$path_out") finding=$(finding_of "$path_out") prefix=$path_prefix lines=$(grep -c '^Evidence path JSON: ' "$R_PATH/prompt.txt" 2>/dev/null) readable=$([[ "$path_observation" == *"readable=yes"* ]] && echo yes || echo no) cleaned=$([[ -n "$decoded_path" && ! -e "$decoded_path" ]] && echo yes || echo no) json=$path_json)"
fi
rm -rf "$R_PATH"

echo
echo "## Missing tooling fails closed, and says which piece is missing"
# The inline fallback prompt these replaced had already drifted from its document. A
# loud FAIL is the correct outcome: it keeps the gate shut and names the cause,
# instead of silently auditing against a superseded standard.
R2="$(setup)"; install_stub "$R2"; rm -f "$R2/.agents/lib/subagent.sh"
expect_fail "missing subagent.sh → FAIL naming it" "$(audit "$R2" "$(bound_output "$R2" PASS '[]')")" "subagent.sh"

R3="$(setup)"; install_stub "$R3"; rm -f "$R3/.agents/prompts/commit-push-runner.md"
expect_fail "missing prompt document → FAIL naming it" \
  "$(audit "$R3" "$(bound_output "$R3" PASS '[]')")" "commit-push-runner.md"

echo
echo "## Mode selection"
R4="$(setup)"; install_stub "$R4"
out="$( ( cd "$R4" && CLAUDE_PROJECT_DIR="$R4" FAKE_DIR="$R4" CODEX_BIN="$R4/bin/codex" \
          CODEX_COMMIT_PUSH_AUDIT_MODE=nonsense \
          bash "$R4/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" ) >/dev/null 2>&1
        cat "$R4/.agents/state/last-audit.json" 2>/dev/null || true )"
expect_fail "an unknown mode → FAIL naming it" "$out" "nonsense"

# local mode exists for offline diagnostics; it must still produce the same contract.
R5="$(setup)"
local_out="$(audit "$R5" '' local)"
case "$(verdict_of "$local_out")" in
  PASS|FAIL) ok "local mode writes a well-formed dossier" ;;
  *)         bad "local mode writes a well-formed dossier (verdict=$(verdict_of "$local_out"))" ;;
esac
bound="$(printf '%s' "$local_out" | jq -r '.branch')"
[[ "$bound" == "$(git -C "$R5" branch --show-current)" ]] && ok "local mode binds to the current branch" \
                                                          || bad "local mode binds to the current branch"

echo
echo "## Audit output is an atomic regular-file publication"
R_OUTPUT_LOCAL="$(setup)"
outside_output="$R_OUTPUT_LOCAL/outside-audit.json"
printf 'outside sentinel\n' > "$outside_output"
rm -f "$R_OUTPUT_LOCAL/.agents/state/last-audit.json"
ln -s "$outside_output" "$R_OUTPUT_LOCAL/.agents/state/last-audit.json"
local_symlink_out="$(audit "$R_OUTPUT_LOCAL" '' local)"
if [[ "$(cat "$outside_output")" == "outside sentinel" \
   && -f "$R_OUTPUT_LOCAL/.agents/state/last-audit.json" \
   && ! -L "$R_OUTPUT_LOCAL/.agents/state/last-audit.json" \
   && "$(verdict_of "$local_symlink_out")" == PASS ]]; then
  ok "local audit atomically replaces a symlink without following it"
else
  bad "local audit atomically replaces a symlink without following it"
fi

R_OUTPUT_AGENT="$(setup)"; install_stub "$R_OUTPUT_AGENT"
outside_agent_output="$R_OUTPUT_AGENT/outside-audit.json"
printf 'outside sentinel\n' > "$outside_agent_output"
rm -f "$R_OUTPUT_AGENT/.agents/state/last-audit.json"
ln -s "$outside_agent_output" "$R_OUTPUT_AGENT/.agents/state/last-audit.json"
agent_symlink_out="$(audit "$R_OUTPUT_AGENT" \
  "$(bound_output "$R_OUTPUT_AGENT" PASS '[]')")"
if [[ "$(cat "$outside_agent_output")" == "outside sentinel" \
   && -f "$R_OUTPUT_AGENT/.agents/state/last-audit.json" \
   && ! -L "$R_OUTPUT_AGENT/.agents/state/last-audit.json" \
   && "$(verdict_of "$agent_symlink_out")" == PASS ]]; then
  ok "normalized agentic audit atomically replaces a symlink without following it"
else
  bad "normalized agentic audit atomically replaces a symlink without following it"
fi

R_OUTPUT_FIFO="$(setup)"
rm -f "$R_OUTPUT_FIFO/.agents/state/last-audit.json"
mkfifo "$R_OUTPUT_FIFO/.agents/state/last-audit.json"
( cd "$R_OUTPUT_FIFO" && CLAUDE_PROJECT_DIR="$R_OUTPUT_FIFO" \
    CODEX_COMMIT_PUSH_AUDIT_MODE=local with_deadline 2 bash \
      "$R_OUTPUT_FIFO/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" \
      >/dev/null 2>&1 )
fifo_output_rc=$?
if [[ -f "$R_OUTPUT_FIFO/.agents/state/last-audit.json" ]]; then
  fifo_output_verdict="$(jq -r '.verdict // "NONE"' \
    "$R_OUTPUT_FIFO/.agents/state/last-audit.json" 2>/dev/null || echo NONE)"
else
  fifo_output_verdict=UNSAFE_PATH
fi
if [[ "$fifo_output_rc" == 0 && "$fifo_output_verdict" == PASS \
   && -f "$R_OUTPUT_FIFO/.agents/state/last-audit.json" \
   && ! -p "$R_OUTPUT_FIFO/.agents/state/last-audit.json" ]]; then
  ok "local audit replaces a FIFO without blocking"
else
  bad "local audit replaces a FIFO without blocking (rc=$fifo_output_rc verdict=$fifo_output_verdict)"
fi

echo
echo "## Push context is read from stable regular-file snapshots"
setup_push_context() { # repo -> prints synthetic command
  local repo="$1" context_dir diff_file meta_file pushed_hash command command_hash zeros
  context_dir="$(git -C "$repo" rev-parse --git-path codex-audit)"
  [[ "$context_dir" != /* ]] && context_dir="$repo/$context_dir"
  mkdir -p "$context_dir"
  diff_file="$context_dir/last-push-audit-context.diff"
  meta_file="$context_dir/last-push-audit-context.json"
  printf 'commit-subject %040d test(hooks): stable push context\n' 1 > "$diff_file"
  printf 'diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-base\n+change\n' >> "$diff_file"
  pushed_hash="$(shasum -a 256 < "$diff_file" | awk '{print $1}')"
  zeros="$(printf '%064d' 0)"
  command="git push --pre-push-hook remote=origin remote_url_sha256=$zeros ref_updates_sha256=$zeros pushed_diff_sha256=$pushed_hash"
  command_hash="$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')"
  jq -nc --arg branch "$(git -C "$repo" branch --show-current)" \
    --arg head "$(git -C "$repo" rev-parse HEAD)" --arg command_hash "$command_hash" \
    --arg ref_updates_hash "$zeros" --arg pushed_diff_hash "$pushed_hash" \
    --arg remote_name origin --arg remote_url_hash "$zeros" \
    '{branch:$branch,head:$head,command_hash:$command_hash,
      ref_updates_hash:$ref_updates_hash,pushed_diff_hash:$pushed_diff_hash,
      remote_name:$remote_name,remote_url_hash:$remote_url_hash}' > "$meta_file"
  printf '%s' "$command"
}
run_push_local() { # repo command
  ( cd "$1" && CLAUDE_PROJECT_DIR="$1" CODEX_COMMIT_PUSH_AUDIT_MODE=local \
      bash "$1/.agents/hooks/run-commit-push-audit.sh" push "$2" \
      >/dev/null 2>&1 )
}

R_PUSH_BASE="$(setup)"
push_command="$(setup_push_context "$R_PUSH_BASE")"
run_push_local "$R_PUSH_BASE" "$push_command"
push_base_rc=$?
push_base_verdict="$(jq -r '.verdict // "NONE"' "$R_PUSH_BASE/.agents/state/last-audit.json")"
[[ "$push_base_rc" == 0 && "$push_base_verdict" == PASS ]] \
  && ok "regular synthetic push context remains accepted" \
  || bad "regular synthetic push context remains accepted (rc=$push_base_rc verdict=$push_base_verdict)"

R_PUSH_META="$(setup)"
push_command="$(setup_push_context "$R_PUSH_META")"
push_dir="$(git -C "$R_PUSH_META" rev-parse --git-path codex-audit)"
[[ "$push_dir" != /* ]] && push_dir="$R_PUSH_META/$push_dir"
mv "$push_dir/last-push-audit-context.json" "$R_PUSH_META/outside-context.json"
ln -s "$R_PUSH_META/outside-context.json" "$push_dir/last-push-audit-context.json"
run_push_local "$R_PUSH_META" "$push_command"
meta_symlink_rc=$?
meta_symlink_verdict="$(jq -r '.verdict // "NONE"' "$R_PUSH_META/.agents/state/last-audit.json")"
[[ "$meta_symlink_rc" != 0 && "$meta_symlink_verdict" == FAIL ]] \
  && ok "symlink push metadata fails closed" \
  || bad "symlink push metadata fails closed (rc=$meta_symlink_rc verdict=$meta_symlink_verdict)"

R_PUSH_DIFF="$(setup)"
push_command="$(setup_push_context "$R_PUSH_DIFF")"
push_dir="$(git -C "$R_PUSH_DIFF" rev-parse --git-path codex-audit)"
[[ "$push_dir" != /* ]] && push_dir="$R_PUSH_DIFF/$push_dir"
mv "$push_dir/last-push-audit-context.diff" "$R_PUSH_DIFF/outside-context.diff"
ln -s "$R_PUSH_DIFF/outside-context.diff" "$push_dir/last-push-audit-context.diff"
run_push_local "$R_PUSH_DIFF" "$push_command"
diff_symlink_rc=$?
diff_symlink_verdict="$(jq -r '.verdict // "NONE"' "$R_PUSH_DIFF/.agents/state/last-audit.json")"
[[ "$diff_symlink_rc" != 0 && "$diff_symlink_verdict" == FAIL ]] \
  && ok "symlink push diff fails closed" \
  || bad "symlink push diff fails closed (rc=$diff_symlink_rc verdict=$diff_symlink_verdict)"

R_PUSH_FIFO="$(setup)"
push_command="$(setup_push_context "$R_PUSH_FIFO")"
push_dir="$(git -C "$R_PUSH_FIFO" rev-parse --git-path codex-audit)"
[[ "$push_dir" != /* ]] && push_dir="$R_PUSH_FIFO/$push_dir"
rm -f "$push_dir/last-push-audit-context.json"
mkfifo "$push_dir/last-push-audit-context.json"
( cd "$R_PUSH_FIFO" && CLAUDE_PROJECT_DIR="$R_PUSH_FIFO" \
    CODEX_COMMIT_PUSH_AUDIT_MODE=local with_deadline 2 bash \
      "$R_PUSH_FIFO/.agents/hooks/run-commit-push-audit.sh" push "$push_command" \
      >/dev/null 2>&1 )
fifo_context_rc=$?
if [[ -f "$R_PUSH_FIFO/.agents/state/last-audit.json" ]]; then
  fifo_context_verdict="$(jq -r '.verdict // "NONE"' \
    "$R_PUSH_FIFO/.agents/state/last-audit.json" 2>/dev/null || echo NONE)"
else
  fifo_context_verdict=UNSAFE_PATH
fi
if [[ "$fifo_context_rc" != 124 && "$fifo_context_rc" != 0 \
   && "$fifo_context_verdict" == FAIL ]]; then
  ok "FIFO push metadata fails closed without blocking"
else
  bad "FIFO push metadata fails closed without blocking (rc=$fifo_context_rc verdict=$fifo_context_verdict)"
fi

echo
echo "## SHA-256 Git repositories keep the audit contract end to end"
R_SHA256="$(setup sha256)"
cp "$REPO_ROOT/.agents/hooks/preflight-commit-push.sh" "$R_SHA256/.agents/hooks/"
sha256_head="$(git -C "$R_SHA256" rev-parse HEAD)"
( cd "$R_SHA256" && CLAUDE_PROJECT_DIR="$R_SHA256" \
    CODEX_COMMIT_PUSH_AUDIT_MODE=local \
    bash "$R_SHA256/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" \
    >/dev/null 2>&1 )
sha256_local_rc=$?
sha256_local_verdict="$(jq -r '.verdict // "NONE"' \
  "$R_SHA256/.agents/state/last-audit.json" 2>/dev/null || echo NONE)"
sha256_local_head="$(jq -r '.head // ""' \
  "$R_SHA256/.agents/state/last-audit.json" 2>/dev/null || true)"
sha256_gate_out="$(printf '%s' "$CMD" | jq -Rs '{tool_input:{command:.}}' \
  | ( cd "$R_SHA256" && CLAUDE_PROJECT_DIR="$R_SHA256" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='' \
      bash "$R_SHA256/.agents/hooks/preflight-commit-push.sh" ) 2>/dev/null)"
sha256_gate_rc=$?
if [[ -z "$sha256_gate_out" ]]; then
  sha256_gate_decision=allow
else
  sha256_gate_decision="$(printf '%s' "$sha256_gate_out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null || echo parse_error)"
fi
if [[ "$sha256_local_rc" == 0 && "$sha256_local_verdict" == PASS \
   && "$sha256_local_head" == "$sha256_head" && "${#sha256_head}" == 64 \
   && "$sha256_gate_rc" == 0 && "$sha256_gate_decision" == allow \
   && ! -e "$R_SHA256/.agents/state/last-audit.json" ]]; then
  ok "local PASS is accepted and consumed in a SHA-256 repository"
else
  bad "local PASS is accepted and consumed in a SHA-256 repository (producer_rc=$sha256_local_rc verdict=$sha256_local_verdict head_length=${#sha256_local_head} gate_rc=$sha256_gate_rc decision=$sha256_gate_decision audit_exists=$([[ -e "$R_SHA256/.agents/state/last-audit.json" ]] && echo yes || echo no))"
fi

R_SHA256_AGENT="$(setup sha256)"; install_stub "$R_SHA256_AGENT"
sha256_agent_head="$(git -C "$R_SHA256_AGENT" rev-parse HEAD)"
sha256_agent_out="$(audit "$R_SHA256_AGENT" \
  "$(bound_output "$R_SHA256_AGENT" PASS '[]')")"
if [[ "$(verdict_of "$sha256_agent_out")" == PASS \
   && "$(printf '%s' "$sha256_agent_out" | jq -r '.head // ""')" == "$sha256_agent_head" \
   && "${#sha256_agent_head}" == 64 ]]; then
  ok "agentic PASS normalizes in a SHA-256 repository"
else
  bad "agentic PASS normalizes in a SHA-256 repository (verdict=$(verdict_of "$sha256_agent_out") head_length=${#sha256_agent_head} finding=$(finding_of "$sha256_agent_out"))"
fi

sha256_schema_pattern="$(jq -r '.properties.head.pattern // ""' \
  "$REPO_ROOT/.agents/hooks/commit-push-audit.schema.json")"
sha256_schema_accepts="$(jq -nr --arg head "$sha256_head" --arg pattern "$sha256_schema_pattern" \
  '$head | test($pattern)' 2>/dev/null || echo false)"
[[ "$sha256_schema_accepts" == true ]] \
  && ok "audit output schema accepts a SHA-256 Git HEAD" \
  || bad "audit output schema accepts a SHA-256 Git HEAD (pattern=$sha256_schema_pattern)"

echo
echo "## A broken auditor binary is a FAIL, never an allow"
R6="$(setup)"; install_stub "$R6"
out="$( ( cd "$R6" && CLAUDE_PROJECT_DIR="$R6" FAKE_DIR="$R6" CODEX_BIN="$R6/bin/nonexistent" \
          bash "$R6/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" ) >/dev/null 2>&1
        cat "$R6/.agents/state/last-audit.json" 2>/dev/null || true )"
expect_fail "unusable CODEX_BIN → FAIL" "$out" "Codex CLI"

R7="$(setup)"; install_stub "$R7"
out="$( ( cd "$R7" && CLAUDE_PROJECT_DIR="$R7" FAKE_DIR="$R7" CODEX_BIN="$R7/bin/codex" \
          CODEX_FAKE_RC=1 CODEX_FAKE_OUTPUT='' \
          bash "$R7/.agents/hooks/run-commit-push-audit.sh" commit "$CMD" ) >/dev/null 2>&1
        cat "$R7/.agents/state/last-audit.json" 2>/dev/null || true )"
expect_fail "auditor exiting nonzero → FAIL" "$out" "failed to complete"

echo
echo "## Native auditor evidence is bounded like the headless route"
native_spec="$REPO_ROOT/.claude/agents/commit-push-auditor.md"
if grep -qF '65536-byte per-command ceiling' "$native_spec" \
   && grep -qF '262144-byte aggregate ceiling' "$native_spec" \
   && grep -qF 'before selecting output' "$native_spec" \
   && grep -qF 'an unbounded full diff' "$native_spec" \
   && grep -qF 'the evidence ceiling is a finding' "$native_spec"; then
  ok "native commit/push auditor has explicit model-visible evidence ceilings"
else
  bad "native commit/push auditor has explicit model-visible evidence ceilings"
fi

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
