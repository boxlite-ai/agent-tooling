#!/usr/bin/env bash
# Configure local idle dismissal; unsupported sessions keep non-blocking questions.
set -euo pipefail
command -v claude >/dev/null || { printf 'claude-with-timed-prompts: claude is required\n' >&2; exit 2; }
version="$(claude --version)"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] \
  || ! (( 10#${BASH_REMATCH[1]} > 2 || (10#${BASH_REMATCH[1]} == 2 \
       && (10#${BASH_REMATCH[2]} > 1 || (10#${BASH_REMATCH[2]} == 1 && 10#${BASH_REMATCH[3]} >= 198))) )); then
  printf 'claude-with-timed-prompts: Claude Code 2.1.198 or later is required\n' >&2
  exit 2
fi
export CLAUDE_AFK_TIMEOUT_MS=180000
unset BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS
can_use_native_questions=true
for argument in "$@"; do
  case "$argument" in
    --remote-control|--remote-control=*|--rc|--rc=*|remote-control|rc|\
    --settings|--settings=*|-p|--print|--print=*|--bg|--background|--cloud|--cloud=*)
      can_use_native_questions=false; break ;;
  esac
done
if [[ "$can_use_native_questions" == true ]]; then
  export BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1
  # Also block later /remote-control activation; startup=false alone is insufficient.
  set -- --settings '{"remoteControlAtStartup":false,"disableRemoteControl":true}' "$@"
else
  printf 'claude-with-timed-prompts: using non-blocking questions for this invocation\n' >&2
fi
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec claude "$@" --plugin-dir "$plugin"
