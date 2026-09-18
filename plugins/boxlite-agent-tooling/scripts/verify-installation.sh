#!/usr/bin/env bash
# Fail-closed installation check the commit and push gates run. Verifies against the
# RECORDED revision (.git/agent-tooling/current, written last by a successful
# install), not against anything remote: a pure local check, so gates keep working
# offline and a network problem can never fail open. Advancing that revision stays the
# job of the lifecycle refresh (scripts/refresh-installation.sh); this check only reports
# when a lock left behind has stopped that refresh from running at all.
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository or pass its root\n' >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { printf 'agent-tooling: perl is required\n' >&2; exit 1; }
profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing %s\n' "$profile_file" >&2; exit 1; }

common_git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
# A refresh killed before its trap runs leaves its lock behind, and the lock is taken with
# a bare mkdir whose only failure path is a silent exit: every later refresh then skips,
# the recorded revision stops advancing on its own, and the refresh log nobody reads is the
# only place that could have said so. Breaking the lock here would race a live holder, so
# this says it where a person is already looking, on the next commit or push. A warning,
# not a failure: the recorded revision is still valid, it has only stopped moving.
refresh_lock="$common_git_dir/agent-tooling/.refresh.lock"
if [[ -d "$refresh_lock" ]]; then
  lock_mtime="$(stat -c '%Y' "$refresh_lock" 2>/dev/null || stat -f '%m' "$refresh_lock" 2>/dev/null || true)"
  now="$(date +%s)"
  # Whole hours, not a timestamp: date renders an epoch differently on GNU and BSD, and the
  # age is what matters. Removal is left to the reader and made conditional, because this
  # cannot tell a dead refresh from a slow one, and a running refresh holds the same lock.
  if [[ "$lock_mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] && (( now - lock_mtime >= 3600 )); then
    printf 'agent-tooling: no refresh has completed for %sh; if none is running, remove %s to let them resume\n' \
      "$(( (now - lock_mtime) / 3600 ))" "$refresh_lock" >&2
  fi
fi

record_file="$common_git_dir/agent-tooling/current"
desired_sha="$(head -n1 "$record_file" 2>/dev/null || true)"
[[ "$desired_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'agent-tooling: no installed revision is recorded; run ./.agent-tooling/install.sh\n' >&2
  exit 1
}

# A hold outranks the record: gates stay closed until the held revision is adopted.
hold_file="$repo_root/.agent-tooling/hold"
if [[ -e "$hold_file" ]]; then
  hold_sha="$(tr -d '\n' < "$hold_file")"
  { [[ "$hold_sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$(wc -c < "$hold_file")" -le 41 ]]; } || {
    printf 'agent-tooling: %s must contain exactly one full lowercase commit SHA\n' "$hold_file" >&2
    exit 1
  }
  [[ "$desired_sha" == "$hold_sha" ]] || {
    printf 'agent-tooling: hold %s is not adopted; run ./.agent-tooling/install.sh\n' "$hold_sha" >&2
    exit 1
  }
fi

expected_plugin="$common_git_dir/agent-tooling/$desired_sha/plugins/boxlite-agent-tooling"
running_plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
running_checkout="$(cd "$running_plugin/../.." && pwd -P)"
configured="$(git -C "$repo_root" config --worktree --get core.hooksPath 2>/dev/null || true)"

[[ "$configured" == /* ]] || {
  printf 'agent-tooling: worktree core.hooksPath is not an absolute shared-tooling path\n' >&2
  exit 1
}
configured="$(cd "$configured" 2>/dev/null && pwd -P)" || {
  printf 'agent-tooling: configured hooks path does not exist: %s\n' "$configured" >&2
  exit 1
}
expected_hooks="$(cd "$expected_plugin/.githooks" 2>/dev/null && pwd -P)" || {
  printf 'agent-tooling: recorded tooling checkout is not installed: %s\n' "$expected_plugin" >&2
  exit 1
}
running_head="$(git --git-dir="$running_checkout/.git" rev-parse HEAD 2>/dev/null || true)"

[[ "$running_head" == "$desired_sha" ]] || {
  printf 'agent-tooling: running revision %s does not match recorded revision %s\n' "${running_head:-unknown}" "$desired_sha" >&2
  exit 1
}
[[ "$configured" == "$expected_hooks" && "$configured" == "$running_plugin/.githooks" ]] || {
  printf 'agent-tooling: configured hooks do not match recorded revision %s\n' "$desired_sha" >&2
  exit 1
}
