#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
release="$root/.github/release/release.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -qb main
git config user.name Fixture
git config user.email fixture@example.invalid
git config commit.gpgsign false

generic=plugins/boxlite-agent-tooling/plugin.json
files=(
  "$generic"
  plugins/boxlite-agent-tooling/.claude-plugin/plugin.json
  plugins/boxlite-agent-tooling/.codex-plugin/plugin.json
  .claude-plugin/marketplace.json
  .github/plugin/marketplace.json
)
for path in "${files[@]}"; do
  mkdir -p "${path%/*}"
  cp "$root/$path" "$path"
done
printf 'original\n' > runtime
git add -- "${files[@]}" runtime
git commit -qm base
base="$(git rev-parse HEAD)"
IFS=. read -r major minor patch <<<"$(jq -r .version "$generic")"
first="$major.$minor.$((patch + 1))"
second="$major.$((minor + 1)).0"
git update-ref refs/remotes/origin/main "$base"

deny() {
  local message="$1"
  shift
  if bash "$release" "$@" >.git/stdout 2>.git/stderr; then
    printf 'Expected rejection: %s\n' "$message" >&2
    exit 1
  fi
  [[ ! -s .git/stdout ]]
  grep -Fq "$message" .git/stderr
}

git switch -qc dev
printf 'first fix\n' > runtime
git add runtime
git commit -qm 'first fix'
source="$(git rev-parse HEAD)"

git switch -qc ignored-source dev
printf '/local.env\n' >> .git/info/exclude
printf 'development fixture\n' > local.env
git add -f local.env
git commit -qm 'track previously ignored file'
git update-ref refs/remotes/origin/dev HEAD
git switch -qc ignored-release main
printf 'local fixture\n' > local.env
deny 'cannot stage the selected source tree' prepare
[[ "$(cat local.env)" == 'local fixture' ]]
git diff --cached --quiet
rm local.env

git update-ref refs/remotes/origin/dev "$source"
git switch -qc release-one main
result="$(bash "$release" prepare)"
[[ "$result" == "$first"$'\t'"$source" ]]
jq -se --arg version "$first" '
  (.[0:3] | all(.version == $version)) and
  (.[3:] | all(.metadata.version == $version and .plugins[0].version == $version))
' "${files[@]}" >/dev/null
git commit -qm 'release one'
candidate="$(git rev-parse HEAD)"
[[ "$(bash "$release" verify "$base" "$source" "$candidate")" == "$result" ]]

git switch -qc forged "$candidate"
jq '.description = "changed during promotion"' "$generic" > manifest.tmp
mv manifest.tmp "$generic"
git add "$generic"
git commit --amend -q --no-edit
deny 'candidate changed' verify "$base" "$source" HEAD
git replace HEAD "$candidate"
deny 'candidate changed' verify "$base" "$source" HEAD
git replace -d HEAD >/dev/null
printf '%s %s\n' "$candidate" "$base" > .git/grafts-fixture
GIT_GRAFT_FILE="$PWD/.git/grafts-fixture" deny 'local Git grafts' verify "$base" "$source" "$candidate"
git restore --source="$candidate" --staged --worktree -- "$generic"
printf '%s\n\n' "$source" > .github/release-source
git add .github/release-source
git commit --amend -q --no-edit
deny 'source record must contain one full SHA' verify "$base" "$source" HEAD
git restore --source="$candidate" --staged --worktree -- .github/release-source
printf 'forged\n' > runtime
git add runtime
git commit --amend -q --no-edit
deny 'outside release metadata' verify "$base" "$source" HEAD
deny 'outside dev' verify "$base" "$base" "$candidate"

git switch -q main
git merge --squash release-one >/dev/null
git commit -qm 'edited squash message'
promoted="$(git rev-parse HEAD)"
git branch -D release-one >/dev/null
[[ "$(git rev-parse 'HEAD^{tree}')" == "$(git rev-parse "$candidate^{tree}")" ]]
git update-ref refs/remotes/origin/main "$promoted"

git switch -q dev
printf 'overlapping later fix\n' > runtime
git add runtime
git commit -qm 'overlapping fix'
dev_tip="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/dev "$dev_tip"
git switch -qc stale-before-sync main
deny 'selected source must include the release base' prepare
git switch -q dev

cp .git/info/exclude .git/exclude-before-release-source
printf '/.github/release-source\n' >> .git/info/exclude
printf 'local source record fixture\n' > .github/release-source
deny 'release source record would overwrite an untracked path' sync "$promoted"
[[ "$(cat .github/release-source)" == 'local source record fixture' && ! -e .git/MERGE_HEAD ]]
git diff --cached --quiet
rm .github/release-source
mv .git/exclude-before-release-source .git/info/exclude

bash "$release" sync "$promoted" >/dev/null
[[ "$(cat runtime)" == 'overlapping later fix' ]]
git commit -qm 'sync release one'
[[ "$(git rev-list --parents -n 1 HEAD)" == "$(git rev-parse HEAD) $dev_tip $promoted" ]]
git update-ref refs/remotes/origin/dev HEAD
[[ "$(bash "$release" sync "$promoted")" == "already synced $first" ]]

git switch -qc release-major main
printf '/source-backup\n' >> .git/info/exclude
ln .github/release-source source-backup
[[ "$(bash "$release" prepare major)" == "$((major + 1)).0.0"$'\t'"$(git rev-parse dev)" ]]
if [[ "$(cat source-backup)" != "$source" ]]; then
  printf 'Release preparation overwrote the hard-linked source backup\n' >&2
  exit 1
fi
git commit -qm 'major bump fixture'
[[ "$(bash "$release" verify main dev HEAD)" == "$((major + 1)).0.0"$'\t'"$(git rev-parse dev)" ]]

git switch -qc release-two main
deny 'selected source must include the release base' prepare patch "$source"
[[ "$(bash "$release" prepare minor)" == "$second"$'\t'"$(git rev-parse dev)" ]]
git commit -qm 'release two'
[[ "$(bash "$release" verify main dev HEAD)" == "$second"$'\t'"$(git rev-parse dev)" ]]
git switch -q main
git merge --squash release-two >/dev/null
git commit -qm 'published release two'
second_promoted="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main HEAD
git switch -q dev
deny 'sync target must be the latest promoted main' sync "$promoted"
bash "$release" sync "$second_promoted" >/dev/null
git commit -qm 'sync release two'
git diff --quiet main dev
git update-ref refs/remotes/origin/dev HEAD
git switch -qc metadata-recovery main
recovery="$(bash "$release" prepare)"
[[ "$(git diff --cached --name-only -- runtime)" == '' ]]
git commit -qm 'metadata-only recovery'
[[ "$(bash "$release" verify main dev HEAD)" == "$recovery" ]]
printf 'Release preparation, provenance, sync, and metadata-only recovery checks passed\n'
