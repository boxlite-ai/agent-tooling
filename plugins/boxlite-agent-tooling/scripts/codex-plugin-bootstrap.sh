#!/usr/bin/env bash
# Trusted Codex SessionStart bootstrap for a consumer repository.
#
# The committed consumer installer adopts and validates shared tooling first. Codex
# then registers one canonical Git marketplace for the whole machine and installs the
# plugin once. A canonical source is essential: local clone paths conflict because
# Codex keys configured marketplaces globally by their manifest name.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository\n' >&2; exit 2; }
profile_file="$repo_root/.agent-tooling/profile.json"
installer="$repo_root/.agent-tooling/install.sh"
marketplace_file="$repo_root/.agents/plugins/marketplace.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing %s\n' "$profile_file" >&2; exit 1; }
[[ -r "$installer" ]] || { printf 'agent-tooling: missing %s\n' "$installer" >&2; exit 1; }
[[ -r "$marketplace_file" ]] || { printf 'agent-tooling: missing %s\n' "$marketplace_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v codex >/dev/null 2>&1 || { printf 'agent-tooling: Codex CLI is required\n' >&2; exit 1; }

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/tooling-profile.sh
source "$plugin_root/.agents/lib/tooling-profile.sh"
# shellcheck source=../.agents/lib/plugin-bootstrap.sh
source "$plugin_root/.agents/lib/plugin-bootstrap.sh"
# shellcheck source=../.agents/lib/tooling-command.sh
source "$plugin_root/.agents/lib/tooling-command.sh"

tooling_profile_read "$profile_file" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }

validate_codex_marketplace_file() {
  jq -e '.name == "boxlite-agent-tooling"' "$1" >/dev/null 2>&1 &&
    tooling_codex_marketplace_valid "$1" "$tooling_ref"
}

validate_codex_marketplace_file "$marketplace_file" || {
  printf 'agent-tooling: invalid Codex marketplace for tooling.ref %s: %s\n' "$tooling_ref" "$marketplace_file" >&2
  exit 1
}

tooling_bootstrap_refresh "$repo_root" "$plugin_root" || exit 1
next_runtime="$(tooling_bootstrap_runtime "$repo_root" codex)" || exit 1
if [[ "$next_runtime" != "${BASH_SOURCE[0]}" ]]; then
  exec bash "$next_runtime" "$@"
fi
host_cli="$(command -v codex)"
host_deadline=$(( $(date +%s) + 120 ))
codex() { tooling_command "$host_deadline" "$host_cli" "$@"; }

if ! tooling_install_is_valid "$repo_root" 2>/dev/null; then
  tooling_run_installer_verified "$repo_root" "$installer" "$host_deadline" || case "$?" in
    1)
      printf 'agent-tooling: automatic tooling installation failed\n' >&2
      exit "$tooling_installer_status"
      ;;
    *)
      printf 'agent-tooling: automatic tooling installation did not produce a valid local installation\n' >&2
      exit 1
      ;;
  esac
fi

read_expected_plugin_version() {
  tooling_expected_plugin_version "$repo_root" codex Codex || {
    printf 'agent-tooling: %s\n' "$tooling_bootstrap_error" >&2
    return 1
  }
}

refresh_adopted_tooling() {
  [[ "${AGENT_TOOLING_REFRESH:-1}" != 0 ]] || {
    printf 'agent-tooling: plugin version differs while AGENT_TOOLING_REFRESH=0; refresh explicitly\n' >&2
    return 1
  }
  tooling_run_installer_verified "$repo_root" "$installer" "$host_deadline" || case "$?" in
    1)
      printf 'agent-tooling: could not refresh adopted tooling before plugin reconciliation\n' >&2
      return "$tooling_installer_status"
      ;;
    *)
      printf 'agent-tooling: tooling refresh did not produce a valid local installation\n' >&2
      return 1
      ;;
  esac
  read_expected_plugin_version
}

read_expected_plugin_version || exit 1

tooling_hold_read "$repo_root/.agent-tooling/hold" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }
[[ -z "$hold_sha" || "$hold_sha" == "$adopted_tooling_revision" ]] || {
  printf 'agent-tooling: hold %s is not the adopted tooling revision %s\n' \
    "$hold_sha" "$adopted_tooling_revision" >&2
  exit 1
}

codex_plugin_catalog() {
  local catalog
  if ! catalog="$(codex plugin list --marketplace boxlite-agent-tooling --available --json)"; then
    printf 'agent-tooling: could not read the boxlite-agent-tooling Codex marketplace\n' >&2
    return 1
  fi
  jq -e '
    def target:
      .pluginId == "boxlite-agent-tooling@boxlite-agent-tooling";
    def valid_metadata:
      .name == "boxlite-agent-tooling" and
      .marketplaceName == "boxlite-agent-tooling" and
      (.enabled | type == "boolean") and
      .installPolicy == "INSTALLED_BY_DEFAULT" and
      .authPolicy == "ON_INSTALL";
    (.installed | type == "array") and
    (.available | type == "array") and
    ([(.installed[], .available[]) | select(target)] | length == 1) and
    all(.installed[];
      (target | not) or
      (valid_metadata and .installed == true and
       (.version | type == "string" and length > 0))) and
    all(.available[];
      (target | not) or
      (valid_metadata and .installed == false and
       has("version") and
       ((.version == null) or (.version | type == "string" and length > 0))))
  ' <<< "$catalog" >/dev/null || {
    printf 'agent-tooling: Codex marketplace boxlite-agent-tooling does not advertise the expected plugin at ref %s\n' "$tooling_ref" >&2
    return 1
  }
  printf '%s' "$catalog"
}

installed_target='def installed_target: .pluginId == "boxlite-agent-tooling@boxlite-agent-tooling" and .installed == true;'

installed_enabled_state() { # prints the single installed plugin's boolean enabled state
  jq -r "$installed_target"' [.installed[] | select(installed_target) | .enabled | booleans]
    | if length == 1 then .[0] else error("no boolean enabled state") end' <<< "$catalog" 2>/dev/null
}

read_catalog_plugin_state() {
  local available_plugin_version
  installed_count="$(jq -r "$installed_target"' [.installed[] | select(installed_target)] | length' <<< "$catalog")"
  if [[ "$installed_count" == 1 ]]; then
    catalog_plugin_version="$(jq -er "$installed_target"' .installed[] | select(installed_target) | .version' <<< "$catalog")" || {
      printf 'agent-tooling: Codex installed plugin has no usable version\n' >&2
      return 1
    }
    return 0
  fi
  [[ "$installed_count" == 0 ]] || {
    printf 'agent-tooling: Codex reported an ambiguous boxlite-agent-tooling installation\n' >&2
    return 1
  }

  available_plugin_version="$(jq -r '.available[] | select(
    .pluginId == "boxlite-agent-tooling@boxlite-agent-tooling" and .installed == false
  ) | .version // ""' <<< "$catalog")"
  if [[ -n "$available_plugin_version" &&
        "$available_plugin_version" != "$configured_plugin_version" ]]; then
    printf 'agent-tooling: Codex available plugin version %s does not match configured marketplace manifest version %s\n' \
      "$available_plugin_version" "$configured_plugin_version" >&2
    return 1
  fi
  catalog_plugin_version="$configured_plugin_version"
}

read_codex_marketplaces() { # verb, message suffix; sets marketplaces and marketplace_count
  marketplaces="$(codex plugin marketplace list --json)" || {
    printf 'agent-tooling: could not %s Codex marketplaces%s\n' "$1" "$2" >&2
    exit 1
  }
  jq -e '.marketplaces | type == "array"' <<< "$marketplaces" >/dev/null || {
    printf 'agent-tooling: Codex returned an invalid marketplace list%s\n' "$2" >&2
    exit 1
  }
  marketplace_count="$(jq -r '[.marketplaces[] | select(.name == "boxlite-agent-tooling")] | length' <<< "$marketplaces")"
}

read_codex_marketplaces list ""
canonical_marketplace_url="https://github.com/$tooling_repo.git"
codex_marketplace_source_is_canonical() {
  local marketplace_list="$1"
  jq -e --arg source "$canonical_marketplace_url" '
    .marketplaces[] |
    select(.name == "boxlite-agent-tooling") |
    .marketplaceSource.sourceType == "git" and
    .marketplaceSource.source == $source
  ' <<< "$marketplace_list" >/dev/null
}

changed=0
case "$marketplace_count" in
  0)
    [[ -z "$hold_sha" ]] || {
      printf 'agent-tooling: hold %s prevents resolving a missing Codex marketplace\n' \
        "$hold_sha" >&2
      exit 1
    }
    if ! codex plugin marketplace add "$canonical_marketplace_url" --ref "$tooling_ref" --json >/dev/null; then
      printf 'agent-tooling: could not add Codex marketplace %s at %s\n' "$tooling_repo" "$tooling_ref" >&2
      exit 1
    fi
    changed=1
    ;;
  1)
    codex_marketplace_source_is_canonical "$marketplaces" || {
      printf 'agent-tooling: configured Codex marketplace source is not canonical Git: %s\n' \
        "$canonical_marketplace_url" >&2
      exit 1
    }
    # The list API omits the configured ref. Re-adding the exact source is Codex's
    # public idempotent check: it returns alreadyAdded for a match and fails otherwise.
    if ! codex plugin marketplace add "$canonical_marketplace_url" --ref "$tooling_ref" --json >/dev/null; then
      printf 'agent-tooling: Codex marketplace is not configured at tooling.ref %s\n' "$tooling_ref" >&2
      exit 1
    fi
    ;;
  *)
    printf 'agent-tooling: Codex has %s marketplaces named boxlite-agent-tooling; remove the conflict and retry\n' "$marketplace_count" >&2
    exit 1
    ;;
esac

# Installed plugins legitimately report their cache directory as a local source.
# Verify the configured marketplace root separately so that source transition cannot
# hide a same-name marketplace pointed at a different Git repository or branch.
read_codex_marketplaces re-read " after configuration"
[[ "$marketplace_count" == 1 ]] || {
  printf 'agent-tooling: Codex marketplace boxlite-agent-tooling is ambiguous after configuration\n' >&2
  exit 1
}
codex_marketplace_source_is_canonical "$marketplaces" || {
  printf 'agent-tooling: configured Codex marketplace source is not canonical Git: %s\n' \
    "$canonical_marketplace_url" >&2
  exit 1
}
marketplace_root="$(jq -er '
  .marketplaces[] |
  select(.name == "boxlite-agent-tooling") |
  .root | select(type == "string" and length > 0)
' <<< "$marketplaces")" || {
  printf 'agent-tooling: configured Codex marketplace has no usable root\n' >&2
  exit 1
}
configured_marketplace_file="$marketplace_root/.agents/plugins/marketplace.json"
validate_codex_marketplace_file "$configured_marketplace_file" || {
  printf 'agent-tooling: configured Codex marketplace is invalid for tooling.ref %s: %s\n' \
    "$tooling_ref" "$configured_marketplace_file" >&2
  exit 1
}
configured_plugin_manifest="$marketplace_root/plugins/boxlite-agent-tooling/.codex-plugin/plugin.json"
read_configured_plugin_version() {
  configured_plugin_version="$(jq -er '
    select(.name == "boxlite-agent-tooling") |
    .version | select(type == "string" and length > 0)
  ' "$configured_plugin_manifest" 2>/dev/null)" || {
    printf 'agent-tooling: configured Codex marketplace has no valid plugin version: %s\n' \
      "$configured_plugin_manifest" >&2
    return 1
  }
}
read_configured_plugin_version || exit 1

catalog="$(codex_plugin_catalog)" || exit 1
read_catalog_plugin_state || exit 1

if [[ "$catalog_plugin_version" != "$expected_plugin_version" ]]; then
  [[ -z "$hold_sha" ]] || {
    printf 'agent-tooling: Codex plugin version %s does not match held tooling version %s; remove hold to reconcile\n' \
      "$catalog_plugin_version" "$expected_plugin_version" >&2
    exit 1
  }
  refresh_adopted_tooling || exit 1
fi

if [[ "$catalog_plugin_version" != "$expected_plugin_version" ]]; then
  installed_enabled_before=""
  if [[ "$installed_count" == 1 ]]; then
    installed_enabled_before="$(installed_enabled_state)" || {
      printf 'agent-tooling: Codex installed plugin has no boolean enabled state\n' >&2
      exit 1
    }
  fi

  if ! upgrade_output="$(codex plugin marketplace upgrade boxlite-agent-tooling --json)"; then
    printf 'agent-tooling: could not upgrade Codex marketplace boxlite-agent-tooling\n' >&2
    exit 1
  fi
  jq -e '
    (.selectedMarketplaces | type == "array") and
    (.selectedMarketplaces | index("boxlite-agent-tooling") != null) and
    (.upgradedRoots | type == "array") and
    (.errors | type == "array" and length == 0)
  ' <<< "$upgrade_output" >/dev/null 2>&1 || {
    printf 'agent-tooling: Codex marketplace upgrade returned an invalid result\n' >&2
    exit 1
  }

  read_configured_plugin_version || exit 1
  [[ "$configured_plugin_version" == "$expected_plugin_version" ]] || {
    printf 'agent-tooling: configured Codex marketplace stayed at %s after upgrade; expected %s\n' \
      "$configured_plugin_version" "$expected_plugin_version" >&2
    exit 1
  }
  catalog="$(codex_plugin_catalog)" || exit 1
  read_catalog_plugin_state || exit 1
  [[ "$catalog_plugin_version" == "$expected_plugin_version" ]] || {
    printf 'agent-tooling: Codex plugin stayed at %s after upgrade; expected %s\n' \
      "$catalog_plugin_version" "$expected_plugin_version" >&2
    exit 1
  }
  if [[ -n "$installed_enabled_before" ]]; then
    [[ "$installed_count" == 1 ]] || {
      printf 'agent-tooling: Codex marketplace upgrade removed the installed plugin\n' >&2
      exit 1
    }
    installed_enabled_after="$(installed_enabled_state)" || {
      printf 'agent-tooling: upgraded Codex plugin has no boolean enabled state\n' >&2
      exit 1
    }
    [[ "$installed_enabled_after" == "$installed_enabled_before" ]] || {
      printf 'agent-tooling: Codex marketplace upgrade changed the plugin enabled state\n' >&2
      exit 1
    }
  fi
  changed=1
fi

if [[ "$installed_count" == 0 ]]; then
  [[ -z "$hold_sha" ]] || {
    printf 'agent-tooling: hold %s prevents installing a missing Codex plugin\n' \
      "$hold_sha" >&2
    exit 1
  }
  if ! codex plugin add boxlite-agent-tooling@boxlite-agent-tooling --json >/dev/null; then
    printf 'agent-tooling: could not install Codex plugin boxlite-agent-tooling@boxlite-agent-tooling\n' >&2
    exit 1
  fi
  changed=1
  catalog="$(codex_plugin_catalog)" || exit 1
  jq -e --arg version "$expected_plugin_version" "$installed_target"' any(.installed[];
    installed_target and .version == $version)' <<< "$catalog" >/dev/null || {
    printf 'agent-tooling: Codex did not install boxlite-agent-tooling at expected version %s\n' \
      "$expected_plugin_version" >&2
    exit 1
  }
elif [[ "$installed_count" != 1 ]]; then
  printf 'agent-tooling: Codex reported an ambiguous boxlite-agent-tooling installation\n' >&2
  exit 1
fi

if [[ "$changed" == 1 ]]; then
  jq -nc --arg message \
    'BoxLite agent tooling was installed or updated. Start a new Codex task to load its skills and tools, then review its plugin hooks with /hooks.' \
    '{systemMessage: $message}'
fi
