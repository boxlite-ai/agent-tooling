#!/usr/bin/env bash
# Advance the recorded tooling revision to the current tip of tooling.ref.
#
# This is the ONLY place besides the bootstrap that touches the network, and it is
# never on the commit path: sync-installation.sh spawns it in the background after
# lifecycle events, throttled by the last-check stamp, and the gates keep verifying
# against the existing record until an adoption completes. Adoption itself is
# delegated to the consumer's committed install.sh — one canonical path that
# validates before it records, so a broken tip is fetched, rejected, and never
# becomes current.
#
# Best-effort by design when the network is the problem (offline is a normal state
# for a laptop), loud when the configuration is the problem (a broken profile or an
# unusable installer would otherwise fail silently forever).
set -uo pipefail

if_due=0
if [[ "${1:-}" == --if-due ]]; then if_due=1; shift; fi

repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository or pass its root\n' >&2; exit 2; }
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/git-environment.sh
source "$plugin_root/.agents/lib/git-environment.sh" || exit 1
# shellcheck source=../.agents/lib/tooling-command.sh
source "$plugin_root/.agents/lib/tooling-command.sh" || exit 1
tooling_git_clear_repository_environment || exit 1
cd -- "$repo_root" || exit 1
repo_root="$(pwd -P)"
profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { printf 'agent-tooling: perl is required\n' >&2; exit 1; }

installer="$repo_root/.agent-tooling/install.sh"
common_git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" || exit 1
cache_parent="$common_git_dir/agent-tooling"
mkdir -p "$cache_parent"

minutes="${AGENT_TOOLING_REFRESH_MINUTES:-15}"
[[ "$minutes" =~ ^[0-9]{1,5}$ ]] || {
  printf 'agent-tooling: AGENT_TOOLING_REFRESH_MINUTES must be a nonnegative integer (0-99999)\n' >&2
  exit 1
}
[[ "$if_due" != 1 || "${AGENT_TOOLING_REFRESH:-1}" != 0 ]] || exit 0
lock_dir="$cache_parent/.refresh.lock"
mkdir "$lock_dir" 2>/dev/null || exit 0
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
update_deadline=$(( $(date +%s) + 30 ))

run_installer() {
  [[ -x "$installer" ]] || {
    printf 'agent-tooling: refresh needs an executable %s\n' "$installer" >&2
    return 1
  }
  AGENT_TOOLING_SYNC_ACTIVE=1 AGENT_TOOLING_UPDATE_DEADLINE="$update_deadline" "$installer"
}

# A hold means there is nothing to poll: just make sure the held revision is the
# adopted one, and let the installer complain if it cannot be.
if [[ -e "$repo_root/.agent-tooling/hold" ]]; then
  "$plugin_root/scripts/verify-installation.sh" "$repo_root" >/dev/null 2>&1 && exit 0
  run_installer
  exit $?
fi

tooling_repo="$(jq -er '.tooling.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: tooling.repository is required\n' >&2
  exit 1
}
[[ "$tooling_repo" == "boxlite-ai/agent-tooling" ]] || {
  printf 'agent-tooling: unsupported tooling repository: %s\n' "$tooling_repo" >&2
  exit 1
}
tooling_ref="$(jq -er '.tooling.ref | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: tooling.ref must name the branch to float on\n' >&2
  exit 1
}
[[ ! "$tooling_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'agent-tooling: tooling.ref names a branch; to freeze a revision write it to .agent-tooling/hold\n' >&2
  exit 1
}
if [[ "$tooling_ref" == -* ]] || ! git check-ref-format "refs/heads/$tooling_ref" >/dev/null 2>&1; then
  printf 'agent-tooling: tooling.ref is not a valid branch name: %s\n' "$tooling_ref" >&2
  exit 1
fi

if [[ "$if_due" == 1 && "$minutes" != 0 ]]; then
  [[ -z "$(find "$cache_parent" -maxdepth 1 -name last-check -mmin "-$minutes")" ]] || exit 0
fi
# Stamp the attempt whatever its outcome: an unreachable remote should back off for
# one interval, not be retried by every subsequent lifecycle event.
touch "$cache_parent/last-check"
resolved="$(tooling_command "$update_deadline" git ls-remote "https://github.com/$tooling_repo.git" "refs/heads/$tooling_ref" | awk 'NR==1{print $1}')" || true
if [[ ! "$resolved" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'agent-tooling: could not resolve %s on %s; keeping the recorded revision\n' "$tooling_ref" "$tooling_repo" >&2
  exit 0
fi

current="$(head -n1 "$cache_parent/current" 2>/dev/null || true)"
[[ "$resolved" != "$current" ]] || exit 0
if run_installer; then exit 0; fi
if "$plugin_root/scripts/validate-profile.sh" "$repo_root" >/dev/null &&
   "$plugin_root/scripts/verify-installation.sh" "$repo_root" >/dev/null; then
  printf 'agent-tooling: refresh failed; keeping the validated recorded revision\n' >&2
  exit 0
fi
exit 1
