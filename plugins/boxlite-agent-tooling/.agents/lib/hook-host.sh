#!/usr/bin/env bash
# Host identity and shared payload parsing for hooks. Source only; no work on load.
#
# Each host manifest exports BOXLITE_HOOK_HOST on every command. Without that marker
# the host is `unknown`, which offers every route. This is routing metadata, not
# authorization or runtime attestation.
#
# Signals that look right and are not: CLAUDECODE and AI_AGENT are inherited by
# nested agents, CODEX_SANDBOX names a sandbox, CODEX_COMPANION marks Claude
# sessions, and PATH probes fail when both CLIs are installed. subagent.test.sh
# rejects routing code that reads any of them.
#
# Tests: bash tests/lib/hook-host.test.sh

# Exported and non-empty. Ask this name's own `declare -p`: a whole-table scan can be
# forged by another variable's multiline value, and an unexported shell variable is
# the caller's local, not the host's answer.
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
  if hook_host_is_env_value BOXLITE_HOOK_HOST; then
    case "$BOXLITE_HOOK_HOST" in
      claude|codex) printf '%s' "$BOXLITE_HOOK_HOST"; return 0 ;;
    esac
  fi
  printf 'unknown'
}

# Print the verb when COMMAND runs PROGRAM at the start of the command or of any
# chain segment (after &&, ||, ;, |, &, $(, (, `, or a newline), after optional
# NAME=value assignments. PROGRAM is an ERE with exactly one capture group, the verb.
# Quoted mentions such as `echo "git push"` do not sit at a segment start. Newlines
# become `;`, so a verb on its own heredoc line may match: a false match fails closed.
hook_command_segment_verb() {  # command program-ere
  local normalized="${1//$'\n'/;}" work pattern
  work="${normalized#"${normalized%%[![:space:]]*}"}"
  pattern='(^|[[:space:]]*(&&|\|\||;|\||&|\$\(|\(|`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*'"$2"'([[:space:]]|$)'
  [[ "$work" =~ $pattern ]] || return 1
  printf '%s' "${BASH_REMATCH[4]}"
}

# Print the tool's working directory: the first present of tool_input.workdir,
# tool_input.cwd, and cwd, else FALLBACK. Fails unless it is a non-empty string
# without NUL.
hook_payload_workdir() {  # payload fallback
  jq -er --arg fallback "$2" '
    first((.tool_input.workdir, .tool_input.cwd, .cwd, $fallback) | select(. != null))
    | strings | select(length > 0 and index("\u0000") == null)
  ' <<<"$1"
}
