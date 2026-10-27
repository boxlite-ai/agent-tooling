#!/usr/bin/env bash
# Tests for synchronization environment boundaries and the refresh lock:
# scripts/refresh-installation.sh takes the lock, and
# scripts/verify-installation.sh reports one that a killed refresh left behind.
#
# The refresh cases pin a held revision with .agent-tooling/hold, the one path that reaches
# the consumer's installer without touching the network, and substitute a stub installer
# that records having run. What each case asserts is therefore whether the lock let the
# refresh through, read from the stub's own marker rather than from anything this suite
# wrote. The notice cases read what verify-installation.sh prints.
#
# Run with:  bash plugins/boxlite-agent-tooling/scripts/refresh-installation.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$PLUGIN_ROOT/scripts/refresh-installation.sh"
VERIFY="$PLUGIN_ROOT/scripts/verify-installation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
rc=""
err=""
REPO="$TMP/consumer"
LOCK=""

report() {  # description, predicate exit status, details on failure
  if [[ "$2" == 0 ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (%s)\n' "$1" "$3"
  fi
}

make_consumer() {
  rm -rf "$REPO"
  mkdir -p "$REPO/.agent-tooling"
  git -C "$TMP" init --quiet consumer
  jq -n '{tooling: {repository: "boxlite-ai/agent-tooling", ref: "main"}}' \
    > "$REPO/.agent-tooling/profile.json"
  # A hold means the refresh never polls the remote: it only makes sure the held
  # revision is adopted, which is the installer call this suite watches for.
  printf '0123456789abcdef0123456789abcdef01234567\n' > "$REPO/.agent-tooling/hold"
  cat > "$REPO/.agent-tooling/install.sh" <<'STUB'
#!/usr/bin/env bash
printf 'installer ran\n' > "$(git rev-parse --path-format=absolute --git-common-dir)/agent-tooling/installer-ran"
STUB
  chmod +x "$REPO/.agent-tooling/install.sh"
  LOCK="$REPO/.git/agent-tooling/.refresh.lock"
  mkdir -p "$REPO/.git/agent-tooling"
}

# A consumer the installation check passes end to end: the recorded revision is the one the
# running tooling is at, and the hooks path is the one that revision installs. Without this
# the check exits early on an unrelated complaint, and a notice case would be comparing one
# failure to another instead of a warning to a clean run.
make_installed_consumer() {
  make_consumer
  rm -f "$REPO/.agent-tooling/hold"
  local checkout sha
  checkout="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
  sha="$(git -C "$checkout" rev-parse HEAD)"
  mkdir -p "$REPO/.git/agent-tooling/$sha/plugins"
  ln -s "$PLUGIN_ROOT" "$REPO/.git/agent-tooling/$sha/plugins/boxlite-agent-tooling"
  printf '%s\n' "$sha" > "$REPO/.git/agent-tooling/current"
  git -C "$REPO" config extensions.worktreeConfig true
  git -C "$REPO" config --worktree core.hooksPath "$PLUGIN_ROOT/.githooks"
}

run_refresh() {
  rm -f "$REPO/.git/agent-tooling/installer-ran"
  err="$(bash "$SCRIPT" "$REPO" 2>&1 >/dev/null)"
  rc=$?
}

run_verify() {
  err="$(bash "$VERIFY" "$REPO" 2>&1 >/dev/null)"
  rc=$?
}

installer_ran() { [[ -e "$REPO/.git/agent-tooling/installer-ran" ]]; }
lock_held() { [[ -d "$LOCK" ]]; }

# Portable "two hours ago" for touch, GNU first and BSD second.
stale_stamp() {
  date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M 2>/dev/null
}

echo "## The refresh takes the lock and leaves none behind"
make_consumer
run_refresh
installer_ran; report "an unlocked refresh reaches the installer" $? "rc=$rc err=$err"
lock_held; report "the lock is released on exit" $((! $?)) "lock still at $LOCK"

echo "## A lock that is held keeps other refreshes out"
make_consumer
mkdir -p "$LOCK"
run_refresh
installer_ran; report "a locked refresh does not run the installer" $((! $?)) "rc=$rc err=$err"
lock_held; report "and the lock is left exactly where it was" $? "lock gone from $LOCK"
# Breaking a lock here would race its holder, so an abandoned one outlives the refresh by
# design and is reported by the installation check instead of cleared behind a back.
run_refresh
installer_ran; report "a second attempt still stays out" $((! $?)) "rc=$rc err=$err"

echo "## An abandoned lock is reported where a person is looking"
# The bug this covers: the refresh takes its lock with a bare mkdir whose only failure path
# is a silent exit, so one killed run stops every later refresh, and the only record of it
# is a log nobody reads. The gates run this check on every commit and push.
make_installed_consumer
run_verify
clean_rc="$rc"
starts_clean=1
[[ "$clean_rc" == 0 ]] && starts_clean=0
report "the fixture passes the installation check to begin with" $starts_clean "rc=$rc err=$err"
mkdir -p "$LOCK"
run_verify
fresh_quiet=1
[[ "$err" != *"no refresh has completed"* ]] && fresh_quiet=0
report "a lock taken just now is not reported" $fresh_quiet "err=$err"
touch -t "$(stale_stamp)" "$LOCK"
run_verify
said_stale=1
[[ "$err" == *"no refresh has completed"* ]] && said_stale=0
report "a lock left for hours is reported" $said_stale "err=$err"
named_path=1
[[ "$err" == *"$LOCK"* ]] && named_path=0
report "and the report names the path to remove" $named_path "err=$err"
# The check still passes: a dead refresh leaves the recorded revision valid, just still.
still_passes=1
[[ "$rc" == 0 ]] && still_passes=0
report "the report is a warning, not a new failure" $still_passes "rc=$rc err=$err"

echo "## Environment discovery must succeed before invoking any installer"
export REAL_GIT
REAL_GIT="$(command -v git)"
mkdir "$TMP/bin"
cat > "$TMP/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
if [[ "$*" == 'rev-parse --local-env-vars' ]]; then
  case "$ENV_DISCOVERY" in
    failed) exit 1 ;;
    empty) exit 0 ;;
    malformed) printf '%s\n' GIT_DIR --invalid; exit 0 ;;
  esac
fi
exec "$REAL_GIT" "$@"
GIT_STUB
chmod +x "$TMP/bin/git"
for discovery in failed empty malformed; do
  for entry in refresh sync; do
    make_consumer
    err="$(cd "$REPO" && PATH="$TMP/bin:$PATH" ENV_DISCOVERY="$discovery" \
      bash "$PLUGIN_ROOT/scripts/$entry-installation.sh" "$REPO" 2>&1 >/dev/null)"
    rc=$?
    expected_rc=1
    [[ "$entry" == sync ]] && expected_rc=0
    [[ "$rc" == "$expected_rc" ]]; report "$entry preserves its exit contract on $discovery discovery" $? "rc=$rc err=$err"
    installer_ran; report "$entry refuses the installer on $discovery discovery" $((! $?)) "err=$err"
    [[ "$err" == *'repository-local Git environment'* ]]
    report "$entry explains $discovery discovery" $? "err=$err"
    lock_held; report "$entry leaves no lock on $discovery discovery" $((! $?)) "lock=$LOCK"
  done
done

echo "## Script boundaries clear repository variables and preserve caller input"
for entry in refresh sync; do
  make_consumer
  cat > "$REPO/.agent-tooling/install.sh" <<'ENV_INSTALLER'
#!/usr/bin/env bash
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_NAMESPACE; do
  [[ -z "${!name+x}" ]] || exit 42
done
[[ "$GIT_CONFIG_GLOBAL" == "$EXPECTED_CONFIG" && "$GIT_SSH_COMMAND" == 'ssh -oBatchMode=yes' ]] || exit 43
cat > "$(git rev-parse --path-format=absolute --git-common-dir)/agent-tooling/installer-ran"
ENV_INSTALLER
  err="$(cd "$REPO" && printf 'caller input\n' | GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" \
    GIT_INDEX_FILE="$TMP/other-index" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.value GIT_CONFIG_VALUE_0=local \
    GIT_NAMESPACE=consumer GIT_CONFIG_GLOBAL="$TMP/global-config" EXPECTED_CONFIG="$TMP/global-config" \
    GIT_SSH_COMMAND='ssh -oBatchMode=yes' bash "$PLUGIN_ROOT/scripts/$entry-installation.sh" "$REPO" 2>&1 >/dev/null)"
  rc=$?
  report "$entry accepts a valid repository environment" "$rc" "err=$err"
  [[ "$(cat "$REPO/.git/agent-tooling/installer-ran" 2>/dev/null)" == 'caller input' ]]
  report "$entry isolates repository variables while preserving input and transport config" $? "err=$err"
done

echo
echo "## Startup and lifecycle polling share one throttled lock owner"
make_installed_consumer
export REFRESH_POLL_LOG REFRESH_POLL_SHA REFRESH_CHILD
REFRESH_POLL_LOG="$TMP/polls"
REFRESH_CHILD="$TMP/remote-child"
REFRESH_POLL_SHA="$(head -n1 "$REPO/.git/agent-tooling/current")"
cat > "$TMP/bin/git" <<'REMOTE_GIT'
#!/usr/bin/env bash
if [[ "$1" == ls-remote ]]; then
  printf 'poll\n' >> "$REFRESH_POLL_LOG"
  if [[ "${REFRESH_DETACH:-0}" == 1 ]]; then
    (sleep 3; printf 'late output\n') &
    exit 0
  fi
  if [[ "${REFRESH_STALL:-0}" == 1 ]]; then
    trap '' TERM
    sleep 3 &
    printf '%s\n' "$!" > "$REFRESH_CHILD"
    wait
    exit 128
  fi
  printf '%s\trefs/heads/main\n' "$REFRESH_POLL_SHA"
else
  exec "$REAL_GIT" "$@"
fi
REMOTE_GIT
chmod +x "$TMP/bin/git"
run_due_refresh() {
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" --if-due "$REPO" > "$TMP/refresh-out" 2> "$TMP/refresh-err"
}
touch "$REPO/.git/agent-tooling/last-check"
run_due_refresh
[[ ! -e "$REFRESH_POLL_LOG" ]]; report "fresh stamp skips the remote inside the lock" $? "$(cat "$TMP/refresh-err")"
AGENT_TOOLING_REFRESH=0 AGENT_TOOLING_REFRESH_MINUTES=0 run_due_refresh
[[ ! -e "$REFRESH_POLL_LOG" ]]; report "refresh opt-out skips the remote" $? "$(cat "$TMP/refresh-err")"
touch -t 200001010000 "$REPO/.git/agent-tooling/last-check"
run_due_refresh
[[ "$(cat "$REFRESH_POLL_LOG" 2>/dev/null)" == poll ]]; report "expired stamp polls once" $? "$(cat "$TMP/refresh-err")"
run_due_refresh
[[ "$(cat "$REFRESH_POLL_LOG" 2>/dev/null)" == poll ]]; report "successful poll throttles the next caller" $? "$(cat "$TMP/refresh-err")"
AGENT_TOOLING_REFRESH_MINUTES=invalid run_due_refresh
[[ "$?" == 1 ]]; report "invalid interval fails closed" $? "$(cat "$TMP/refresh-err")"
started="$(date +%s)"
AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 AGENT_TOOLING_REFRESH_MINUTES=0 REFRESH_STALL=1 run_due_refresh
rc=$?
elapsed=$(( $(date +%s) - started ))
[[ "$rc" == 0 && "$elapsed" -le 2 ]]; report "stalled remote is bounded and retains the record" $? "rc=$rc elapsed=$elapsed"
[[ "$(head -n1 "$REPO/.git/agent-tooling/current")" == "$REFRESH_POLL_SHA" ]]
report "timeout does not advance the record" $? "record changed"
lock_held; report "timeout releases its refresh lock" $((! $?)) "lock remains"
child="$(cat "$REFRESH_CHILD")"
kill -0 "$child" 2>/dev/null
report "timeout stops the remote's descendant" $((! $?)) "child $child remains"
started="$(date +%s)"
AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 AGENT_TOOLING_REFRESH_MINUTES=0 REFRESH_DETACH=1 run_due_refresh
elapsed=$(( $(date +%s) - started ))
[[ "$elapsed" -le 2 ]]; report "deadline also stops inherited pipes after the direct child exits" $? "elapsed=$elapsed"
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
