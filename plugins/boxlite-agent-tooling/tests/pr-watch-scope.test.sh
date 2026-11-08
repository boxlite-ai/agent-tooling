#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/repo"
cd "$scratch/repo"
git init -qb main
git config user.name Fixture
git config user.email fixture@example.invalid
git config commit.gpgsign false
printf 'unchanged root file\n' > same.txt
git add same.txt
git commit -qm base
git update-ref refs/remotes/origin/main HEAD
git switch -qc dev
printf 'integration\n' > dev-only.txt
git add dev-only.txt
git commit -qm integration
base="$(git rev-parse HEAD)"
git switch -qc feature
printf 'feature\n' > feature.txt
git add feature.txt
git commit -qm feature
head="$(git rev-parse HEAD)"
url=https://github.com/example/repo/pull/7
export SCOPE_FIXTURE
SCOPE_FIXTURE="$(jq -nc --arg url "$url" --arg base "$base" --arg head "$head" \
  '{url:$url,state:"OPEN",baseRefOid:$base,headRefOid:$head}')"
cat > "$scratch/bin/gh" <<'FIXTURE'
#!/usr/bin/env bash
if [[ "${SCOPE_STALL:-}" == 1 ]]; then
  exec perl -e '$SIG{ALRM} = "IGNORE"; sleep 3; print "$ENV{SCOPE_FIXTURE}\n"'
fi
if [[ -n "${SCOPE_SECOND_READ:-}" ]]; then
  if [[ -e "$SCOPE_MARKER" ]]; then
    printf '%s\n' "$SCOPE_SECOND_READ"
    exit 0
  fi
  : > "$SCOPE_MARKER"
fi
printf '%s\n' "$SCOPE_FIXTURE"
FIXTURE
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"

scope="$(bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head")"
jq -e '.paths == ["feature.txt"]' <<<"$scope" >/dev/null || {
  printf 'PR scope should only contain feature.txt; received %s\n' "$scope" >&2
  exit 1
}

export SCOPE_MARKER="$scratch/first-read"
export SCOPE_SECOND_READ
SCOPE_SECOND_READ="$(jq -c --arg old "$(git rev-parse origin/main)" '.baseRefOid=$old' <<<"$SCOPE_FIXTURE")"
if bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head" >"$scratch/paths" 2>"$scratch/error"; then
  printf 'Changed live base must fail closed\n' >&2
  exit 1
fi
[[ ! -s "$scratch/paths" ]]
grep -Fq 'refs changed' "$scratch/error"

unset SCOPE_SECOND_READ
mkdir nested
printf 'nested change\n' > nested/same.txt
git add nested/same.txt
git commit -qm 'nested change'
head="$(git rev-parse HEAD)"
SCOPE_FIXTURE="$(jq -c --arg head "$head" '.headRefOid=$head' <<<"$SCOPE_FIXTURE")"
git config diff.relative true
scope="$(cd nested && bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head")"
jq -e '.paths == ["feature.txt", "nested/same.txt"]' <<<"$scope" >/dev/null || {
  printf 'PR scope should contain complete repository-relative paths; received %s\n' "$scope" >&2
  exit 1
}

if SCOPE_STALL=1 AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 \
  bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head" >"$scratch/paths" 2>"$scratch/error"; then
  printf 'A stalled live ref lookup must fail closed\n' >&2
  exit 1
fi
[[ ! -s "$scratch/paths" ]]
grep -Fq 'command interrupted or timed out' "$scratch/error"

SCOPE_GIT_BIN="$(command -v git)"
export SCOPE_GIT_BIN
cat > "$scratch/bin/git" <<'FIXTURE'
#!/usr/bin/env bash
if [[ "${SCOPE_STALL_DIFF:-}" == 1 && "${1:-}" == diff ]]; then
  sleep 3
fi
exec "$SCOPE_GIT_BIN" "$@"
FIXTURE
chmod +x "$scratch/bin/git"
if SCOPE_STALL_DIFF=1 AGENT_TOOLING_COMMAND_TIMEOUT_SECONDS=1 \
  bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head" >"$scratch/paths" 2>"$scratch/error"; then
  printf 'A stalled diff must fail closed\n' >&2
  exit 1
fi
[[ ! -s "$scratch/paths" ]]
grep -Fq 'command interrupted or timed out' "$scratch/error"

git switch -qc replacement "$base"
printf 'outside the PR\n' > outside.txt
git add outside.txt
git commit -qm 'alternate tree'
replacement="$(git rev-parse HEAD)"
git switch -q feature
git replace "$head" "$replacement"
scope="$(bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head")"
jq -e '.paths == ["feature.txt", "nested/same.txt"]' <<<"$scope" >/dev/null || {
  printf 'PR scope must use the original Git objects; received %s\n' "$scope" >&2
  exit 1
}
git replace -d "$head" >/dev/null

printf '%s %s\n' "$head" "$base" > "$scratch/grafts"
if GIT_GRAFT_FILE="$scratch/grafts" \
  bash "$plugin/.agents/watch/pr-watch-scope.sh" "$url" "$head" >"$scratch/paths" 2>"$scratch/error"; then
  printf 'Local Git grafts must fail closed\n' >&2
  exit 1
fi
[[ ! -s "$scratch/paths" ]]
grep -Fq 'local Git grafts' "$scratch/error"
printf 'PR scope checks live refs, paths, deadlines, and original Git objects\n'
