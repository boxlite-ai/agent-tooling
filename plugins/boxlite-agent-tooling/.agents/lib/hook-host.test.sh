#!/usr/bin/env bash
# Tests for .agents/lib/hook-host.sh
#
# Two things are worth guarding here, and only one of them is the truth table.
#
#   1. The mapping itself, including the cases a hand-written conditional gets wrong:
#      both names set at once, and a name exported empty.
#   2. That the answer never disagrees with the root expression every wired command
#      uses. Detection and root resolution read the same two variables; if they ever
#      picked differently, a hook would load its libraries from one host's tree while
#      announcing the other host's route. The oracle is bash's own parameter
#      expansion, so this compares production code against the mechanism the
#      manifests actually rely on rather than against a restatement of the rule.
#
# Run with:  bash .agents/lib/hook-host.test.sh
# Exits non-zero on any failure.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing is itself under test: a library that writes to stdout or exits corrupts
# every hook that loads it, and hooks here speak JSON on stdout.
source_output="$(source "$LIB_DIR/hook-host.sh" 2>&1)"
source_status=$?

# shellcheck source=./hook-host.sh
source "$LIB_DIR/hook-host.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got=$2 want=$3)"; fi
}

# "-" means the variable is absent rather than empty; the two are distinct inputs.
with_env() {  # PLUGIN_ROOT CLAUDE_PLUGIN_ROOT command...
  local codex_root="$1" claude_root="$2"; shift 2
  (
    if [[ "$codex_root" == "-" ]]; then unset PLUGIN_ROOT
    else export PLUGIN_ROOT="$codex_root"; fi
    if [[ "$claude_root" == "-" ]]; then unset CLAUDE_PLUGIN_ROOT
    else export CLAUDE_PLUGIN_ROOT="$claude_root"; fi
    "$@"
  )
}

# The expansion every wired command in hooks/hooks.json and hooks/codex-hooks.json
# uses to find the plugin. host-parity.test.sh proves the manifests still spell it
# this way; this is that same expression, evaluated.
resolved_root() { printf '%s' "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"; }

echo "## Loading the library is inert"
check_eq "sourcing writes nothing to stdout or stderr" "$source_output" ""
check_eq "sourcing succeeds"                           "$source_status" "0"

echo
echo "## Each host is named by the root it injects"
check_eq "Claude Code injects only CLAUDE_PLUGIN_ROOT" \
  "$(with_env - /claude/root hook_host_kind)" "claude"
check_eq "Codex injects only PLUGIN_ROOT" \
  "$(with_env /codex/root - hook_host_kind)" "codex"
check_eq "no runtime injects either name" \
  "$(with_env - - hook_host_kind)" "unknown"

echo
echo "## A same-named shell variable is not a host"
# The real instance this defends against: subagent.test.sh:22 and lifecycle.test.sh:4
# both use PLUGIN_ROOT as an ordinary local. Sourcing this library into either shell
# must not turn it into a Codex host.
local_plugin_root_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    PLUGIN_ROOT="/some/script/local"
    hook_host_kind
  )
}
check_eq "an unexported PLUGIN_ROOT does not make the caller Codex" \
  "$(local_plugin_root_kind)" "unknown"
local_claude_root_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    CLAUDE_PLUGIN_ROOT="/some/script/local"
    hook_host_kind
  )
}
check_eq "an unexported CLAUDE_PLUGIN_ROOT does not make the caller Claude Code" \
  "$(local_claude_root_kind)" "unknown"
# ...and a local must not mask a real host either.
mixed_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    export CLAUDE_PLUGIN_ROOT="/claude/root"
    PLUGIN_ROOT="/some/script/local"
    hook_host_kind
  )
}
check_eq "a local PLUGIN_ROOT cannot mask the exported Claude root" \
  "$(mixed_kind)" "claude"

echo
echo "## An exported value cannot forge the marker for another name"
# Values are text the caller does not control. Deciding exportedness by scanning the
# whole serialized table lets one variable's multiline value carry the exact bytes that
# another name's entry would have, and a caller holding an unexported local of that
# name is then routed as the wrong host.
forged_codex_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    PLUGIN_ROOT="/some/script/local"
    export DECOY_ROOT=$'value\ndeclare -x PLUGIN_ROOT="/forged/codex"'
    hook_host_kind
  )
}
check_eq "a forged PLUGIN_ROOT entry in another value is not a host" \
  "$(forged_codex_kind)" "unknown"
forged_claude_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    CLAUDE_PLUGIN_ROOT="/some/script/local"
    export DECOY_ROOT=$'value\ndeclare -x CLAUDE_PLUGIN_ROOT="/forged/claude"'
    hook_host_kind
  )
}
check_eq "a forged CLAUDE_PLUGIN_ROOT entry in another value is not a host" \
  "$(forged_claude_kind)" "unknown"
# The forgery must not be able to override a genuine host either.
forged_over_real_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    export CLAUDE_PLUGIN_ROOT="/claude/root"
    PLUGIN_ROOT="/some/script/local"
    export DECOY_ROOT=$'value\ndeclare -x PLUGIN_ROOT="/forged/codex"'
    hook_host_kind
  )
}
check_eq "a forged entry cannot displace the real exported host" \
  "$(forged_over_real_kind)" "claude"

echo
echo "## Cases a hand-written conditional gets wrong"
# Both names present is the nesting case, not a tie: a hook running under one host
# inside another inherits the outer host's root alongside its own. Preferring either
# name hands somebody the other host's route, so neither is named.
check_eq "both names set names no host" \
  "$(with_env /codex/root /claude/root hook_host_kind)" "unknown"
# The direction that motivated it: Claude injects its root for a hook it spawned, while
# the Codex process that launched the session still has PLUGIN_ROOT in the environment.
# Answering `codex` there would emit spawn_agent() to a runtime that has no such call.
claude_under_codex_kind() {
  (
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    export PLUGIN_ROOT="/outer/codex"
    export CLAUDE_PLUGIN_ROOT="/inner/claude"
    hook_host_kind
  )
}
check_eq "a Claude hook nested under Codex is not called Codex" \
  "$(claude_under_codex_kind)" "unknown"
# An exported-but-empty name has told us nothing, and the root expression skips it.
check_eq "an empty PLUGIN_ROOT falls through to Claude Code" \
  "$(with_env '' /claude/root hook_host_kind)" "claude"
check_eq "both names empty is no runtime" \
  "$(with_env '' '' hook_host_kind)" "unknown"

echo
echo "## A named host owns the root the wired commands resolve"
# Naming a host is a claim about which tree the hook is running out of, so whenever one
# IS named it must own the root that `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}` picks —
# otherwise a hook reads one host's tree while announcing the other's route. Exactly one
# name present is the only case that can carry that claim; zero or two must decline it.
for codex_root in - '' /codex/root; do
  for claude_root in - '' /claude/root; do
    kind="$(with_env "$codex_root" "$claude_root" hook_host_kind)"
    root="$(with_env "$codex_root" "$claude_root" resolved_root)"
    codex_set=no; [[ "$codex_root" != - && -n "$codex_root" ]] && codex_set=yes
    claude_set=no; [[ "$claude_root" != - && -n "$claude_root" ]] && claude_set=yes
    label="PLUGIN_ROOT=[$codex_root] CLAUDE_PLUGIN_ROOT=[$claude_root]"
    if [[ "$codex_set" == yes && "$claude_set" == yes ]]; then
      check_eq "$label -> ambiguous, so no host is named" "$kind" "unknown"
    elif [[ "$codex_set" == yes ]]; then
      check_eq "$label -> codex owns the resolved root" "$kind:$root" "codex:$codex_root"
    elif [[ "$claude_set" == yes ]]; then
      check_eq "$label -> claude owns the resolved root" "$kind:$root" "claude:$claude_root"
    else
      check_eq "$label -> no root, so no host is named" "$kind:$root" "unknown:"
    fi
  done
done

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
