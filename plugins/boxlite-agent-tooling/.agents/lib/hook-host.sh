#!/usr/bin/env bash
# Which coding agent is invoking this hook right now.
# Source this file; it performs no work on load.
#
# The signal
# ----------
# Each host injects its own name for the plugin root into the environment of the hook
# process it spawns, and every wired command in hooks/hooks.json and
# hooks/codex-hooks.json already resolves it the same way:
#
#     ${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}      Codex first, Claude Code second
#
# The scope is one invocation. The interactive session does not carry these names, so
# nothing downstream of it — the Bash tool, a git hook, a shelled-out CLI, a nested
# agent — inherits a value and mistakes itself for its parent.
#
# Naming a host requires exactly ONE of those names. The root expression breaks a tie
# because it must load libraries from somewhere; this must not, because the two
# questions differ. `${PLUGIN_ROOT:-...}` asks which tree to read. This asks who is
# calling, and with both names present that is genuinely unanswerable: one host nested
# inside another leaves its own root in the environment the inner hook inherits, so a
# preference either way eventually hands someone the other host's route. Answering
# `unknown` prints every route instead, which every host can act on.
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
hook_host_is_env_root() {  # $1 = variable name
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
  hook_host_is_env_root PLUGIN_ROOT && codex_root=true
  hook_host_is_env_root CLAUDE_PLUGIN_ROOT && claude_root=true
  if [[ "$codex_root" == true && "$claude_root" == true ]]; then
    # Both names exported is not a tie to be broken, it is a caller that cannot be
    # identified. One host nested inside another leaves its own root in the
    # environment the inner hook inherits, so whichever name were preferred here
    # would hand somebody the other host's route — the single failure this accessor
    # exists to prevent. `unknown` prints every route, which each host can act on.
    printf 'unknown'
  elif [[ "$codex_root" == true ]]; then
    printf 'codex'
  elif [[ "$claude_root" == true ]]; then
    printf 'claude'
  else
    printf 'unknown'
  fi
}
