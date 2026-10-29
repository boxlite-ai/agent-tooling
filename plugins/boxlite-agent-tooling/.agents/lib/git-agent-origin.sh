#!/usr/bin/env bash
# Agent origin activates audits; it never authorizes Git. Requires verdict-audit-state.sh.
# One token per declaring process in the worktree Git directory avoids shared-handoff
# replacement and audit-consumption races. A dead owner cannot identify a later shell.

_git_agent_origin_directory() { # repository -> worktree-local state directory
  local git_dir
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)" || return 1
  printf '%s/agent-tooling-agent-shells' "$git_dir"
}

git_agent_origin_record() { # repository, validated host-runner PID, start token
  local directory owner="$2" token="$3"
  [[ "$owner" =~ ^[1-9][0-9]*$ && "$owner" != 1 ]] || return 1
  verdict_audit_process_has_ancestor "$owner" "$token" || return 1
  directory="$(_git_agent_origin_directory "$1")" || return 1
  [[ ! -L "$directory" ]] || return 1
  mkdir -p "$directory" || return 1
  printf '%s\n' "$token" | verdict_audit_write_atomic "$directory/$owner"
}

git_agent_origin_classify() { # repository -> 1 (agent), 0 (human); errors are not human
  local directory current_pid="$$" parent_pid record token live_token depth=0
  if [[ -n "${CLAUDECODE:-}" || -n "${CODEX_SANDBOX:-}" || -n "${AGENT_GATED:-}" ]]; then
    printf '1'; return 0
  fi
  directory="$(_git_agent_origin_directory "$1")" || return 2
  [[ ! -L "$directory" ]] || return 2
  if [[ ! -e "$directory" ]]; then printf '0'; return 0; fi
  [[ -d "$directory" && -r "$directory" && -x "$directory" ]] || return 2
  while [[ "$current_pid" != 1 ]] && (( depth < 64 )); do
    [[ "$current_pid" =~ ^[1-9][0-9]*$ ]] || return 2
    record="$directory/$current_pid"
    if [[ -e "$record" || -L "$record" ]]; then
      token="$(verdict_audit_read_single_record "$record")" || return 2
      [[ "$token" =~ ^cksum-[0-9]+-[0-9]+$ ]] || return 2
      live_token="$(verdict_audit_process_start_token "$current_pid")" || return 2
      if [[ "$token" == "$live_token" ]]; then printf '1'; return 0; fi
    fi
    parent_pid="$(ps -p "$current_pid" -o ppid= 2>/dev/null)" || return 2
    parent_pid="${parent_pid//[[:space:]]/}"
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" != "$current_pid" ]] || return 2
    current_pid="$parent_pid"
    depth=$((depth + 1))
  done
  [[ "$current_pid" == 1 ]] || return 2
  printf '0'
}
