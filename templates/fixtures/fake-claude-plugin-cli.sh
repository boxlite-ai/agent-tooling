#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_CLAUDE_STATE:?}"
printf '%s\n' "$*" >> "$state/commands"

if [[ "$*" == "plugin marketplace list --json" ]]; then
  [[ "${FAKE_CLAUDE_INVALID_MARKETPLACE_LIST:-0}" != 1 ]] || {
    printf '{"unexpected":true}\n'
    exit 0
  }
  if [[ -e "$state/marketplace" ]]; then
    marketplace_json="$(jq -nc \
      --arg source "${FAKE_CLAUDE_MARKETPLACE_SOURCE:-github}" \
      --arg repo "${FAKE_CLAUDE_MARKETPLACE_REPO:-boxlite-ai/agent-tooling}" \
      --arg ref "${FAKE_CLAUDE_MARKETPLACE_REF:-main}" \
      '[{
        name: "boxlite-agent-tooling",
        source: $source,
        repo: $repo,
        ref: $ref,
        installLocation: "/plugin-marketplaces/boxlite-agent-tooling"
      }]')"
    if [[ "${FAKE_CLAUDE_DUPLICATE_MARKETPLACE:-0}" == 1 ]]; then
      jq '. + [{name:"boxlite-agent-tooling",source:"directory",repo:null,ref:null}]' \
        <<< "$marketplace_json"
    else
      printf '%s\n' "$marketplace_json"
    fi
  else
    printf '[]\n'
  fi
elif [[ "$1 $2 $3" == "plugin marketplace add" ]]; then
  [[ "$4" == "boxlite-ai/agent-tooling@main" ]]
  [[ "$5" == "--scope" && "$6" == "project" ]]
  [[ "${FAKE_CLAUDE_FAIL_MARKETPLACE_ADD:-0}" != 1 ]] || {
    printf 'fixture marketplace failure\n' >&2
    exit 1
  }
  touch "$state/marketplace"
  printf '%s\n' "${FAKE_CLAUDE_MARKETPLACE_VERSION:-0.1.5}" > "$state/marketplace-version"
  printf 'marketplace added\n' >> "$state/marketplace-mutations"
  printf 'Successfully added marketplace\n'
elif [[ "$*" == "plugin marketplace update boxlite-agent-tooling" ]]; then
  printf '%s\n' "${CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE:-0}" \
    >> "$state/marketplace-update-keep"
  [[ "${CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE:-0}" == 1 ]] || {
    printf 'fixture requires keep-on-failure protection\n' >&2
    exit 65
  }
  [[ "${FAKE_CLAUDE_FAIL_MARKETPLACE_UPDATE:-0}" != 1 ]] || {
    printf 'fixture marketplace update failure\n' >&2
    exit 1
  }
  printf '%s\n' "${FAKE_CLAUDE_MARKETPLACE_VERSION:-0.1.5}" > "$state/marketplace-version"
  printf 'Successfully updated marketplace\n'
elif [[ "$*" == "plugin list --json" ]]; then
  [[ "${FAKE_CLAUDE_INVALID_PLUGIN_LIST:-0}" != 1 ]] || {
    printf '{"unexpected":true}\n'
    exit 0
  }
  if [[ -e "$state/plugin-installed" ]]; then
    enabled=false
    [[ ! -e "$state/plugin-enabled" ]] || enabled=true
    version="$(head -n1 "$state/plugin-version" 2>/dev/null || printf '0.1.5')"
    project_path="${FAKE_CLAUDE_REPORTED_PROJECT_PATH:-${FAKE_CLAUDE_PROJECT_PATH:?}}"
    [[ ! -e "$state/plugin-installed-here" ]] || project_path="${FAKE_CLAUDE_PROJECT_PATH:?}"
    jq -nc \
      --argjson enabled "$enabled" \
      --arg project_path "$project_path" \
      --arg version "$version" '[{
      id: "boxlite-agent-tooling@boxlite-agent-tooling",
      version: $version,
      scope: "project",
      enabled: $enabled,
      installPath: ("/plugin-cache/boxlite-agent-tooling/" + $version),
      projectPath: $project_path
    }]'
  else
    printf '[]\n'
  fi
elif [[ "$1 $2" == "plugin install" ]]; then
  [[ "$3" == "boxlite-agent-tooling@boxlite-agent-tooling" ]]
  [[ "$4" == "--scope" && "$5" == "project" && "$6" == "--yes" ]]
  [[ "${FAKE_CLAUDE_FAIL_PLUGIN_INSTALL:-0}" != 1 ]] || {
    printf 'fixture plugin failure\n' >&2
    exit 1
  }
  # Like Claude Code, installing over this checkout's own record changes nothing.
  if [[ -e "$state/plugin-installed" && -e "$state/plugin-installed-here" ]]; then
    printf 'Plugin is already installed\n'
    exit 0
  fi
  if [[ "${FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_INSTALL:-0}" != 1 ]]; then
    touch "$state/plugin-installed" "$state/plugin-enabled" "$state/plugin-installed-here"
    head -n1 "$state/marketplace-version" > "$state/plugin-version"
    settings="${FAKE_CLAUDE_PROJECT_PATH:?}/.claude/settings.json"
    if ! jq -e '.enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"]' "$settings" >/dev/null; then
      jq -c '.enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] = true' "$settings" \
        > "$settings.fake" && mv "$settings.fake" "$settings"
    fi
  fi
  printf 'Successfully installed plugin\n'
elif [[ "$1 $2" == "plugin uninstall" ]]; then
  [[ "$3" == "boxlite-agent-tooling@boxlite-agent-tooling" ]]
  [[ "$4" == "--scope" && "$5" == "project" && "$6" == "--keep-data" ]]
  [[ -e "$state/plugin-installed" && -e "$state/plugin-installed-here" ]]
  rm -f "$state/plugin-installed" "$state/plugin-installed-here"
  # Claude Code also drops the plugin from the tracked project settings.
  settings="${FAKE_CLAUDE_PROJECT_PATH:?}/.claude/settings.json"
  jq -c 'del(.enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"])' "$settings" \
    > "$settings.fake" && mv "$settings.fake" "$settings"
  printf 'Successfully uninstalled plugin\n'
elif [[ "$1 $2" == "plugin update" ]]; then
  [[ "$3" == "boxlite-agent-tooling@boxlite-agent-tooling" ]]
  [[ "$4" == "--scope" && "$5" == "project" && "$6" == "--yes" ]]
  [[ "${FAKE_CLAUDE_FAIL_PLUGIN_UPDATE:-0}" != 1 ]] || {
    printf 'fixture plugin update failure\n' >&2
    exit 1
  }
  if [[ "${FAKE_CLAUDE_FALSE_SUCCESS_PLUGIN_UPDATE:-0}" != 1 ]]; then
    head -n1 "$state/marketplace-version" > "$state/plugin-version"
  fi
  printf 'Successfully updated plugin\n'
else
  printf 'unexpected claude command: %s\n' "$*" >&2
  exit 64
fi
