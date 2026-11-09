#!/usr/bin/env bash
# Shared host startup policy; host scripts own validation and session failure state.
# shellcheck disable=SC2034 # Readers return results in caller-visible globals.
tooling_bootstrap_refresh() { # consumer root, running plugin root
  bash "$2/scripts/refresh-installation.sh" --if-due "$1" </dev/null >/dev/null
}

tooling_bootstrap_cache() { # consumer root
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" || return 1
  printf '%s/agent-tooling\n' "$common"
}

tooling_bootstrap_revision() { # consumer root; prints the recorded revision
  local cache revision
  cache="$(tooling_bootstrap_cache "$1")" || return 1
  revision="$(head -n1 "$cache/current" 2>/dev/null)" || return 1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$revision"
}

tooling_bootstrap_runtime() { # consumer root, host
  local cache revision runtime
  cache="$(tooling_bootstrap_cache "$1")" || return 1
  revision="$(tooling_bootstrap_revision "$1")" || return 1
  runtime="$cache/$revision/plugins/boxlite-agent-tooling/scripts/$2-plugin-bootstrap.sh"
  [[ -r "$runtime" ]] || { printf 'agent-tooling: adopted release has no compatible %s bootstrap\n' "$2" >&2; return 1; }
  printf '%s\n' "$runtime"
}

tooling_install_is_valid() { # consumer root
  local cache revision verify
  cache="$(tooling_bootstrap_cache "$1")" || return 1
  revision="$(tooling_bootstrap_revision "$1")" || return 1
  verify="$cache/$revision/plugins/boxlite-agent-tooling/scripts/verify-installation.sh"
  [[ -x "$verify" ]] || return 1
  "$verify" "$1" >/dev/null
}

# Returns 1 when the installer fails and 2 when it leaves no valid installation; on
# either failure its combined output goes to stderr and its exit status is in
# tooling_installer_status.
tooling_run_installer_verified() { # consumer root, installer, absolute deadline
  local output
  tooling_installer_status=0
  output="$(cd "$1" && AGENT_TOOLING_SYNC_ACTIVE=1 AGENT_TOOLING_UPDATE_DEADLINE="$3" /usr/bin/env bash "$2" 2>&1)" \
    || tooling_installer_status=$?
  if [[ "$tooling_installer_status" == 0 ]] && tooling_install_is_valid "$1"; then
    return 0
  fi
  [[ -z "$output" ]] || printf '%s\n' "$output" >&2
  [[ "$tooling_installer_status" == 0 ]] && return 2
  return 1
}

# Sets adopted_tooling_revision and expected_plugin_version, or sets
# tooling_bootstrap_error and returns 1.
tooling_expected_plugin_version() { # consumer root, host (claude|codex), host display name
  local cache manifest
  if ! adopted_tooling_revision="$(tooling_bootstrap_revision "$1")" || ! cache="$(tooling_bootstrap_cache "$1")"; then
    tooling_bootstrap_error="adopted tooling revision is invalid after verification"
    return 1
  fi
  manifest="$cache/$adopted_tooling_revision/plugins/boxlite-agent-tooling/.$2-plugin/plugin.json"
  expected_plugin_version="$(jq -er '
    select(.name == "boxlite-agent-tooling") |
    .version | select(type == "string" and length > 0)
  ' "$manifest" 2>/dev/null)" || {
    tooling_bootstrap_error="adopted tooling has no valid $3 plugin version: $manifest"
    return 1
  }
}
