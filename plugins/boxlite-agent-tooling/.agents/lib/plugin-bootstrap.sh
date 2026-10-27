#!/usr/bin/env bash
# Shared startup policy; host scripts own validation and session failure state.
tooling_bootstrap_refresh() { # consumer root, running plugin root
  bash "$2/scripts/refresh-installation.sh" --if-due "$1" </dev/null >/dev/null
}

tooling_bootstrap_runtime() { # consumer root, host
  local common revision runtime
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" || return 1
  revision="$(head -n1 "$common/agent-tooling/current" 2>/dev/null)" || return 1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  runtime="$common/agent-tooling/$revision/plugins/boxlite-agent-tooling/scripts/$2-plugin-bootstrap.sh"
  [[ -r "$runtime" ]] || { printf 'agent-tooling: adopted release has no compatible %s bootstrap\n' "$2" >&2; return 1; }
  printf '%s\n' "$runtime"
}
