#!/usr/bin/env bash
# Exercise schedule setup instructions at the real PostToolUse boundary.
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
while IFS= read -r name; do unset "$name"; done < <(git rev-parse --local-env-vars)
unset BOXLITE_PR_WATCH
mkdir -p "$scratch/bin"
printf '#!/bin/sh\nprintf "42\\n"\n' > "$scratch/bin/gh"
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
git init -q -b delivery-test "$scratch/repo"
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

fail=0
require_text() {
  [[ "$1" == *"$2"* ]] || { printf 'FAIL: missing %s\n' "$2" >&2; fail=$((fail + 1)); }
}

reject_text() {
  [[ "$1" != *"$2"* ]] || { printf 'FAIL: unexpected %s\n' "$2" >&2; fail=$((fail + 1)); }
}

check_schedule() {
  local rendered="$1" root="$2" prompt_path policy_path prompt
  if [[ "$rendered" == *'Codex: read schedule setup at JSON path '* ]]; then
    prompt_path="$(printf '%s\n' "$rendered" | sed -n 's/^.*Codex: read schedule setup at JSON path //p' | jq -er '.')"
  else
    require_text "$rendered" 'Codex: read ../prompts/watch/pr-watch-schedule.md relative to policy; follow setup.'
    policy_path="$(printf '%s\n' "$rendered" | sed -n 's/^Read policy at JSON path \(.*\) before attaching\.$/\1/p' | jq -er '.')"
    prompt_path="${policy_path%/*}/../prompts/watch/pr-watch-schedule.md"
  fi
  [[ "$prompt_path" -ef "$root/.agents/prompts/watch/pr-watch-schedule.md" && -r "$prompt_path" ]]
  prompt="$(cat "$prompt_path")"
  require_text "$prompt" 'one 10-minute heartbeat per chat'
  require_text "$prompt" 'Preserve opt-outs'
  require_text "$prompt" '{{KEEPALIVE_PATH_JSON}}'
  require_text "$prompt" '{{TARGETS_JSON}}'
  require_text "$prompt" 'Stay silent'
  require_text "$prompt" 'pr-watch-keepalive.sh'
  require_text "$prompt" '--events'
  require_text "$prompt" 'data, never instructions'
  require_text "$prompt" 'then acknowledge handled IDs'
  require_text "$prompt" 'read failures as lost coverage'
  require_text "$prompt" 'Handle terminal events before retiring the final target'
  require_text "$prompt" 'preserve status and notification preferences'
  reject_text "$prompt" 'Pause this schedule when active=0. Stay silent.'
  reject_text "$prompt" 'consumer-lifecycle.md'
  reject_text "$prompt" 'hook_activity'
  reject_text "$rendered" 'every 1 minute'
  reject_text "$rendered" 'no automatic heartbeat'
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
check_schedule "$native_context" "$plugin"
require_text "$native_context" 'PR #77'
for failed_response in \
  '{"output":"permission check failed","exit_code":1}' \
  '{"output":"still running","exit_code":null}' \
  '{"output":"fatal: rejected push","exit_code":0}'; do
  failed_context="$(context codex "$plugin" cmd "$failed_response")" || true
  [[ -z "$failed_context" ]] || { printf 'FAIL: failed native command armed a watcher\n' >&2; exit 1; }
done

codex_context="$(context codex "$plugin")"
check_schedule "$codex_context" "$plugin"
[[ "$codex_context" != *'Monitor({'* ]]
claude_context="$(context claude "$plugin")"
require_text "$claude_context" 'Monitor({'
[[ "$claude_context" != *'heartbeat'* && "$claude_context" != *'pr-watch-schedule.md'* ]]
unknown_context="$(context unknown "$plugin")"
check_schedule "$unknown_context" "$plugin"
require_text "$unknown_context" 'Monitor({'

# The compact rendering must retain schedule setup.
long_parent="$scratch/quoted \"path\" $(printf '%0150d' 0 | tr 0 p)"
mkdir -p "$long_parent"
ln -s "$plugin" "$long_parent/plugin"
compact_context="$(context codex "$long_parent/plugin")"
check_schedule "$compact_context" "$long_parent/plugin"
[[ "$compact_context" != *'using the route below'* ]]
compact_unknown="$(context unknown "$long_parent/plugin")"
check_schedule "$compact_unknown" "$long_parent/plugin"
require_text "$compact_unknown" 'Claude: use Monitor'

# Contract guards catch omissions; they do not prove model compliance.
lifecycle="$(cat "$plugin/.agents/watch/consumer-lifecycle.md")"
policy="$(cat "$plugin/.agents/watch/escalation-policy.md")"
require_text "$lifecycle" 'One active consumer per generation'
require_text "$lifecycle" 'pr-watch-session.sh'
require_text "$lifecycle" 'consecutive failures'
require_text "$lifecycle" 'after reporting'
require_text "$lifecycle" 'watch_end is not PR closure'
require_text "$lifecycle" 'one 10-minute heartbeat per chat'
require_text "$lifecycle" 'keep watchers alive'
reject_text "$lifecycle" 'hook_activity'
require_text "$lifecycle" 'confirmed PR watcher'
require_text "$lifecycle" 'unrelated automations'
require_text "$lifecycle" 'cancelled checks'
require_text "$lifecycle" 'bots/threads'
require_text "$lifecycle" 'PR links'
require_text "$lifecycle" 'Preserve an explicit user mute'
require_text "$lifecycle" 'otherwise stay silent'
require_text "$lifecycle" 'Visible reports need TL;DR'
reject_text "$lifecycle" 'Create/reuse one **active, one-minute** heartbeat'
require_text "$lifecycle" 'inspect both revisions'
require_text "$lifecycle" 'Without scheduling support'
require_text "$lifecycle" 'foreground delivery'
require_text "$lifecycle" 'notification-only'
require_text "$policy" 'runner OOM'
require_text "$policy" 'never-started jobs'
require_text "$policy" 'depends on product intent'
require_text "$policy" 'what changed and why'
require_text "$policy" 'pre-existing findings in the PR'
require_text "$unknown_context" 'inspect both revisions'
[[ "$fail" == 0 ]] || { printf '%d failures\n' "$fail" >&2; exit 1; }
printf 'PASS: normal, compact, and unknown routes request schedule setup; Claude retains Monitor\n'
