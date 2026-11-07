#!/usr/bin/env bash
# Loaded as BASH_ENV in a fixture runner. Do not instrument its subprocesses.
# shellcheck disable=SC2154 # Runner state is assigned after this file is sourced.
unset BASH_ENV

audit_test_drop_leader() {
  [[ "$1" == "$AUDIT_TEST_LEADER_LOSS_BOUNDARY" && "$BASH_SUBSHELL" == 0 ]] || return 0
  trap - DEBUG
  local pgid="$2" writer leader_parent leader_group writer_group
  [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 0
  read -r writer < "$CLAUDE_PROJECT_DIR/resource-parent.pid" || return 0
  [[ "$writer" =~ ^[1-9][0-9]*$ && "$writer" != "$pgid" ]] || return 0
  read -r leader_parent leader_group <<<"$(ps -p "$pgid" -o ppid= -o pgid=)"
  writer_group="$(ps -p "$writer" -o pgid= | tr -d '[:space:]')"
  [[ "$leader_parent" == "$$" && "$leader_group" == "$pgid" && "$writer_group" == "$pgid" ]] || return 0
  if [[ "${AUDIT_TEST_LOSS_TARGET:-leader}" == controller ]]; then
    local controller controller_parent controller_group
    read -r controller < "$audit_stderr_dir/group-ready" || return 0
    [[ "$controller" =~ ^[1-9][0-9]*$ ]] || return 0
    read -r controller_parent controller_group <<<"$(ps -p "$controller" -o ppid= -o pgid=)"
    [[ "$controller_parent" == "$pgid" && "$controller_group" == "$pgid" ]] || return 0
    kill -KILL "$controller" || return 0
    printf 'controller\n' > "$CLAUDE_PROJECT_DIR/leader-loss"
    printf '%s\n' "$pgid" > "$CLAUDE_PROJECT_DIR/fixture-group-leader.pid"
    return 0
  fi
  kill -KILL "$pgid" || return 0
  wait "$pgid" 2>/dev/null || true
  ! kill -0 "$pgid" 2>/dev/null && kill -0 "$writer" 2>/dev/null || return 0
  printf 'confirmed\n' > "$CLAUDE_PROJECT_DIR/leader-loss"
}

set -T
trap 'audit_test_drop_leader "$BASH_COMMAND" "${active_audit_pgid:-${audit_pgid:-0}}"' DEBUG
