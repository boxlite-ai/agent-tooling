#!/usr/bin/env bash
# Which coding agent is invoking this hook right now.
# Source this file; it performs no work on load.
#
# Each host manifest sets BOXLITE_HOOK_HOST on every command, replacing inherited
# markers. Codex exports both plugin-root names as aliases; roots alone cannot
# distinguish that from nesting. Claude's manifest prefers its own root when loading
# scripts. Generic hooks explicitly identify as unknown. This is routing metadata,
# not authorization or runtime attestation.
#
# Legacy callers without a marker retain single-root inference. Both roots remain
# unknown there: equal roots can mean either aliases or same-installation nesting.
#
# Signals that look right and are not
# -----------------------------------
# Each of these is session-scoped and exported, so it reports what launched the process
# tree rather than who is calling this hook:
#
#   CLAUDECODE       inherited by every child. run-commit-push-audit.sh spawns the
#                    Codex CLI from inside a hook; that process reads it as "Claude".
#   AI_AGENT         deliberately preserves a foreign agent's value instead of
#                    overwriting it, so under nesting it names the OUTERMOST agent.
#   CODEX_SANDBOX    names the active sandbox, not the agent. Routing on it is the bug
#                    this accessor exists to make unreachable: the wiring that launched
#                    that gate forced it non-empty, so it picked wrong on every host.
#   CODEX_COMPANION  set by the openai-codex plugin FOR Claude Code, so it marks a
#                    Claude session as Codex.
#
# Probing PATH for a vendor binary is the same mistake — both CLIs can be installed at
# once. subagent.test.sh greps for every name above.
#
# Tests: bash .agents/lib/hook-host.test.sh

# Exported AND non-empty:
#   exported  — only the environment carries a host's answer. A same-named shell
#               variable is whatever the caller named its own local, and PLUGIN_ROOT is
#               generic enough that this repository already uses it that way
#               (subagent.test.sh:22, lifecycle.test.sh:4); reading the shell's
#               variable table would let any of those silently reroute a gate.
#   non-empty — a name exported empty says nothing, and the root expression skips an
#               empty PLUGIN_ROOT for the same reason.
#
# Asked of THIS name's own declaration, never of the serialized export table. Values
# are attacker-shaped text: one exported variable holding a newline followed by
# `declare -x PLUGIN_ROOT=` forges that marker inside a whole-table scan, and a caller
# with an unexported local of the same name is then routed as the wrong host. A single
# `declare -p NAME` cannot be forged that way — the value can only appear after the
# attribute field, never in front of it.
hook_host_is_env_value() {  # $1 = variable name
  local declaration attributes
  [[ -n "${!1:-}" ]] || return 1
  declaration="$(declare -p "$1" 2>/dev/null)" || return 1
  [[ "$declaration" == "declare "* ]] || return 1
  attributes="${declaration#declare }"
  attributes="${attributes%% *}"
  [[ "$attributes" == *x* ]]
}

hook_host_kind() {  # -> claude | codex | unknown
  local codex_root=false claude_root=false
  if hook_host_is_env_value BOXLITE_HOOK_HOST; then
    case "$BOXLITE_HOOK_HOST" in
      claude|codex) printf '%s' "$BOXLITE_HOOK_HOST" ;;
      *) printf 'unknown' ;;
    esac
    return 0
  fi
  hook_host_is_env_value PLUGIN_ROOT && codex_root=true
  hook_host_is_env_value CLAUDE_PLUGIN_ROOT && claude_root=true
  if [[ "$codex_root" == true && "$claude_root" == true ]]; then
    # No manifest marker: aliases and nesting are indistinguishable.
    printf 'unknown'
  elif [[ "$codex_root" == true ]]; then
    printf 'codex'
  elif [[ "$claude_root" == true ]]; then
    printf 'claude'
  else
    printf 'unknown'
  fi
}
