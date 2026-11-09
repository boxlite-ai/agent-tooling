#!/usr/bin/env bash
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
CONSUMER="$ROOT/consumer"
mkdir -p "$CONSUMER"
git -C "$CONSUMER" init -q
git -C "$CONSUMER" config user.email test@boxlite.test
git -C "$CONSUMER" config user.name tester
printf 'base\n' > "$CONSUMER/file"
git -C "$CONSUMER" add file
git -C "$CONSUMER" commit -qm base
COMMON="$(git -C "$CONSUMER" rev-parse --path-format=absolute --git-common-dir)"

make_tooling() {
  local label="$1" scratch sha destination
  scratch="$(mktemp -d "$ROOT/tooling.XXXXXX")"
  mkdir -p "$scratch/plugins"
  cp -R "$PLUGIN_ROOT" "$scratch/plugins/boxlite-agent-tooling"
  printf '%s\n' "$label" > "$scratch/revision-label"
  git -C "$scratch" init -q
  git -C "$scratch" config user.email test@boxlite.test
  git -C "$scratch" config user.name tester
  git -C "$scratch" add plugins revision-label
  git -C "$scratch" commit -qm "$label"
  sha="$(git -C "$scratch" rev-parse HEAD)"
  destination="$COMMON/agent-tooling/$sha"
  mkdir -p "$COMMON/agent-tooling"
  mv "$scratch" "$destination"
  printf '%s' "$sha"
}

# Floating consumer: the profile and every host activation carry the BRANCH; the
# adopted revision lives only in the record the installer writes.
write_consumer_profile() {
  mkdir -p "$CONSUMER/.agent-tooling" "$CONSUMER/.agents/plugins" \
    "$CONSUMER/.claude" "$CONSUMER/.github/copilot"
  jq -nc '{schemaVersion:1,profile:"consumer",repository:"boxlite-ai/example-consumer",tooling:{repository:"boxlite-ai/agent-tooling",ref:"main"},checks:[{name:"test",command:"true"}]}' \
    > "$CONSUMER/.agent-tooling/profile.json"
  jq -nc '{extraKnownMarketplaces:{"boxlite-agent-tooling":{source:{source:"github",repo:"boxlite-ai/agent-tooling",ref:"main"}}},enabledPlugins:{"boxlite-agent-tooling@boxlite-agent-tooling":true}}' \
    > "$CONSUMER/.claude/settings.json"
  cp "$CONSUMER/.claude/settings.json" "$CONSUMER/.github/copilot/settings.json"
  jq -nc '{plugins:[{name:"boxlite-agent-tooling",source:{source:"git-subdir",url:"https://github.com/boxlite-ai/agent-tooling.git",ref:"main",path:"./plugins/boxlite-agent-tooling"},policy:{installation:"INSTALLED_BY_DEFAULT",authentication:"ON_INSTALL"},category:"Developer Tools"}]}' \
    > "$CONSUMER/.agents/plugins/marketplace.json"
}

write_record() {
  printf '%s\n' "$1" > "$COMMON/agent-tooling/current"
}

# Lifecycle events must not dial out mid-suite: the refresh spawn is exercised by
# tests/bootstrap/install.test.sh against a local remote, not against github.com.
export AGENT_TOOLING_REFRESH=0

printf '/.agents/state/\n/.claude/.*\n' > "$CONSUMER/.gitignore"
SHA_ONE="$(make_tooling one)"
write_consumer_profile
write_record "$SHA_ONE"
cp "$(cd "$PLUGIN_ROOT/../.." && pwd -P)/templates/install.sh" "$CONSUMER/.agent-tooling/install.sh"
chmod +x "$CONSUMER/.agent-tooling/install.sh"

SETUP_ONE="$COMMON/agent-tooling/$SHA_ONE/plugins/boxlite-agent-tooling/scripts/setup.sh"
"$SETUP_ONE" "$CONSUMER" >/dev/null
HOOKS_ONE="$COMMON/agent-tooling/$SHA_ONE/plugins/boxlite-agent-tooling/.githooks"
check_eq "setup enables worktree config" "$(git -C "$CONSUMER" config --get extensions.worktreeConfig)" true
check_eq "setup stores hooks per worktree" "$(git -C "$CONSUMER" config --worktree --get core.hooksPath)" "$HOOKS_ONE"
"$COMMON/agent-tooling/$SHA_ONE/plugins/boxlite-agent-tooling/scripts/verify-installation.sh" "$CONSUMER"
check_eq "fresh installation verifies" "$?" 0
GIT_DIR="$COMMON" "$COMMON/agent-tooling/$SHA_ONE/plugins/boxlite-agent-tooling/scripts/verify-installation.sh" "$CONSUMER"
check_eq "verification ignores Git's inherited worktree directory" "$?" 0

# shellcheck disable=SC2016 # $1-$3 belong to the generated hook.
printf '#!/usr/bin/env bash\nprintf "checkout %s %s %s\\n" "$1" "$2" "$3" >> "%s"\n' \
  '%s' '%s' '%s' "$ROOT/chained.log" > "$COMMON/hooks/post-checkout"
chmod +x "$COMMON/hooks/post-checkout"

# A hold is how a floating consumer names a revision explicitly; the cache already
# holds it (make_tooling), so adoption needs no network — exactly a laptop that
# fetched earlier and then went offline.
SHA_TWO="$(make_tooling two)"
printf '%s\n' "$SHA_TWO" > "$CONSUMER/.agent-tooling/hold"
(cd "$CONSUMER" && "$HOOKS_ONE/post-checkout" old new 1) 2> "$ROOT/sync.err"
HOOKS_TWO="$COMMON/agent-tooling/$SHA_TWO/plugins/boxlite-agent-tooling/.githooks"
check_eq "checkout adopts a new hold" "$(git -C "$CONSUMER" config --worktree --get core.hooksPath)" "$HOOKS_TWO"
check_eq "checkout records the adopted revision" "$(head -n1 "$COMMON/agent-tooling/current")" "$SHA_TWO"
check_eq "checkout preserves chained hook arguments" "$(cat "$ROOT/chained.log")" "checkout old new 1"
check_eq "checkout reports synchronization" "$(grep -c 'synchronized the recorded tooling revision' "$ROOT/sync.err")" 1

# shellcheck disable=SC2016 # $1 belongs to the generated hook.
printf '#!/usr/bin/env bash\nprintf "rewrite %s\\n" "$1" >> "%s"\ncat >> "%s"\n' \
  '%s' "$ROOT/rewrite.log" "$ROOT/rewrite.log" > "$COMMON/hooks/post-rewrite"
chmod +x "$COMMON/hooks/post-rewrite"
printf 'old-sha new-sha refs/heads/main\n' | (cd "$CONSUMER" && "$HOOKS_TWO/post-rewrite" rebase)
check_eq "post-rewrite preserves arguments and stdin" "$(cat "$ROOT/rewrite.log")" $'rewrite rebase\nold-sha new-sha refs/heads/main'

# Occupy both lock forms: the native lease file and the directory fallback.
mkdir "$COMMON/agent-tooling/.install.lock"
rm -f "$COMMON/agent-tooling/.install.guard"
mkdir "$COMMON/agent-tooling/.install.guard"
(cd "$CONSUMER" && ./.agent-tooling/install.sh > /dev/null 2> "$ROOT/lock.err")
check_eq "installer rejects a concurrent cache mutation" "$?" 1
check_eq "installer explains the lock" "$(grep -c 'another installation is already in progress' "$ROOT/lock.err")" 1
rmdir "$COMMON/agent-tooling/.install.lock" "$COMMON/agent-tooling/.install.guard"

BOGUS_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
printf '%s\n' "$BOGUS_SHA" > "$CONSUMER/.agent-tooling/hold"
printf '#!/usr/bin/env bash\nexit 7\n' > "$CONSUMER/.agent-tooling/install.sh"
chmod +x "$CONSUMER/.agent-tooling/install.sh"
(cd "$CONSUMER" && "$HOOKS_TWO/post-merge" 0) 2> "$ROOT/failure.err"
check_eq "lifecycle synchronization is opportunistic" "$?" 0
check_eq "lifecycle failure gives a recovery command" "$(grep -c 'run ./.agent-tooling/install.sh' "$ROOT/failure.err")" 1
(cd "$CONSUMER" && "$HOOKS_TWO/pre-commit" > /dev/null 2> "$ROOT/pre-commit.err")
check_eq "commit rejects a stale installation" "$?" 1
check_eq "commit gives the same recovery command" "$(grep -c 'run ./.agent-tooling/install.sh before committing' "$ROOT/pre-commit.err")" 1

assert_result
