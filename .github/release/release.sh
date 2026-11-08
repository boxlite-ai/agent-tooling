#!/usr/bin/env bash
# Stage or verify a release snapshot. Never commits, pushes, tags, or publishes.
set -uo pipefail

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

root="$(git rev-parse --show-toplevel)" || die 'run inside the repository'
cd "$root" || die 'cannot enter repository'
command -v jq >/dev/null || die 'jq is required'
export GIT_NO_REPLACE_OBJECTS=1
grafts="$(git rev-parse --git-path info/grafts)" || die 'cannot inspect Git grafts'
[[ -n "$grafts" && ! -e "$grafts" && ! -L "$grafts" ]] || die 'local Git grafts prevent checking release provenance'

plugin=plugins/boxlite-agent-tooling
source_record=.github/release-source
manifests=(
  "$plugin/plugin.json"
  "$plugin/.claude-plugin/plugin.json"
  "$plugin/.codex-plugin/plugin.json"
  .claude-plugin/marketplace.json
  .github/plugin/marketplace.json
)
version_pattern='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
sha_pattern='^[0-9a-f]{40}$'

commit() {
  git rev-parse --verify --end-of-options "$1^{commit}" || die "cannot resolve commit $1"
}

version_paths() {
  case "$1" in
    */marketplace.json) printf '%s\n' '[["metadata","version"],["plugins",0,"version"]]' ;;
    *) printf '%s\n' '[["version"]]' ;;
  esac
}

release_blob() {
  local entry
  entry="$(git ls-tree "$1" -- "$2")" || return 1
  [[ "$entry" == '100644 blob '* ]] || return 1
  git cat-file blob "$1:$2"
}

version_at() {
  local file value found=''
  for file in "${manifests[@]}"; do
    value="$(release_blob "$1" "$file" | jq -ers --argjson paths "$(version_paths "$file")" '
      select(length == 1) | .[0]
      | [$paths[] as $path | getpath($path)] | unique
      | select(length == 1) | .[0] | strings
    ')" || die "invalid version fields in $file at $1"
    [[ "$value" =~ $version_pattern ]] || die "invalid version in $file at $1"
    [[ -z "$found" || "$value" == "$found" ]] || die "version fields disagree at $1"
    found="$value"
  done
  printf '%s\n' "$found"
}

next_version() {
  local major minor patch result
  IFS=. read -r major minor patch <<<"$1"
  case "$2" in
    patch) result="$major.$minor.$((patch + 1))" ;;
    minor) result="$major.$((minor + 1)).0" ;;
    major) result="$((major + 1)).0.0" ;;
    *) return 1 ;;
  esac
  [[ "$result" =~ $version_pattern ]] || return 1
  printf '%s\n' "$result"
}

render_manifest() {
  release_blob "$1" "$2" | jq -be --argjson paths "$(version_paths "$2")" --arg version "$3" '
    reduce $paths[] as $path (.; setpath($path; $version))
  '
}

check_source() {
  git merge-base --is-ancestor "$1" "$3" || die 'selected source must include the release base'
  git merge-base --is-ancestor "$3" "$2" || die 'selected source is outside dev'
}

verify_candidate() {
  local base="$1" dev="$2" head="$3" source old new part expected actual file
  local excludes=(":(top,exclude)$source_record")
  [[ "$(git rev-list --parents -n 1 "$head")" == "$head $base" ]] ||
    die 'release must have the current base as its only parent'
  source="$(release_blob "$head" "$source_record")" || die 'missing or invalid release source record'
  [[ "$source" =~ $sha_pattern &&
     "$(printf '%s\n' "$source" | git hash-object --stdin)" == "$(git rev-parse "$head:$source_record")" ]] ||
    die 'release source record must contain one full SHA and a newline'
  check_source "$base" "$dev" "$source"
  old="$(version_at "$base")" && new="$(version_at "$head")" || exit 1
  [[ "$(version_at "$source")" == "$old" ]] || die 'source version differs from release base'
  for part in patch minor major; do
    [[ "$(next_version "$old" "$part")" == "$new" ]] && break
  done
  [[ "$(next_version "$old" "$part")" == "$new" ]] || die 'candidate is not a next patch, minor, or major version'
  for file in "${manifests[@]}"; do
    excludes+=(":(top,exclude)$file")
    expected="$(render_manifest "$source" "$file" "$new" | git hash-object --stdin)" ||
      die "cannot reconstruct $file"
    actual="$(git rev-parse --verify "$head:$file")" || die "missing $file"
    [[ "$actual" == "$expected" ]] || die "candidate changed $file beyond its generated version"
  done
  git diff --quiet --no-ext-diff --no-textconv --no-renames --ignore-submodules=none \
    "$source" "$head" -- . "${excludes[@]}" ||
    die 'candidate has changes outside release metadata'
  printf '%s\t%s\n' "$new" "$source"
}

clean_at() {
  local status
  status="$(git status --porcelain --untracked-files=all)" || die 'cannot inspect worktree'
  [[ -z "$status" && "$(commit HEAD)" == "$1" ]] || die 'use a clean branch at the expected tip'
  if [[ -e "$source_record" || -L "$source_record" ]] &&
     [[ "$(git ls-files -- "$source_record")" != "$source_record" ]]; then
    die 'release source record would overwrite an untracked path'
  fi
}

stage_metadata() {
  local from="$1" version="$2" source="$3" file temp
  [[ ! -L "$source_record" && ( ! -e "$source_record" || -f "$source_record" ) ]] ||
    die 'release source record must be a regular file'
  for file in "${manifests[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || die "not a regular manifest: $file"
    temp="$(mktemp "$file.XXXXXX")" || die "cannot stage $file"
    if ! render_manifest "$from" "$file" "$version" > "$temp" ||
       ! chmod 644 "$temp" || ! mv "$temp" "$file"; then
      rm -f "$temp"
      die "cannot update $file"
    fi
  done
  temp="$(mktemp "$source_record.XXXXXX")" || die 'cannot stage release source record'
  if ! printf '%s\n' "$source" > "$temp" ||
     ! chmod 644 "$temp" || ! mv "$temp" "$source_record"; then
    rm -f "$temp"
    die 'cannot update release source record'
  fi
  git add -- "${manifests[@]}" "$source_record" || die 'cannot stage release metadata'
}

prepare() {
  local base dev source branch old new
  base="$(commit refs/remotes/origin/main)" && dev="$(commit refs/remotes/origin/dev)" || exit 1
  source="$(commit "${2:-$dev}")" || exit 1
  clean_at "$base"
  branch="$(git symbolic-ref --quiet --short HEAD)" || die 'create a release branch first'
  [[ "$branch" != main && "$branch" != dev ]] || die 'prepare on a separate release branch'
  check_source "$base" "$dev" "$source"
  old="$(version_at "$base")" || exit 1
  [[ "$(version_at "$source")" == "$old" ]] || die 'source version differs from release base'
  new="$(next_version "$old" "${1:-patch}")" || die 'cannot calculate requested patch, minor, or major bump'
  git merge --squash --no-overwrite-ignore "$source" >&2 || die 'cannot stage the selected source tree'
  stage_metadata "$source" "$new" "$source"
  printf '%s\t%s\n' "$new" "$source"
}

sync_dev() {
  local main dev promoted base result version source
  main="$(commit refs/remotes/origin/main)" && dev="$(commit refs/remotes/origin/dev)" &&
    promoted="$(commit "$1")" || exit 1
  [[ "$promoted" == "$main" ]] || die 'sync target must be the latest promoted main'
  clean_at "$dev"
  base="$(commit "$promoted^")" || exit 1
  result="$(verify_candidate "$base" "$dev" "$promoted")" || exit 1
  IFS=$'\t' read -r version source <<<"$result"
  if git merge-base --is-ancestor "$promoted" "$dev"; then
    [[ "$(version_at "$dev")" == "$version" &&
       "$(release_blob "$dev" "$source_record")" == "$source" ]] || die 'dev metadata differs from the synced release'
    printf 'already synced %s\n' "$version"
    return
  fi
  [[ "$(version_at "$dev")" == "$(version_at "$base")" ]] || die 'dev is not at the prior release version'
  # The verified release differs from its source only in metadata. Preserve all
  # later dev changes and record the stable parent without replaying the source.
  git merge --no-commit --no-ff --no-overwrite-ignore -s ours "$promoted" >&2 || die 'cannot start dev sync'
  stage_metadata "$dev" "$version" "$source"
  printf '%s\t%s\n' "$version" "$source"
}

case "${1:-}:$#" in
  prepare:1|prepare:2|prepare:3) shift; prepare "$@" ;;
  verify:4)
    base="$(commit "$2")" && dev="$(commit "$3")" && head="$(commit "$4")" || exit 1
    verify_candidate "$base" "$dev" "$head" ;;
  sync:2) sync_dev "$2" ;;
  *) die 'usage: release.sh prepare [patch|minor|major] [source] | verify BASE DEV CANDIDATE | sync PROMOTED' ;;
esac
