#!/usr/bin/env bash
# Tests for the refresh lock: scripts/refresh-installation.sh takes it, and
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

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
