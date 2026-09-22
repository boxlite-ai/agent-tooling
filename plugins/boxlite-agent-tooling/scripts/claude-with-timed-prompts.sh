#!/usr/bin/env bash
# Load this plugin and opt one Claude session into idle dismissal without editing settings.
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
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec claude "$@" --plugin-dir "$plugin"
