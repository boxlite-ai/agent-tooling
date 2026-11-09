#!/usr/bin/env bash
# Adopt the tooling revision the profile's branch (or .agent-tooling/hold) names:
# fetch it into .git/agent-tooling/<sha>/, run its setup, then write `current` last,
# so a failure anywhere earlier leaves the previous revision adopted.
# A malformed hold aborts. Rationale: scripts/README.md#installation-runtime.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository\n' >&2; exit 2; }
profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { printf 'agent-tooling: perl is required\n' >&2; exit 1; }
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/git-environment.sh
source "$plugin_root/.agents/lib/git-environment.sh"
# shellcheck source=../.agents/lib/tooling-command.sh
source "$plugin_root/.agents/lib/tooling-command.sh"
# shellcheck source=../.agents/lib/tooling-profile.sh
source "$plugin_root/.agents/lib/tooling-profile.sh"
# shellcheck source=../.agents/lib/install-lock.sh
source "$plugin_root/.agents/lib/install-lock.sh"
# A linked-worktree hook exports GIT_DIR; every Git call below must address the
# cache or rediscover the consumer from repo_root, never inherit it.
tooling_git_clear_repository_environment
update_deadline="${AGENT_TOOLING_UPDATE_DEADLINE:-$(( $(date +%s) + 120 ))}"

tooling_profile_read "$profile_file" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }

cache_parent="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)/agent-tooling"
record_file="$cache_parent/current"
mkdir -p "$cache_parent"

lock_dir="$cache_parent/.install.lock"
lease_held=0
lock_unavailable() {
  printf 'agent-tooling: another installation is already in progress or the lock is unavailable: %s\n' "$lock_dir" >&2
  exit 1
}
if [[ "${1:-}" == --install-lease-held ]]; then
  shift
  install_lock_native "$cache_parent" && install_lock_lease verify "$cache_parent" || lock_unavailable
  lease_held=1
elif install_lock_native "$cache_parent"; then
  install_lock_lease enter "$cache_parent" bash -- "$0" --install-lease-held "$@" || lock_unavailable
  exit 0
else
  mkdir "$lock_dir" 2>/dev/null || lock_unavailable
fi

scratch=""
cleanup() {
  if [[ -n "$scratch" && -d "$scratch" && "$scratch" == "$cache_parent"/.install.* ]]; then
    rm -rf -- "$scratch"
  fi
  if (( lease_held )); then
    exec 9>&-
  else
    rm -f -- "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
(( lease_held )) || printf '%s\n' "$$" > "$lock_dir/pid"

recorded_sha() {
  local rec
  rec="$(head -n1 "$record_file" 2>/dev/null || true)"
  [[ "$rec" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$rec"
}

target_sha=""
target_source=""
is_offline_repair=0
tooling_hold_read "$repo_root/.agent-tooling/hold" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }
if [[ -n "$hold_sha" ]]; then
  target_sha="$hold_sha"
  target_source="hold"
else
  resolved="$(tooling_command "$update_deadline" git ls-remote "https://github.com/$tooling_repo.git" "refs/heads/$tooling_ref" | awk 'NR==1{print $1}')" || resolved=""
  if [[ "$resolved" =~ ^[0-9a-f]{40}$ ]]; then
    target_sha="$resolved"
    target_source="$tooling_ref"
  elif current="$(recorded_sha)" && [[ -d "$cache_parent/$current" ]]; then
    # The record is shared, but hook paths are per worktree: repair this one offline.
    printf 'agent-tooling: could not resolve %s on %s; keeping %s\n' "$tooling_ref" "$tooling_repo" "$current" >&2
    target_sha="$current"
    is_offline_repair=1
  else
    printf 'agent-tooling: could not resolve %s on %s and no revision is installed\n' "$tooling_ref" "$tooling_repo" >&2
    exit 1
  fi
fi

checkout="$cache_parent/$target_sha"
if [[ -e "$checkout" ]]; then
  actual="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
  [[ "$actual" == "$target_sha" ]] || {
    printf 'agent-tooling: cached checkout has unexpected HEAD: %s\n' "$checkout" >&2
    exit 1
  }
else
  scratch="$(mktemp -d "$cache_parent/.install.XXXXXX")"
  git -C "$scratch" init -q
  git -C "$scratch" remote add origin "https://github.com/$tooling_repo.git"
  tooling_command "$update_deadline" git -C "$scratch" fetch -q --depth 1 origin "$target_sha"
  git -C "$scratch" -c advice.detachedHead=false checkout -q --detach "$target_sha"
  actual="$(git -C "$scratch" rev-parse HEAD)"
  [[ "$actual" == "$target_sha" ]] || {
    printf 'agent-tooling: fetched %s instead of resolved %s\n' "$actual" "$target_sha" >&2
    exit 1
  }
  mv "$scratch" "$checkout"
  scratch=""
fi

setup="$checkout/plugins/boxlite-agent-tooling/scripts/setup.sh"
[[ -x "$setup" ]] || { printf 'agent-tooling: fetched checkout has no executable setup script\n' >&2; exit 1; }
"$setup" "$repo_root"

if [[ "$is_offline_repair" == 1 ]]; then
  "$checkout/plugins/boxlite-agent-tooling/scripts/verify-installation.sh" "$repo_root"
  printf 'agent-tooling: repaired installation from cached revision %s (offline)\n' "$target_sha"
  exit 0
fi

# Record before history: a crash between them may drop a history line, but history
# never claims an adoption that did not happen.
tmp_record="$cache_parent/.current.$$"
printf '%s\n' "$target_sha" > "$tmp_record"
mv "$tmp_record" "$record_file"
printf '%s %s %s\n' "$(date +%s)" "$target_source" "$target_sha" >> "$cache_parent/history.log"
touch "$cache_parent/last-check"
printf 'agent-tooling: adopted %s (%s)\n' "$target_sha" "$target_source"
