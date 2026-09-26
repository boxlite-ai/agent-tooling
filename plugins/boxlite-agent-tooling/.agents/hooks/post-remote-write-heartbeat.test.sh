#!/usr/bin/env bash
# Exercise host scheduling instructions at the real PostToolUse boundary.
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
while IFS= read -r name; do unset "$name"; done < <(git rev-parse --local-env-vars)
unset BOXLITE_PR_WATCH
mkdir -p "$scratch/bin"
printf '#!/bin/sh\nprintf "42\\n"\n' > "$scratch/bin/gh"
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
git init -q -b heartbeat-test "$scratch/repo"
git -C "$scratch/repo" remote add origin https://github.com/example/repo.git
git -C "$scratch/repo" -c user.name=test -c user.email=test@example.com \
  -c core.hooksPath=/dev/null commit -q --allow-empty -m fixture
cd "$scratch/repo"

context() { # host plugin-path [command-field] [response]
  local host="$1" root="$2"
  local payload response="${4:-}"
  [[ -n "$response" ]] || response='{"stdout":"https://github.com/example/repo/pull/42"}'
  payload="$(jq -nc --arg field "${3:-command}" --argjson response "$response" \
    '{tool_input:{($field):"gh pr create"},tool_response:$response}')"
  case "$host" in
    codex) printf '%s' "$payload" | env -u CLAUDE_PLUGIN_ROOT PLUGIN_ROOT="$root" \
      bash "$root/.agents/hooks/post-remote-write-watch.sh" ;;
    claude) printf '%s' "$payload" | env -u PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$root" \
      bash "$root/.agents/hooks/post-remote-write-watch.sh" ;;
    unknown) printf '%s' "$payload" | env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT \
      bash "$root/.agents/hooks/post-remote-write-watch.sh" ;;
  esac | jq -er '.hookSpecificOutput.additionalContext'
}

require_text() {
  [[ "$1" == *"$2"* ]] || { printf 'FAIL: missing %s\n' "$2" >&2; exit 1; }
}

check_heartbeat() {
  local rendered="$1"
  require_text "$rendered" 'native heartbeat'
  require_text "$rendered" 'every 1 minute'
  require_text "$rendered" 'this task'
  require_text "$rendered" 'reuse'
  require_text "$rendered" 'escalation-policy.md'
  require_text "$rendered" 'Stream command:'
  [[ "${rendered%%Stream command:*}" == *'Read policy'* ]] || {
    printf 'FAIL: setup policy follows the executable command\n' >&2; exit 1;
  }
  [[ "$rendered" != *'natural pauses'* ]]
  (( $(LC_ALL=C printf '%s' "$rendered" | wc -c) <= 1400 ))
}

native_context="$(context codex "$plugin" cmd \
  '{"output":"https://github.com/example/repo/pull/77","exit_code":0}')" || {
  printf 'FAIL: native cmd input did not reach the watcher route\n' >&2
  exit 1
}
check_heartbeat "$native_context"
require_text "$native_context" 'PR #77'
for failed_response in \
  '{"output":"permission check failed","exit_code":1}' \
  '{"output":"still running","exit_code":null}' \
  '{"output":"fatal: rejected push","exit_code":0}'; do
  failed_context="$(context codex "$plugin" cmd "$failed_response")" || true
  [[ -z "$failed_context" ]] || { printf 'FAIL: failed native command armed a watcher\n' >&2; exit 1; }
done

codex_context="$(context codex "$plugin")"
check_heartbeat "$codex_context"
[[ "$codex_context" != *'Monitor({'* ]]
claude_context="$(context claude "$plugin")"
require_text "$claude_context" 'Monitor({'
[[ "$claude_context" != *'native heartbeat'* ]]
unknown_context="$(context unknown "$plugin")"
check_heartbeat "$unknown_context"
require_text "$unknown_context" 'Monitor({'

# The compact rendering must retain scheduling, not silently lose idle delivery.
long_parent="$scratch/$(printf '%0150d' 0 | tr 0 p)"
mkdir -p "$long_parent"
ln -s "$plugin" "$long_parent/plugin"
compact_context="$(context codex "$long_parent/plugin")"
check_heartbeat "$compact_context"
[[ "$compact_context" != *'using the route below'* ]]

# Contract guards catch omissions; they do not prove model compliance.
lifecycle="$(cat "$plugin/.agents/watch/consumer-lifecycle.md")"
saved_prompt="$(sed -n 's/^> //p' "$plugin/.agents/watch/consumer-lifecycle.md")"
policy="$(cat "$plugin/.agents/watch/escalation-policy.md")"
require_text "$lifecycle" 'One active consumer per generation'
require_text "$lifecycle" 'one recovery attempt'
require_text "$lifecycle" 'watch_end is not PR closure'
require_text "$lifecycle" 'absolute policy path'
require_text "$saved_prompt" 'If unreadable, report and pause'
require_text "$saved_prompt" 'Read POLICY'
require_text "$saved_prompt" 'cancelled checks'
require_text "$saved_prompt" 'bots/threads'
require_text "$saved_prompt" 'PR links'
require_text "$lifecycle" '`notificationPolicy: failed_runs_only`'
require_text "$lifecycle" 'successful-run alerts'
require_text "$saved_prompt" 'otherwise stay silent'
require_text "$saved_prompt" 'Visible reports need TL;DR'
require_text "$lifecycle" 'inspect both revisions'
require_text "$lifecycle" 'Without background support'
require_text "$lifecycle" 'report unavailable idle coverage'
require_text "$lifecycle" 'notification-only'
require_text "$policy" 'runner OOM'
require_text "$policy" 'never-started jobs'
require_text "$policy" 'depends on product intent'
require_text "$policy" 'what changed and why'
require_text "$policy" 'pre-existing findings in the PR'
require_text "$unknown_context" 'inspect both revisions'
printf 'PASS: normal, compact, and unknown routes retain one-minute heartbeats; Claude retains Monitor\n'
