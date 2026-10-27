#!/usr/bin/env bash
# Shared public-hook regressions; sourced by each host's boundary suite.
echo "## Startup discovers a release when both installed versions agree"
CONSUMER="$TMP/startup consumer"
FAKE_STATE="$TMP/startup-state"
mkdir -p "$CONSUMER/.agent-tooling" "$CONSUMER/.claude" "$CONSUMER/.agents/plugins" \
  "$CONSUMER/.github/copilot" "$CONSUMER/subdirectory" "$FAKE_STATE"
git init -q "$CONSUMER"
cp "$BOOTSTRAP" "$CONSUMER/.agent-tooling/$startup_host-plugin-bootstrap.sh"
cp "$FAKE_INSTALLER" "$CONSUMER/.agent-tooling/install.sh"
cp "$REPO_ROOT/templates/claude-plugin-bootstrap.json" "$CONSUMER/.claude/settings.json"
cp "$CONSUMER/.claude/settings.json" "$CONSUMER/.github/copilot/settings.json"
cp "$REPO_ROOT/.agents/plugins/marketplace.json" "$CONSUMER/.agents/plugins/marketplace.json"
printf '/.agents/state/\n/.claude/.*\n' > "$CONSUMER/.gitignore"
jq -nc '{schemaVersion:1,profile:"consumer",repository:"boxlite-ai/example-consumer",
  tooling:{repository:"boxlite-ai/agent-tooling",ref:"main"},checks:[{name:"test",command:"true"}]}' \
  > "$CONSUMER/.agent-tooling/profile.json"
chmod +x "$CONSUMER/.agent-tooling/"*.sh
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "equal-version fixture starts successfully" "$?" 0

# Fake only Git's remote boundary. All local repository operations remain real.
export STARTUP_REAL_GIT STARTUP_REMOTE_SHA STARTUP_POLL_LOG
STARTUP_REAL_GIT="$(command -v git)"
STARTUP_REMOTE_SHA=cccccccccccccccccccccccccccccccccccccccc
STARTUP_POLL_LOG="$TMP/startup-polls"
: > "$STARTUP_POLL_LOG"
cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$1" == ls-remote ]]; then
  printf 'poll\n' >> "$STARTUP_POLL_LOG"
  [[ "${STARTUP_OFFLINE:-0}" != 1 ]] || exit 128
  printf '%s\trefs/heads/main\n' "$STARTUP_REMOTE_SHA"
else
  exec "$STARTUP_REAL_GIT" "$@"
fi
GIT
chmod +x "$FAKE_BIN/git"
touch -t 200001010000 "$(common_git_dir)/agent-tooling/last-check"
run_new_release() {
  FAKE_AGENT_TOOLING_SHA="$STARTUP_REMOTE_SHA" FAKE_AGENT_TOOLING_VERSION=0.1.7 \
    FAKE_CODEX_MARKETPLACE_VERSION=0.1.7 FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.7 run_hook
}
AGENT_TOOLING_REFRESH=0 run_new_release > "$TMP/out" 2> "$TMP/err"
check_eq "refresh opt-out leaves equal old versions alone" "$?" 0
check_eq "opt-out does not poll" "$(test -f "$STARTUP_POLL_LOG" && cat "$STARTUP_POLL_LOG")" ""
export STARTUP_ENTRY_LOG
STARTUP_ENTRY_LOG="$TMP/runtime-entries"
cat > "$TMP/trace-entry" <<'TRACE'
trap 'printf "%s\n" "$0" >> "$STARTUP_ENTRY_LOG"; trap - DEBUG' DEBUG
TRACE
BASH_ENV="$TMP/trace-entry" run_new_release > "$TMP/out" 2> "$TMP/err"
check_eq "new release startup succeeds" "$?" 0
check_eq "equal old versions do not hide the new release" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" 0.1.7
check_eq "startup advances the recorded tooling revision" \
  "$(head -n1 "$(common_git_dir)/agent-tooling/current")" "$STARTUP_REMOTE_SHA"
grep -Fx "$(common_git_dir)/agent-tooling/$STARTUP_REMOTE_SHA/plugins/boxlite-agent-tooling/scripts/$startup_host-plugin-bootstrap.sh" \
  "$STARTUP_ENTRY_LOG" >/dev/null
runtime_status=$?
check_eq "startup executes the newly adopted host implementation" "$runtime_status" 0
check_eq "eligible startup polls once" "$(wc -l < "$STARTUP_POLL_LOG" 2>/dev/null | tr -d ' ')" 1
run_new_release > "$TMP/out" 2> "$TMP/err"
check_eq "startup within the polling interval succeeds" "$?" 0
check_eq "fresh polling stamp prevents another poll" "$(wc -l < "$STARTUP_POLL_LOG" 2>/dev/null | tr -d ' ')" 1
check_eq "repeat startup is quiet" "$(cat "$TMP/out")" ""
touch -t 200001010000 "$(common_git_dir)/agent-tooling/last-check"
STARTUP_OFFLINE=1 run_new_release > "$TMP/out" 2> "$TMP/err"
check_eq "offline startup keeps a valid installed release" "$?" 0
check_eq "offline startup retains the installed version" "$(head -n1 "$FAKE_STATE/plugin-version")" 0.1.7
if [[ "$startup_host" == claude ]]; then
  # Resume the same session after a successful start: stale .ok must not survive.
  touch -t 200001010000 "$(common_git_dir)/agent-tooling/last-check"
  AGENT_TOOLING_REFRESH_MINUTES=invalid run_new_release > "$TMP/out" 2> "$TMP/err"
  check_eq "invalid refresh configuration fails resumed startup" "$?" 1
  run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
  check_eq "failed resume revokes the previous session success" "$?" 2

  adopt_tooling_release dddddddddddddddddddddddddddddddddddddddd 0.1.8
  cp -p "$CONSUMER/.claude/settings.json" "$TMP/settings-before-timeout"
  AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.8 \
    FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_UPDATE=1 FAKE_CLAUDE_STALL_REINSTALL=1 \
    run_hook > "$TMP/out" 2> "$TMP/err"
  check_eq "stalled reinstall returns a failure" "$?" 1
  cmp -s "$TMP/settings-before-timeout" "$CONSUMER/.claude/settings.json"
  check_eq "deadline restores project settings byte for byte" "$?" 0
  run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
  check_eq "deadline leaves the session failed" "$?" 2

  echo "## Termination after uninstall restores settings before exit"
  touch "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-installed-here" "$FAKE_STATE/plugin-enabled"
  printf '0.1.7\n' > "$FAKE_STATE/plugin-version"
  rm -f "$FAKE_STATE/stalled-cli"
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"resume"}\n' "$SESSION_ID" > "$TMP/resume-input"
  (cd "$CONSUMER" &&
    PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$CONSUMER" FAKE_CLAUDE_STATE="$FAKE_STATE" \
    FAKE_CLAUDE_PROJECT_PATH="$CONSUMER" FAKE_AGENT_TOOLING_STATE="$FAKE_STATE" \
    FAKE_AGENT_TOOLING_VERIFY="$FAKE_VERIFY" FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.8 \
    FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_UPDATE=1 FAKE_CLAUDE_STALL_REINSTALL=1 \
    AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 \
    exec bash "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh" < "$TMP/resume-input"
  ) > "$TMP/interrupted-out" 2> "$TMP/interrupted-err" &
  bootstrap_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -s "$FAKE_STATE/stalled-cli" ]] || break
    sleep 0.05
  done
  [[ -s "$FAKE_STATE/stalled-cli" ]]
  check_eq "reinstall reaches the interrupted phase" "$?" 0
  kill -TERM "$bootstrap_pid" 2>/dev/null
  wait "$bootstrap_pid"
  check_eq "termination propagates the signal status" "$?" 143
  cmp -s "$TMP/settings-before-timeout" "$CONSUMER/.claude/settings.json"
  check_eq "termination restores tracked settings" "$?" 0
  run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
  check_eq "terminated resume remains blocked" "$?" 2
  stalled_pid="$(cat "$FAKE_STATE/stalled-cli")"
  kill -0 "$stalled_pid" 2>/dev/null
  check_eq "termination leaves no active CLI writer" "$?" 1
  kill -KILL "$stalled_pid" 2>/dev/null || true
fi
