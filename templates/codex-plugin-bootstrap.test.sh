#!/usr/bin/env bash
# Tests the trust-once Codex bootstrap a consumer commits at project scope:
#
#   templates/codex-plugin-bootstrap.json -> .codex/hooks.json
#   templates/codex-plugin-bootstrap.sh   -> tooling setup + one-time plugin install
#
# The Codex CLI is a fake boundary, not a mock of implementation details. It records
# the public commands and returns the JSON shapes Codex 0.148 exposes. Nothing in this
# suite reads or writes the developer's real Codex configuration.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_FILE="$REPO_ROOT/templates/codex-plugin-bootstrap.json"
BOOTSTRAP="$REPO_ROOT/templates/codex-plugin-bootstrap.sh"
FAKE_CODEX="$REPO_ROOT/templates/fixtures/fake-codex-plugin-cli.sh"
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

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

echo "## Project hook shape"
if [[ -r "$HOOKS_FILE" ]]; then
  ok "bootstrap hook template exists"
else
  bad "bootstrap hook template exists"
fi
if jq -e . "$HOOKS_FILE" >/dev/null 2>&1; then
  ok "hook is valid JSON"
else
  bad "hook is valid JSON"
fi

unknown="$(jq -r '
  [ (keys_unsorted[] | select(. != "hooks")),
    (.hooks | keys_unsorted[] | select(. != "SessionStart")),
    (.hooks.SessionStart[] | keys_unsorted[] | select(. != "hooks" and . != "matcher")),
    (.hooks.SessionStart[].hooks[] | keys_unsorted[]
      | select(IN("type","command","statusMessage","timeout") | not))
  ] | join(",")
' "$HOOKS_FILE" 2>/dev/null)"
if [[ -z "$unknown" ]]; then
  ok "hook uses only supported schema keys"
else
  bad "hook uses only supported schema keys (found: $unknown)"
fi

matcher="$(jq -r '.hooks.SessionStart[0].matcher // "MISSING"' "$HOOKS_FILE" 2>/dev/null)"
check_eq "hook runs for startup and resume only" "$matcher" "^(startup|resume)$"
hook_command="$(jq -r '.hooks.SessionStart[0].hooks[0].command // "MISSING"' "$HOOKS_FILE" 2>/dev/null)"
git_root_expression="\$(git rev-parse --show-toplevel)"
case "$hook_command" in
  *"$git_root_expression"*'.agent-tooling/codex-plugin-bootstrap.sh"')
    ok "hook resolves the Git root and calls the Codex bootstrap" ;;
  *)
    bad "hook resolves the Git root and calls the Codex bootstrap (got: $hook_command)" ;;
esac
check_eq "hook handler is a command" \
  "$(jq -r '.hooks.SessionStart[0].hooks[0].type // "MISSING"' "$HOOKS_FILE" 2>/dev/null)" \
  "command"

# Minimal consumer fixture. The fake installer creates the same adopted-revision
# boundary as the ordinary install path, so no Git remote or tooling checkout is needed.
CONSUMER="$TMP/consumer repo"
mkdir -p "$CONSUMER/.agent-tooling" "$CONSUMER/.agents/plugins" "$CONSUMER/subdirectory"
git init -q "$CONSUMER"
cp "$BOOTSTRAP" "$CONSUMER/.agent-tooling/codex-plugin-bootstrap.sh"
cp "$FAKE_INSTALLER" "$CONSUMER/.agent-tooling/install.sh"
chmod +x "$CONSUMER/.agent-tooling/codex-plugin-bootstrap.sh"
chmod +x "$CONSUMER/.agent-tooling/install.sh"
jq -nc '{
  schemaVersion: 1,
  profile: "consumer",
  repository: "boxlite-ai/example-consumer",
  tooling: {repository: "boxlite-ai/agent-tooling", ref: "main"},
  checks: [{name: "test", command: "true"}]
}' > "$CONSUMER/.agent-tooling/profile.json"
jq -nc '{
  name: "boxlite-agent-tooling",
  plugins: [{
    name: "boxlite-agent-tooling",
    source: {
      source: "git-subdir",
      url: "https://github.com/boxlite-ai/agent-tooling.git",
      ref: "main",
      path: "./plugins/boxlite-agent-tooling"
    },
    policy: {installation: "INSTALLED_BY_DEFAULT", authentication: "ON_INSTALL"},
    category: "Developer Tools"
  }]
}' > "$CONSUMER/.agents/plugins/marketplace.json"

# Fake only the stable public Codex plugin commands used by the bootstrap.
FAKE_BIN="$TMP/bin"
FAKE_STATE="$TMP/codex-state"
mkdir -p "$FAKE_BIN" "$FAKE_STATE"
cp "$FAKE_CODEX" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"

run_hook() {
  (cd "$CONSUMER/subdirectory" && \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_CODEX_STATE="$FAKE_STATE" \
    FAKE_CODEX_MARKETPLACE_ROOT="${FAKE_CODEX_MARKETPLACE_ROOT:-$CONSUMER}" \
    FAKE_AGENT_TOOLING_STATE="$FAKE_STATE" \
    FAKE_AGENT_TOOLING_VERIFY="$FAKE_VERIFY" \
    bash -c "$hook_command")
}
command_count() { grep -c -E "$1" "$FAKE_STATE/commands" 2>/dev/null || true; }
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
adopted_codex_version() {
  local git_dir record
  git_dir="$(common_git_dir)"
  record="$(head -n1 "$git_dir/agent-tooling/current")"
  jq -r '.version' \
    "$git_dir/agent-tooling/$record/plugins/boxlite-agent-tooling/.codex-plugin/plugin.json"
}

echo
echo "## First trusted startup installs from the canonical marketplace"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "trusted startup succeeds" "$?" 0
if jq -e '.systemMessage | test("new Codex task")' "$TMP/out" >/dev/null 2>&1; then
  ok "first install asks for a new task"
else
  bad "first install asks for a new task (stdout=$(cat "$TMP/out"))"
fi
check_eq "canonical marketplace is added once" \
  "$(command_count '^plugin marketplace add https://github.com/boxlite-ai/agent-tooling.git --ref main --json$')" 1
check_eq "canonical marketplace is mutated once" \
  "$(wc -l < "$FAKE_STATE/marketplace-additions" | tr -d ' ')" 1
check_eq "plugin is installed once" \
  "$(command_count '^plugin add boxlite-agent-tooling@boxlite-agent-tooling --json$')" 1
check_eq "tooling installer runs once" "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" 1
check_eq "adopted checkout expects plugin release 0.1.5" "$(adopted_codex_version)" "0.1.5"
check_eq "installed plugin reports release 0.1.5" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"
if grep -q '^sync=1$' "$FAKE_STATE/installer-calls"; then
  ok "SessionStart marks the tooling install as lifecycle-triggered"
else
  bad "SessionStart marks the tooling install as lifecycle-triggered"
fi

echo
echo "## Later startups are quiet no-ops"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "repeat startup succeeds" "$?" 0
check_eq "repeat startup emits no model-visible output" "$(wc -c < "$TMP/out" | tr -d ' ')" 0
check_eq "repeat startup does not mutate the marketplace again" \
  "$(wc -l < "$FAKE_STATE/marketplace-additions" | tr -d ' ')" 1
check_eq "repeat startup does not reinstall the plugin" \
  "$(command_count '^plugin add ')" 1
check_eq "repeat startup uses the local verifier instead of the installer" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" 1

echo
echo "## An intentionally disabled installation stays disabled"
rm -f "$FAKE_STATE/plugin-enabled"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "disabled plugin does not fail startup" "$?" 0
check_eq "disabled plugin is not re-enabled by reinstall" \
  "$(command_count '^plugin add ')" 1

echo
echo "## A moved adopted release upgrades once and preserves disabled state"
NEXT_TOOLING_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
adopt_tooling_release "$NEXT_TOOLING_SHA" "0.1.6"
check_eq "moved checkout expects plugin release 0.1.6" "$(adopted_codex_version)" "0.1.6"
check_eq "host remains on plugin release 0.1.5 before refresh" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"

echo "## Failed refresh preserves installer and verifier diagnostics"
before_failed_refresh="$(command_count '^plugin marketplace upgrade ')"
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
  "$(command_count '^plugin marketplace upgrade ')" "$before_failed_refresh"
rm "$FAKE_STATE/invalid-install"

before_manifest_upgrade_commands="$(command_count '^plugin marketplace upgrade ')"
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 \
FAKE_CODEX_FALSE_SUCCESS_MARKETPLACE_MANIFEST=1 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "upgrade without a matching configured manifest is rejected" "$?" 1
check_eq "stale-manifest path runs the exact marketplace upgrade command" \
  "$(command_count '^plugin marketplace upgrade boxlite-agent-tooling --json$')" \
  "$((before_manifest_upgrade_commands + 1))"
if grep -q 'configured Codex marketplace stayed at 0.1.5 after upgrade; expected 0.1.6' "$TMP/err"; then
  ok "stale-manifest failure names both versions"
else
  bad "stale-manifest failure names both versions (stderr=$(cat "$TMP/err"))"
fi
# Restore only the simulated host record so the next case starts from the same
# pre-upgrade boundary; the false-success fixture deliberately left the manifest old.
printf '%s\n' "0.1.5" > "$FAKE_STATE/plugin-version"

before_upgrade_commands="$(command_count '^plugin marketplace upgrade ')"
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 \
FAKE_CODEX_FALSE_SUCCESS_MARKETPLACE_UPGRADE=1 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "false-success marketplace upgrade is rejected" "$?" 1
check_eq "false-success path runs the exact marketplace upgrade command" \
  "$(command_count '^plugin marketplace upgrade boxlite-agent-tooling --json$')" \
  "$((before_upgrade_commands + 1))"
check_eq "false-success upgrade cannot advance installed plugin metadata" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.5"

before_catalog_reads="$(command_count '^plugin list ')"
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "release-transition startup succeeds after a real upgrade" "$?" 0
check_eq "release transition runs the exact marketplace upgrade command once more" \
  "$(command_count '^plugin marketplace upgrade boxlite-agent-tooling --json$')" \
  "$((before_upgrade_commands + 2))"
check_ge "release transition re-reads the plugin catalog after upgrading" \
  "$(( $(command_count '^plugin list ') - before_catalog_reads ))" 2
check_eq "installed plugin reports the adopted release after upgrade" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
[[ ! -e "$FAKE_STATE/plugin-enabled" ]] \
  && ok "upgrade preserves the intentionally disabled state" \
  || bad "upgrade preserves the intentionally disabled state"
if jq -e '.systemMessage | test("new Codex task")' "$TMP/out" >/dev/null 2>&1; then
  ok "upgraded plugin asks for a new task"
else
  bad "upgraded plugin asks for a new task (stdout=$(cat "$TMP/out"))"
fi

upgrades_after_transition="$(command_count '^plugin marketplace upgrade ')"
installer_calls_after_transition="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "same-release startup succeeds" "$?" 0
check_eq "same-release startup emits no model-visible output" \
  "$(wc -c < "$TMP/out" | tr -d ' ')" 0
check_eq "same-release startup performs no marketplace upgrade" \
  "$(command_count '^plugin marketplace upgrade ')" "$upgrades_after_transition"
check_eq "same-release startup keeps tooling verification local" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" "$installer_calls_after_transition"

echo
echo "## A host-ahead plugin first advances the adopted tooling revision"
ORIGINAL_TOOLING_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
adopt_tooling_release "$ORIGINAL_TOOLING_SHA" "0.1.5"
check_eq "test setup restores an adopted 0.1.5 checkout" "$(adopted_codex_version)" "0.1.5"
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

rm -f "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
printf '%s\n' "0.1.5" > "$FAKE_STATE/marketplace-version"
before_held_plugin_adds="$(command_count '^plugin add ')"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "hold rejects a missing plugin before installation" "$?" 1
check_eq "hold prevents installing a missing plugin" \
  "$(command_count '^plugin add ')" "$before_held_plugin_adds"
[[ ! -e "$FAKE_STATE/plugin-installed" ]] \
  && ok "held missing-plugin path leaves host state untouched" \
  || bad "held missing-plugin path leaves host state untouched"
touch "$FAKE_STATE/plugin-installed"
rm -f "$FAKE_STATE/plugin-enabled"
printf '%s\n' "0.1.6" > "$FAKE_STATE/plugin-version"
printf '%s\n' "0.1.6" > "$FAKE_STATE/marketplace-version"

before_held_installs="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
before_held_upgrades="$(command_count '^plugin marketplace upgrade ')"
FAKE_AGENT_TOOLING_SHA="$NEXT_TOOLING_SHA" \
FAKE_AGENT_TOOLING_VERSION=0.1.6 \
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "held host-ahead startup fails closed" "$?" 1
grep -q 'hold' "$TMP/err" \
  && ok "held mismatch explains the freeze" \
  || bad "held mismatch explains the freeze (stderr=$(cat "$TMP/err"))"
check_eq "held mismatch does not refresh adopted tooling" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" "$before_held_installs"
check_eq "held mismatch does not touch the marketplace" \
  "$(command_count '^plugin marketplace upgrade ')" "$before_held_upgrades"
check_eq "held mismatch leaves the adopted release frozen" "$(adopted_codex_version)" "0.1.5"
check_eq "held mismatch leaves the host plugin untouched" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
rm -f "$CONSUMER/.agent-tooling/hold"

before_host_ahead_installs="$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')"
before_host_ahead_upgrades="$(command_count '^plugin marketplace upgrade ')"
FAKE_AGENT_TOOLING_SHA="$NEXT_TOOLING_SHA" \
FAKE_AGENT_TOOLING_VERSION=0.1.6 \
FAKE_CODEX_MARKETPLACE_VERSION=0.1.6 \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "host-ahead startup advances tooling and succeeds" "$?" 0
check_eq "host-ahead startup adopts the matching tooling release" \
  "$(adopted_codex_version)" "0.1.6"
check_eq "host-ahead startup invokes the validated installer once" \
  "$(wc -l < "$FAKE_STATE/installer-calls" | tr -d ' ')" \
  "$((before_host_ahead_installs + 1))"
check_eq "host-ahead startup does not try to downgrade the marketplace" \
  "$(command_count '^plugin marketplace upgrade ')" "$before_host_ahead_upgrades"
check_eq "host-ahead startup preserves the newer installed plugin" \
  "$(head -n1 "$FAKE_STATE/plugin-version")" "0.1.6"
[[ ! -e "$FAKE_STATE/plugin-enabled" ]] \
  && ok "host-ahead reconciliation preserves disabled state" \
  || bad "host-ahead reconciliation preserves disabled state"

echo
echo "## A same-name local marketplace is not mistaken for the canonical Git source"
before_marketplace_commands="$(command_count '^plugin marketplace add ')"
FAKE_CODEX_MARKETPLACE_SOURCE_TYPE=local \
FAKE_CODEX_MARKETPLACE_SOURCE="$CONSUMER" \
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "local marketplace registration is rejected" "$?" 1
check_eq "local marketplace is rejected before Git add can replace it" \
  "$(command_count '^plugin marketplace add ')" "$before_marketplace_commands"
if grep -q 'configured Codex marketplace source is not canonical Git' "$TMP/err"; then
  ok "failure explains the non-canonical marketplace source"
else
  bad "failure explains the non-canonical marketplace source (stderr=$(cat "$TMP/err"))"
fi

echo
echo "## The configured marketplace ref must match tooling.ref"
FAKE_CODEX_MARKETPLACE_REF=release run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "different configured ref is rejected" "$?" 1
if grep -q 'marketplace is not configured at tooling.ref main' "$TMP/err"; then
  ok "failure explains the marketplace ref mismatch"
else
  bad "failure explains the marketplace ref mismatch (stderr=$(cat "$TMP/err"))"
fi

echo
echo "## A same-name incompatible marketplace fails closed"
BAD_MARKETPLACE_ROOT="$TMP/incompatible marketplace"
mkdir -p "$BAD_MARKETPLACE_ROOT/.agents/plugins"
jq '.plugins[0].source.url = "https://example.invalid/wrong.git"' \
  "$CONSUMER/.agents/plugins/marketplace.json" \
  > "$BAD_MARKETPLACE_ROOT/.agents/plugins/marketplace.json"
FAKE_CODEX_MARKETPLACE_ROOT="$BAD_MARKETPLACE_ROOT" run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "incompatible catalog is rejected" "$?" 1
if grep -q 'configured Codex marketplace is invalid' "$TMP/err"; then
  ok "failure explains the marketplace conflict"
else
  bad "failure explains the marketplace conflict (stderr=$(cat "$TMP/err"))"
fi

echo
echo "## Boundary failures stop before the next mutation"
COMMON_GIT_DIR="$(git -C "$CONSUMER" rev-parse --git-common-dir)"
[[ "$COMMON_GIT_DIR" == /* ]] || COMMON_GIT_DIR="$CONSUMER/$COMMON_GIT_DIR"
rm -f "$COMMON_GIT_DIR/agent-tooling/current"
before_marketplaces="$(command_count '^plugin marketplace add ')"
FAKE_AGENT_TOOLING_FAIL=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "tooling installation failure is nonzero" "$?" 1
if grep -q 'automatic tooling installation failed' "$TMP/err"; then
  ok "tooling failure has actionable stderr"
else
  bad "tooling failure has actionable stderr (stderr=$(cat "$TMP/err"))"
fi
check_eq "tooling failure prevents marketplace mutation" \
  "$(command_count '^plugin marketplace add ')" "$before_marketplaces"

rm -f "$FAKE_STATE/marketplace" "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
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
  "$(command_count '^plugin marketplace add ')" "$before_marketplaces"
rm "$FAKE_STATE/invalid-install"

FAKE_CODEX_FAIL_MARKETPLACE_ADD=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "marketplace add failure is nonzero" "$?" 1
if grep -q 'could not add Codex marketplace' "$TMP/err"; then
  ok "marketplace failure has actionable stderr"
else
  bad "marketplace failure has actionable stderr (stderr=$(cat "$TMP/err"))"
fi

touch "$FAKE_STATE/marketplace"
before_plugins="$(command_count '^plugin add ')"
FAKE_CODEX_FAIL_PLUGIN_ADD=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "plugin add failure is nonzero" "$?" 1
if grep -q 'could not install Codex plugin' "$TMP/err"; then
  ok "plugin failure has actionable stderr"
else
  bad "plugin failure has actionable stderr (stderr=$(cat "$TMP/err"))"
fi
check_eq "failed plugin add is attempted exactly once" \
  "$(command_count '^plugin add ')" "$((before_plugins + 1))"

echo
echo "## Catalog version boundaries fail closed"
CONFIGURED_PLUGIN_MANIFEST="$CONSUMER/plugins/boxlite-agent-tooling/.codex-plugin/plugin.json"
cp "$CONFIGURED_PLUGIN_MANIFEST" "$TMP/configured-plugin-manifest"
jq '.version = null' "$TMP/configured-plugin-manifest" > "$CONFIGURED_PLUGIN_MANIFEST"
before_catalog_reads="$(command_count '^plugin list ')"
run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "configured marketplace manifest without a version is rejected" "$?" 1
if grep -q 'configured Codex marketplace has no valid plugin version' "$TMP/err"; then
  ok "manifest failure names the invalid configured version"
else
  bad "manifest failure names the invalid configured version (stderr=$(cat "$TMP/err"))"
fi
check_eq "invalid configured manifest stops before catalog inspection" \
  "$(command_count '^plugin list ')" "$before_catalog_reads"
cp "$TMP/configured-plugin-manifest" "$CONFIGURED_PLUGIN_MANIFEST"

rm -f "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
before_plugins="$(command_count '^plugin add ')"
FAKE_CODEX_AVAILABLE_VERSION_JSON='{}' run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "malformed available version is rejected" "$?" 1
check_eq "malformed available version stops before plugin installation" \
  "$(command_count '^plugin add ')" "$before_plugins"

FAKE_CODEX_AVAILABLE_VERSION_OMITTED=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "missing available version field is rejected" "$?" 1
check_eq "missing available version field stops before plugin installation" \
  "$(command_count '^plugin add ')" "$before_plugins"
rm -f "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"

touch "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
printf '%s\n' "0.1.5" > "$FAKE_STATE/plugin-version"
FAKE_CODEX_INSTALLED_VERSION_NULL=1 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "installed plugin with a null version is rejected" "$?" 1
if grep -q 'does not advertise the expected plugin' "$TMP/err"; then
  ok "installed null failure names the invalid catalog entry"
else
  bad "installed null failure names the invalid catalog entry (stderr=$(cat "$TMP/err"))"
fi

rm -f "$FAKE_STATE/plugin-installed" "$FAKE_STATE/plugin-enabled"
before_plugins="$(command_count '^plugin add ')"
FAKE_CODEX_PLUGIN_ADD_VERSION=0.1.3 run_hook > "$TMP/out" 2> "$TMP/err"
check_eq "plugin add with the wrong installed version is rejected" "$?" 1
check_eq "wrong-version plugin add is attempted exactly once" \
  "$(command_count '^plugin add ')" "$((before_plugins + 1))"
if grep -q 'did not install boxlite-agent-tooling at expected version 0.1.5' "$TMP/err"; then
  ok "post-add failure names the adopted expected version"
else
  bad "post-add failure names the adopted expected version (stderr=$(cat "$TMP/err"))"
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
