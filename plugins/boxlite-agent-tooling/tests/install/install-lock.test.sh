#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)"
# shellcheck source=../../.agents/lib/install-lock.sh
source "$root/plugins/boxlite-agent-tooling/.agents/lib/install-lock.sh"
scratch="$(mktemp -d)"
installer_pid=""
setup_pid=""
cleanup() {
  [[ -z "$installer_pid" ]] || kill -KILL "$installer_pid" 2>/dev/null || true
  [[ -z "$setup_pid" ]] || kill -KILL "$setup_pid" 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT
fail() { printf 'install-lock: %s\n' "$*" >&2; exit 1; }
wait_file() {
  local file="$1" attempts=0
  until [[ -s "$file" ]]; do
    (( attempts < 100 )) || fail "timed out waiting for ${file##*/}"
    attempts=$((attempts + 1))
    sleep 0.05
  done
}

# Keep all writes local. A hold points at a cached Git checkout with a blocking
# setup child so the fixture observes the installer crossing its write boundary.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export INSTALL_TEST_STARTED="$scratch/started" INSTALL_TEST_RELEASE="$scratch/release"
export INSTALL_TEST_WRITES="$scratch/writes"
source_cache="$scratch/cache-source"
git init -q "$source_cache"
setup="$source_cache/plugins/boxlite-agent-tooling/scripts/setup.sh"
mkdir -p "$(dirname "$setup")"
cat > "$setup" <<'SETUP'
#!/usr/bin/env bash
set -eu
if [[ "${INSTALL_TEST_BLOCK:-0}" == 1 ]]; then
  printf '%s\n' "$$" > "$INSTALL_TEST_STARTED"
  while [[ ! -e "$INSTALL_TEST_RELEASE" ]]; do sleep 0.03; done
fi
printf 'setup\n' >> "$INSTALL_TEST_WRITES"
SETUP
chmod +x "$setup"
git -C "$source_cache" add .
git -C "$source_cache" -c user.name=test -c user.email=test@example.invalid commit -qm setup
sha="$(git -C "$source_cache" rev-parse HEAD)"

installer="$root/plugins/boxlite-agent-tooling/scripts/install.sh"
consumer="$scratch/consumer"
git init -q "$consumer"
mkdir -p "$consumer/.agent-tooling" "$consumer/.git/agent-tooling"
printf '%s\n' "$sha" > "$consumer/.agent-tooling/hold"
printf '%s\n' '{"tooling":{"repository":"boxlite-ai/agent-tooling","ref":"main"}}' \
  > "$consumer/.agent-tooling/profile.json"
cache="$consumer/.git/agent-tooling"
git clone -q "$source_cache" "$cache/$sha"
cd "$consumer"

if ! install_lock_native "$cache"; then
  bash "$installer"
  [[ "$(cat "$cache/current")" == "$sha" && ! -e "$cache/.install.guard" ]] \
    || fail 'fallback did not use the directory lock'
  mkdir "$cache/.install.lock"
  if bash "$installer" > "$scratch/held.log" 2>&1; then fail 'a held directory lock was ignored'; fi
  rmdir "$cache/.install.lock"
  printf 'install-lock: directory lock fallback passed\n'
  exit 0
fi

(export INSTALL_TEST_BLOCK=1; exec bash "$installer") > "$scratch/install.log" 2>&1 &
installer_pid=$!
wait_file "$INSTALL_TEST_STARTED"
setup_pid="$(cat "$INSTALL_TEST_STARTED")"
kill -KILL "$installer_pid"
wait "$installer_pid" 2>/dev/null || true
installer_pid=""
kill -0 "$setup_pid" || fail 'installer death also stopped the setup fixture'
if bash "$installer" > "$scratch/contender.log" 2>&1; then
  fail 'another installer entered while orphaned setup was still live'
fi
grep -Fq 'installation is already in progress' "$scratch/contender.log" \
  || { cat "$scratch/contender.log" >&2; fail 'contender did not hit the lock'; }
printf 'release\n' > "$INSTALL_TEST_RELEASE"
wait_file "$INSTALL_TEST_WRITES"
setup_pid=""
sleep 0.1
if ! bash "$installer" > "$scratch/retry.log" 2>&1; then
  cat "$scratch/retry.log" >&2
  fail 'a stopped installation stranded its lock'
fi
[[ "$(cat "$cache/current")" == "$sha" ]] || fail 'retry did not adopt the held revision'
[[ -f "$cache/.install.guard" && ! -e "$cache/.install.lock" ]] || fail 'native lease left an unexpected lock path'
[[ "$(wc -l < "$INSTALL_TEST_WRITES" | tr -d ' ')" == 2 ]] || fail 'a writer ran during contention'

mv "$cache/.install.guard" "$scratch/guard"
ln -s "$scratch/guard" "$cache/.install.guard"
if bash "$installer" > "$scratch/symlink.log" 2>&1; then fail 'a symlinked guard was accepted'; fi
[[ -L "$cache/.install.guard" ]] || fail 'the symlinked guard was changed'
unlink "$cache/.install.guard"

# Force the guard open onto descriptor 9 so dup2 is a no-op.
bash "$installer" 3</dev/null 4</dev/null 5</dev/null 6</dev/null 7</dev/null 8</dev/null \
  || fail 'lease descriptor did not survive when already numbered 9'
printf 'install-lock: orphan exclusion and retry passed\n'
