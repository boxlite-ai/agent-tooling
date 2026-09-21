#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_AGENT_TOOLING_STATE:?}"
printf 'sync=%s\n' "${AGENT_TOOLING_SYNC_ACTIVE:-0}" >> "$state/installer-calls"
[[ "${FAKE_AGENT_TOOLING_FAIL:-0}" != 1 ]] || {
  printf 'fixture installer failure\n' >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
common_git_dir="$(git -C "$repo_root" rev-parse --git-common-dir)"
[[ "$common_git_dir" == /* ]] || common_git_dir="$repo_root/$common_git_dir"
record_file="$common_git_dir/agent-tooling/current"
recorded_sha="$(head -n1 "$record_file" 2>/dev/null || true)"
if [[ "$recorded_sha" =~ ^[0-9a-f]{40}$ ]]; then
  recorded_manifest="$common_git_dir/agent-tooling/$recorded_sha/plugins/boxlite-agent-tooling/.codex-plugin/plugin.json"
  recorded_version="$(jq -r '.version // empty' "$recorded_manifest" 2>/dev/null || true)"
else
  recorded_sha=""
  recorded_version=""
fi
tooling_sha="${FAKE_AGENT_TOOLING_SHA:-${recorded_sha:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}"
tooling_version="${FAKE_AGENT_TOOLING_VERSION:-${recorded_version:-0.1.5}}"
plugin_dir="$common_git_dir/agent-tooling/$tooling_sha/plugins/boxlite-agent-tooling"
verify_dir="$plugin_dir/scripts"
mkdir -p "$verify_dir"
cp "${FAKE_AGENT_TOOLING_VERIFY:?}" "$verify_dir/verify-installation.sh"
chmod +x "$verify_dir/verify-installation.sh"
jq -nc --arg version "$tooling_version" \
  '{name:"boxlite-agent-tooling",version:$version}' \
  > "$plugin_dir/.claude-plugin.json.tmp"
mkdir -p "$plugin_dir/.claude-plugin" "$plugin_dir/.codex-plugin"
mv "$plugin_dir/.claude-plugin.json.tmp" "$plugin_dir/.claude-plugin/plugin.json"
jq -nc --arg version "$tooling_version" \
  '{name:"boxlite-agent-tooling",version:$version}' \
  > "$plugin_dir/.codex-plugin/plugin.json"
printf '%s\n' "$tooling_sha" > "$record_file"
if [[ "${FAKE_AGENT_TOOLING_INVALID_INSTALL:-0}" == 1 ]]; then
  touch "$state/invalid-install"
  printf 'fixture network unavailable; keeping cached revision\n' >&2
fi
printf 'fixture installer progress that a SessionStart hook must suppress\n'
