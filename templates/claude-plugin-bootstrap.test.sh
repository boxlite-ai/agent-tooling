#!/usr/bin/env bash
# Tests the trusted Claude Code project bootstrap without touching the developer's
# real Claude configuration. The fake CLI implements only the public plugin commands
# used at the boundary and records every mutation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_FILE="$REPO_ROOT/templates/claude-plugin-bootstrap.json"
MERGE_FILTER="$REPO_ROOT/templates/merge-claude-plugin-settings.jq"
PRECANONICAL_SETTINGS="$REPO_ROOT/templates/fixtures/claude-plugin-bootstrap-precanonical.json"
BOOTSTRAP="$REPO_ROOT/templates/claude-plugin-bootstrap.sh"
FAKE_CLAUDE="$REPO_ROOT/templates/fixtures/fake-claude-plugin-cli.sh"
FAKE_INSTALLER="$REPO_ROOT/templates/fixtures/fake-agent-tooling-install.sh"
FAKE_VERIFY="$REPO_ROOT/templates/fixtures/fake-agent-tooling-verify.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (got=$got want=$want)"; fi
}
check_ge() {
  local desc="$1" got="$2" want="$3"
  if (( got >= want )); then ok "$desc"; else bad "$desc (got=$got want>=$want)"; fi
}
command_count() { grep -c -E "$1" "$FAKE_STATE/commands" 2>/dev/null || true; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

echo "## Project settings and hook shape"
[[ -r "$SETTINGS_FILE" ]] && ok "bootstrap settings template exists" \
                              || bad "bootstrap settings template exists"
[[ -r "$BOOTSTRAP" ]] && ok "bootstrap script exists" || bad "bootstrap script exists"
if jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
  ok "bootstrap settings are valid JSON"
else
  bad "bootstrap settings are valid JSON"
fi
jq -e '
  .extraKnownMarketplaces["boxlite-agent-tooling"].source == {
    source: "github", repo: "boxlite-ai/agent-tooling", ref: "main"
  } and
  .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "settings declare a typed GitHub marketplace and enable the plugin" \
  || bad "settings declare a typed GitHub marketplace and enable the plugin"
actual_top_level="$(jq -c '.' "$SETTINGS_FILE" 2>/dev/null)"
canonical_top_level="$(jq -c '{hooks, enabledPlugins, extraKnownMarketplaces}' "$SETTINGS_FILE" 2>/dev/null)"
check_eq "settings use Claude Code canonical top-level key order" \
  "$actual_top_level" "$canonical_top_level"
actual_session_hook="$(jq -c '.hooks.SessionStart[0].hooks[0]' "$SETTINGS_FILE" 2>/dev/null)"
canonical_session_hook="$(jq -c '
  .hooks.SessionStart[0].hooks[0] |
  {type, command, args, timeout, statusMessage}
' "$SETTINGS_FILE" 2>/dev/null)"
check_eq "SessionStart hook uses Claude Code canonical key order" \
  "$actual_session_hook" "$canonical_session_hook"
if jq -s -f "$MERGE_FILTER" "$PRECANONICAL_SETTINGS" "$SETTINGS_FILE" \
  > "$TMP/merged-settings.json" 2>/dev/null; then
  merge_status=0
else
  merge_status="$?"
fi
check_eq "documented merge accepts settings from the previous template" "$merge_status" 0
merged_session_hook="$(jq -c '.hooks.SessionStart[0].hooks[0]' "$TMP/merged-settings.json" 2>/dev/null)"
check_eq "documented merge replaces the previous hook with canonical key order" \
  "$merged_session_hook" "$canonical_session_hook"
check_eq "documented merge keeps one managed SessionStart hook" \
  "$(jq -r '.hooks.SessionStart | length' "$TMP/merged-settings.json" 2>/dev/null)" 1
check_eq "documented merge keeps one managed prompt gate" \
  "$(jq -r '.hooks.UserPromptSubmit | length' "$TMP/merged-settings.json" 2>/dev/null)" 1
check_eq "hook runs only when Claude creates a session context" \
  "$(jq -r '.hooks.SessionStart[0].matcher // "MISSING"' "$SETTINGS_FILE" 2>/dev/null)" \
  "^(startup|resume|fork|clear)$"
hook_command="$(jq -r '.hooks.SessionStart[0].hooks[0].command // "MISSING"' "$SETTINGS_FILE" 2>/dev/null)"
check_eq "hook uses exec form instead of a shell command string" "$hook_command" "/usr/bin/env"
check_eq "hook uses Claude's trusted project root" \
  "$(jq -c '.hooks.SessionStart[0].hooks[0].args // []' "$SETTINGS_FILE" 2>/dev/null)" \
  '["bash","${CLAUDE_PROJECT_DIR}/.agent-tooling/claude-plugin-bootstrap.sh"]'
check_eq "hook handler is a command" \
  "$(jq -r '.hooks.SessionStart[0].hooks[0].type // "MISSING"' "$SETTINGS_FILE" 2>/dev/null)" \
  "command"
check_eq "prompt gate uses the same trusted script in check mode" \
  "$(jq -c '.hooks.UserPromptSubmit[0].hooks[0].args // []' "$SETTINGS_FILE" 2>/dev/null)" \
  '["bash","-c","/usr/bin/env bash \"$1\" --check; status=$?; [ \"$status\" -eq 0 ] && exit 0; exit 2","agent-tooling-prompt-gate","${CLAUDE_PROJECT_DIR}/.agent-tooling/claude-plugin-bootstrap.sh"]'
check_eq "prompt gate is a command hook" \
  "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].type // "MISSING"' "$SETTINGS_FILE" 2>/dev/null)" \
  "command"
gate_command="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // "MISSING"' "$SETTINGS_FILE" 2>/dev/null)"
gate_args=()
while IFS= read -r gate_arg; do
  gate_args+=("$gate_arg")
done < <(jq -r '.hooks.UserPromptSubmit[0].hooks[0].args[]?' "$SETTINGS_FILE" 2>/dev/null)

# The fixture starts in a subdirectory to prove the script resolves the repository
# root rather than treating the hook process's current directory as the project.
CONSUMER="$TMP/consumer repo"
mkdir -p "$CONSUMER/.agent-tooling" "$CONSUMER/.claude" "$CONSUMER/subdirectory"
git init -q "$CONSUMER"
cp "$BOOTSTRAP" "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh" 2>/dev/null || true
cp "$FAKE_INSTALLER" "$CONSUMER/.agent-tooling/install.sh"
cp "$SETTINGS_FILE" "$CONSUMER/.claude/settings.json" 2>/dev/null || true
chmod +x "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh" 2>/dev/null || true
chmod +x "$CONSUMER/.agent-tooling/install.sh"
jq -nc '{
  schemaVersion: 1,
  profile: "consumer",
  repository: "boxlite-ai/example-consumer",
  tooling: {repository: "boxlite-ai/agent-tooling", ref: "main"},
  checks: [{name: "test", command: "true"}]
}' > "$CONSUMER/.agent-tooling/profile.json"

FAKE_BIN="$TMP/bin"
FAKE_STATE="$TMP/claude-state"
SESSION_ID="fixture-session-123"
mkdir -p "$FAKE_BIN" "$FAKE_STATE"
cp "$FAKE_CLAUDE" "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

run_hook_at() {
  local target="$1" session_id="${2:-$SESSION_ID}" source="${3:-startup}"
  (cd "$target/subdirectory" && \
    printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"SessionStart\",\"source\":\"$source\"}" | \
    PATH="$FAKE_BIN:$PATH" \
    CLAUDE_PROJECT_DIR="$target" \
    FAKE_CLAUDE_STATE="$FAKE_STATE" \
    FAKE_CLAUDE_PROJECT_PATH="$target" \
    FAKE_AGENT_TOOLING_STATE="$FAKE_STATE" \
    FAKE_AGENT_TOOLING_VERIFY="$FAKE_VERIFY" \
    "$hook_command" bash "$target/.agent-tooling/claude-plugin-bootstrap.sh")
}
run_hook() {
  run_hook_at "$CONSUMER"
}
run_gate_at() {
  local target="$1" session_id="${2:-$SESSION_ID}" event_name="${3:-UserPromptSubmit}"
  local gate_arg
  local resolved_gate_args=()
  for gate_arg in "${gate_args[@]}"; do
    resolved_gate_args+=("${gate_arg//\$\{CLAUDE_PROJECT_DIR\}/$target}")
  done
  (cd "$target/subdirectory" && \
    printf '%s\n' "{\"session_id\":\"$session_id\",\"hook_event_name\":\"$event_name\",\"prompt\":\"test\"}" | \
    PATH="$FAKE_BIN:$PATH" \
    CLAUDE_PROJECT_DIR="$target" \
    FAKE_CLAUDE_STATE="$FAKE_STATE" \
    FAKE_CLAUDE_PROJECT_PATH="$target" \
    FAKE_AGENT_TOOLING_STATE="$FAKE_STATE" \
    FAKE_AGENT_TOOLING_VERIFY="$FAKE_VERIFY" \
    "$gate_command" "${resolved_gate_args[@]}")
}
run_gate() {
  run_gate_at "$CONSUMER"
}
common_git_dir() {
  local path
  path="$(git -C "$CONSUMER" rev-parse --git-common-dir)"
  [[ "$path" == /* ]] || path="$CONSUMER/$path"
  printf '%s' "$path"
}
adopt_tooling_release() {
  local sha="$1" version="$2"
  (cd "$CONSUMER" && \
    FAKE_AGENT_TOOLING_STATE="$FAKE_STATE" \
    FAKE_AGENT_TOOLING_VERIFY="$FAKE_VERIFY" \
    FAKE_AGENT_TOOLING_SHA="$sha" \
    FAKE_AGENT_TOOLING_VERSION="$version" \
    AGENT_TOOLING_SYNC_ACTIVE=1 \
    ./.agent-tooling/install.sh >/dev/null)
}
adopted_claude_version() {
  local git_dir record
  git_dir="$(common_git_dir)"
  record="$(head -n1 "$git_dir/agent-tooling/current")"
  jq -r '.version' \
    "$git_dir/agent-tooling/$record/plugins/boxlite-agent-tooling/.claude-plugin/plugin.json"
}
check_failed_start() {
  local desc="$1" pattern="$2" start_status="$3"
  check_eq "$desc exits nonzero" "$start_status" 1
  check_eq "$desc emits no fake decision JSON" "$(wc -c < "$TMP/out" | tr -d ' ')" 0
  grep -q "$pattern" "$TMP/err" \
    && ok "$desc has actionable stderr" \
    || bad "$desc has actionable stderr (stderr=$(cat "$TMP/err"))"
  run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
  check_eq "$desc blocks the next user prompt" "$?" 2
  grep -q "$pattern" "$TMP/gate-err" \
    && ok "$desc reaches the prompt gate" \
    || bad "$desc reaches the prompt gate (stderr=$(cat "$TMP/gate-err"))"
}

echo
echo "## First trusted session installs tooling and the Claude plugin once"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "first SessionStart succeeds" "$?" 0
jq -e '
  (.systemMessage | test("/reload-plugins")) and
  (.hookSpecificOutput.hookEventName == "SessionStart") and
  .hookSpecificOutput.reloadSkills == true
' "$TMP/out" >/dev/null 2>&1 \
  && ok "first install tells both the user and Claude to reload plugins" \
  || bad "first install tells both the user and Claude to reload plugins (stdout=$(cat "$TMP/out"))"
check_eq "canonical marketplace is added once" \
  "$(command_count '^plugin marketplace add boxlite-ai/agent-tooling@main --scope project$')" 1
check_eq "project plugin is installed once and accepts the non-TTY prompt" \
  "$(command_count '^plugin install boxlite-agent-tooling@boxlite-agent-tooling --scope project --yes$')" 1
check_eq "tooling installer runs once" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" 1
check_eq "adopted checkout expects plugin release 0.1.5" "$(adopted_claude_version)" "0.1.5"
check_eq "installed plugin reports release 0.1.5" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"
grep -q '^sync=1$' "$FAKE_STATE/installer-calls" \
  && ok "SessionStart marks the tooling install as lifecycle-triggered" \
  || bad "SessionStart marks the tooling install as lifecycle-triggered"
if ! grep -q 'fixture installer progress\|Successfully added\|Successfully installed' "$TMP/out"; then
  ok "bootstrap suppresses child-command chatter from SessionStart context"
else
  bad "bootstrap suppresses child-command chatter from SessionStart context"
fi
run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
check_eq "successful SessionStart opens the user-prompt gate" "$?" 0
check_eq "open prompt gate is silent" "$(wc -c < "$TMP/gate-out" | tr -d ' ')" 0
run_gate_at "$CONSUMER" "$SESSION_ID" SessionStart > "$TMP/gate-out" 2> "$TMP/gate-err"
check_eq "check mode rejects the wrong hook event" "$?" 2
grep -q 'expected UserPromptSubmit' "$TMP/gate-err" \
  && ok "wrong hook event has actionable stderr" \
  || bad "wrong hook event has actionable stderr (stderr=$(cat "$TMP/gate-err"))"
run_gate_at "$CONSUMER" never-started-session > "$TMP/gate-out" 2> "$TMP/gate-err"
check_eq "a session with no successful bootstrap is blocked" "$?" 2
grep -q 'did not complete' "$TMP/gate-err" \
  && ok "missing session stamp has actionable stderr" \
  || bad "missing session stamp has actionable stderr (stderr=$(cat "$TMP/gate-err"))"
mv "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh" \
  "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh.saved"
run_gate > "$TMP/gate-out" 2> "$TMP/gate-err"
check_eq "a missing gate script still blocks the prompt" "$?" 2
grep -q 'No such file' "$TMP/gate-err" \
  && ok "missing gate script reports the missing dependency" \
  || bad "missing gate script reports the missing dependency (stderr=$(cat "$TMP/gate-err"))"
mv "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh.saved" \
  "$CONSUMER/.agent-tooling/claude-plugin-bootstrap.sh"

CLEAR_SESSION_ID="fixture-clear-session-456"
run_hook_at "$CONSUMER" "$CLEAR_SESSION_ID" clear > "$TMP/out" 2> "$TMP/err"
check_eq "/clear bootstraps its new session id" "$?" 0
run_gate_at "$CONSUMER" "$CLEAR_SESSION_ID" > "$TMP/gate-out" 2> "$TMP/gate-err"
check_eq "/clear opens the prompt gate for its new session" "$?" 0

echo
echo "## Later sessions are quiet local no-ops"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "repeat SessionStart succeeds" "$?" 0
check_eq "repeat SessionStart emits no model-visible output" \
  "$(wc -c < "$TMP/out" | tr -d ' ')" 0
check_eq "repeat SessionStart does not add the marketplace again" \
  "$(command_count '^plugin marketplace add ')" 1
check_eq "repeat SessionStart does not reinstall the plugin" \
  "$(command_count '^plugin install ')" 1
check_eq "repeat SessionStart verifies locally instead of reinstalling tooling" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" 1

echo
echo "## An intentionally disabled plugin stays disabled"
rm -f "$FAKE_STATE/plugin-enabled"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "disabled installation does not fail startup" "$?" 0
check_eq "disabled installation stays a quiet no-op" "$(wc -c < "$TMP/out" | tr -d ' ')" 0
check_eq "disabled installation is not re-enabled by install" \
  "$(command_count '^plugin install ')" 1

echo
echo "## A moved adopted release upgrades once and preserves disabled state"
NEXT_TOOLING_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
adopt_tooling_release "$NEXT_TOOLING_SHA" "0.1.6"
check_eq "moved checkout expects plugin release 0.1.6" "$(adopted_claude_version)" "0.1.6"
check_eq "host remains on plugin release 0.1.5 before refresh" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"

echo "## Failed refresh preserves installer and verifier diagnostics"
before_failed_refresh="$(command_count '^plugin marketplace update ')"
FAKE_AGENT_TOOLING_INVALID_INSTALL=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "invalid refreshed tooling is rejected" "$?" 1
for detail in 'fixture network unavailable' 'fixture configured hooks do not match'; do
  if grep -q "$detail" "$TMP/err"; then
    ok "failed refresh preserves $detail"
  else
    bad "failed refresh preserves $detail (stderr=$(cat "$TMP/err"))"
  fi
done
check_eq "invalid refreshed tooling prevents marketplace mutation" \
  "$(command_count '^plugin marketplace update ')" "$before_failed_refresh"
rm "$FAKE_STATE/invalid-install"

before_marketplace_updates="$(command_count '^plugin marketplace update ')"
before_plugin_updates="$(command_count '^plugin update ')"
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 \
FAKE_CLAUDE_FAIL_MARKETPLACE_UPDATE=1 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "marketplace update failure is rejected" "$?" 1
check_eq "failed marketplace refresh keeps the installed plugin version" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"
check_eq "failed marketplace refresh keeps the last-known-good catalog version" \
  "$(head -n1 "$FAKE_STATE/marketplace-version")" "0.1.5"
check_eq "marketplace refresh protects the last-known-good clone on failure" \
  "$(tail -n1 "$FAKE_STATE/marketplace-update-keep")" "1"

before_marketplace_updates="$(command_count '^plugin marketplace update ')"
before_plugin_updates="$(command_count '^plugin update ')"
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 \
FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_UPDATE=1 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "false-success plugin update is rejected" "$?" 1
check_eq "false-success path runs the exact marketplace update command" \
  "$(command_count '^plugin marketplace update boxlite-agent-tooling$')" \
  "$((before_marketplace_updates + 1))"
check_eq "false-success path runs the exact project plugin update command" \
  "$(command_count '^plugin update boxlite-agent-tooling@boxlite-agent-tooling --scope project --yes$')" \
  "$((before_plugin_updates + 1))"
check_eq "false-success update cannot advance installed plugin metadata" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"

before_plugin_reads="$(command_count '^plugin list --json$')"
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "release-transition SessionStart succeeds after a real update" "$?" 0
check_eq "release transition runs the exact marketplace update command once more" \
  "$(command_count '^plugin marketplace update boxlite-agent-tooling$')" \
  "$((before_marketplace_updates + 2))"
check_eq "release transition runs the exact project plugin update command once more" \
  "$(command_count '^plugin update boxlite-agent-tooling@boxlite-agent-tooling --scope project --yes$')" \
  "$((before_plugin_updates + 2))"
check_ge "release transition re-reads installed plugins after updating" \
  "$(( $(command_count '^plugin list --json$') - before_plugin_reads ))" 2
check_eq "installed plugin reports the adopted release after update" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
[[ ! -e "$FAKE_STATE/plugin-enabled" ]] \
  && ok "update preserves the intentionally disabled state" \
  || bad "update preserves the intentionally disabled state"
jq -e '
  (.systemMessage | test("/reload-plugins")) and
  .hookSpecificOutput.reloadSkills == true
' "$TMP/out" >/dev/null 2>&1 \
  && ok "updated plugin requests an in-session reload" \
  || bad "updated plugin requests an in-session reload (stdout=$(cat "$TMP/out"))"

marketplace_updates_after_transition="$(command_count '^plugin marketplace update ')"
plugin_updates_after_transition="$(command_count '^plugin update ')"
installer_calls_after_transition="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "same-release SessionStart succeeds" "$?" 0
check_eq "same-release SessionStart emits no model-visible output" \
  "$(wc -c < "$TMP/out" | tr -d ' ')" 0
check_eq "same-release SessionStart performs no marketplace update" \
  "$(command_count '^plugin marketplace update ')" "$marketplace_updates_after_transition"
check_eq "same-release SessionStart performs no plugin update" \
  "$(command_count '^plugin update ')" "$plugin_updates_after_transition"
check_eq "same-release SessionStart keeps tooling verification local" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" "$installer_calls_after_transition"

echo
echo "## A host-ahead plugin first advances the adopted tooling revision"
ORIGINAL_TOOLING_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
adopt_tooling_release "$ORIGINAL_TOOLING_SHA" "0.1.5"
check_eq "test setup restores an adopted 0.1.5 checkout" "$(adopted_claude_version)" "0.1.5"
check_eq "host remains ahead at plugin release 0.1.6" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
printf '%s\n' "$ORIGINAL_TOOLING_SHA" > "$CONSUMER/.agent-tooling/hold"
rm -f "$FAKE_STATE/marketplace"
before_held_marketplace_adds="$(command_count '^plugin marketplace add ')"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "hold rejects a missing marketplace before configuration" "$?" 1
check_eq "hold prevents adding a missing marketplace" \
  "$(command_count '^plugin marketplace add ')" "$before_held_marketplace_adds"
[[ ! -e "$FAKE_STATE/marketplace" ]] \
  && ok "held missing-marketplace path leaves host state untouched" \
  || bad "held missing-marketplace path leaves host state untouched"
touch "$FAKE_STATE/marketplace"

rm -f "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-installed-here" \
  "$FAKE_STATE/plugin-enabled"
printf '%s\n' "0.1.6" > "$FAKE_STATE/marketplace-version"
before_held_plugin_installs="$(command_count '^plugin install ')"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "hold rejects a missing project plugin before installation" "$?" 1
check_eq "hold prevents installing a missing project plugin" \
  "$(command_count '^plugin install ')" "$before_held_plugin_installs"
[[ ! -e "$FAKE_STATE/plugin-installed" ]] \
  && ok "held missing-plugin path leaves host state untouched" \
  || bad "held missing-plugin path leaves host state untouched"
touch "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-installed-here"
rm -f "$FAKE_STATE/plugin-enabled"
printf '%s\n' "0.1.6" > "$FAKE_STATE/plugin-version"

before_held_installs="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
before_held_marketplace_updates="$(command_count '^plugin marketplace update ')"
before_held_plugin_updates="$(command_count '^plugin update ')"
FAKE_AGENT_TOOLING_SHA="$NEXT_TOOLING_SHA" \
FAKE_AGENT_TOOLING_VERSION=0.1.6 \
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "held host-ahead SessionStart fails closed" "$?" 1
grep -q 'hold' "$TMP/err" \
  && ok "held mismatch explains the freeze" \
  || bad "held mismatch explains the freeze (stderr=$(cat "$TMP/err"))"
check_eq "held mismatch does not refresh adopted tooling" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" "$before_held_installs"
check_eq "held mismatch does not update the marketplace" \
  "$(command_count '^plugin marketplace update ')" "$before_held_marketplace_updates"
check_eq "held mismatch does not update the plugin" \
  "$(command_count '^plugin update ')" "$before_held_plugin_updates"
check_eq "held mismatch leaves the adopted release frozen" "$(adopted_claude_version)" "0.1.5"
check_eq "held mismatch leaves the host plugin untouched" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
rm -f "$CONSUMER/.agent-tooling/hold"

before_host_ahead_installs="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
before_host_ahead_marketplace_updates="$(command_count '^plugin marketplace update ')"
before_host_ahead_plugin_updates="$(command_count '^plugin update ')"
FAKE_AGENT_TOOLING_SHA="$NEXT_TOOLING_SHA" \
FAKE_AGENT_TOOLING_VERSION=0.1.6 \
FAKE_CLAUDE_MARKETPLACE_VERSION=0.1.6 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "host-ahead SessionStart advances tooling and succeeds" "$?" 0
check_eq "host-ahead SessionStart adopts the matching tooling release" \
  "$(adopted_claude_version)" "0.1.6"
check_eq "host-ahead SessionStart invokes the validated installer once" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" \
  "$((before_host_ahead_installs + 1))"
check_eq "host-ahead SessionStart skips marketplace update" \
  "$(command_count '^plugin marketplace update ')" "$before_host_ahead_marketplace_updates"
check_eq "host-ahead SessionStart skips plugin update" \
  "$(command_count '^plugin update ')" "$before_host_ahead_plugin_updates"
check_eq "host-ahead SessionStart preserves the newer installed plugin" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
[[ ! -e "$FAKE_STATE/plugin-enabled" ]] \
  && ok "host-ahead reconciliation preserves disabled state" \
  || bad "host-ahead reconciliation preserves disabled state"

echo
echo "## Linked worktrees receive path-specific project installations"
git -C "$CONSUMER" config user.email fixture@example.test
git -C "$CONSUMER" config user.name fixture
git -C "$CONSUMER" add .agent-tooling .claude
git -C "$CONSUMER" commit -qm fixture
WORKTREE="$TMP/linked worktree"
git -C "$CONSUMER" worktree add -q -b fixture-worktree "$WORKTREE"
mkdir -p "$WORKTREE/subdirectory"
touch "$FAKE_STATE/plugin-enabled"
rm -f "$FAKE_STATE/plugin-installed-here"
before_plugin_commands="$(command_count '^plugin install ')"
FAKE_CLAUDE_REPORTED_PROJECT_PATH="$CONSUMER" \
  run_hook_at "$WORKTREE" > "$TMP/out" 2> "$TMP/err"
check_eq "linked worktree bootstrap succeeds" "$?" 0
check_eq "linked worktree receives its own project installation" \
  "$(command_count '^plugin install ')" "$((before_plugin_commands + 1))"
jq -e '.systemMessage | test("/reload-plugins")' "$TMP/out" >/dev/null 2>&1 \
  && ok "linked worktree installation requests a plugin reload" \
  || bad "linked worktree installation requests a plugin reload (stdout=$(cat "$TMP/out"))"

echo
echo "## A project installation from another repository is not a false positive"
touch "$FAKE_STATE/plugin-enabled"
rm -f "$FAKE_STATE/plugin-installed-here"
before_plugin_commands="$(command_count '^plugin install ')"
FAKE_CLAUDE_REPORTED_PROJECT_PATH="$TMP/unrelated-repository" \
  run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "unrelated project installation is replaced locally" "$?" 0
check_eq "current project receives its own installation" \
  "$(command_count '^plugin install ')" "$((before_plugin_commands + 1))"
jq -e '.systemMessage | test("/reload-plugins")' "$TMP/out" >/dev/null 2>&1 \
  && ok "new project installation requests a plugin reload" \
  || bad "new project installation requests a plugin reload (stdout=$(cat "$TMP/out"))"

echo
echo "## Same-name marketplace conflicts fail closed"
FAKE_CLAUDE_MARKETPLACE_REPO=wrong/repository run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "wrong repository" 'marketplace source does not match' "$start_status"
FAKE_CLAUDE_MARKETPLACE_REF=release run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "wrong ref" 'marketplace source does not match' "$start_status"
FAKE_CLAUDE_DUPLICATE_MARKETPLACE=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "duplicate marketplace" 'marketplace source does not match' "$start_status"

echo
echo "## Boundary failures stop before the next mutation"
COMMON_GIT_DIR="$(git -C "$CONSUMER" rev-parse --git-common-dir)"
[[ "$COMMON_GIT_DIR" == /* ]] || COMMON_GIT_DIR="$CONSUMER/$COMMON_GIT_DIR"
rm -rf "$COMMON_GIT_DIR/agent-tooling"
rm -f "$FAKE_STATE/marketplace" "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
before_marketplace_commands="$(command_count '^plugin marketplace add ')"
FAKE_AGENT_TOOLING_FAIL=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "tooling installation failure" 'automatic tooling installation failed' "$start_status"
check_eq "tooling failure prevents marketplace mutation" \
  "$(command_count '^plugin marketplace add ')" "$before_marketplace_commands"

FAKE_AGENT_TOOLING_INVALID_INSTALL=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "invalid repaired tooling is rejected" "$?" 1
check_eq "invalid repair emits no model-visible output" "$(wc -c < "$TMP/out" | tr -d ' ')" 0
for detail in 'fixture network unavailable' 'fixture configured hooks do not match'; do
  if grep -q "$detail" "$TMP/err"; then
    ok "failed repair preserves $detail"
  else
    bad "failed repair preserves $detail (stderr=$(cat "$TMP/err"))"
  fi
done
check_eq "invalid repaired tooling prevents marketplace mutation" \
  "$(command_count '^plugin marketplace add ')" "$before_marketplace_commands"
rm "$FAKE_STATE/invalid-install"

FAKE_CLAUDE_FAIL_MARKETPLACE_ADD=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "marketplace add failure" 'could not add Claude marketplace' "$start_status"

touch "$FAKE_STATE/marketplace"
before_plugin_commands="$(command_count '^plugin install ')"
FAKE_CLAUDE_FAIL_PLUGIN_INSTALL=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "plugin installation failure" 'could not install Claude plugin' "$start_status"
check_eq "failed plugin install is attempted exactly once" \
  "$(command_count '^plugin install ')" "$((before_plugin_commands + 1))"

FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_INSTALL=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "false-success plugin install" \
  'did not report boxlite-agent-tooling as installed' "$start_status"

FAKE_CLAUDE_INVALID_MARKETPLACE_LIST=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "invalid marketplace JSON" 'invalid marketplace list' "$start_status"

FAKE_CLAUDE_INVALID_PLUGIN_LIST=1 run_hook > "$TMP/out" 2> "$TMP/err"
start_status="$?"
check_failed_start "invalid plugin JSON" 'invalid plugin list' "$start_status"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
