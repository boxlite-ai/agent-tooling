#!/usr/bin/env bash
# Source-only consumer profile and hold policy; requires jq and Git.
# Readers set their result variables, or set tooling_profile_error and return 1
# so each caller reports through its own failure channel.
# shellcheck disable=SC2034 # Readers return results in caller-visible globals.

tooling_profile_read() {  # profile file; sets tooling_repo and tooling_ref
  local file="$1"
  tooling_profile_error=""
  tooling_repo="$(jq -er '.tooling.repository | select(type == "string" and length > 0)' "$file" 2>/dev/null)" || {
    tooling_profile_error="tooling.repository must be a non-empty string in $file"
    return 1
  }
  [[ "$tooling_repo" == "boxlite-ai/agent-tooling" ]] || {
    tooling_profile_error="unsupported tooling repository: $tooling_repo"
    return 1
  }
  tooling_ref="$(jq -er '.tooling.ref | select(type == "string" and length > 0)' "$file" 2>/dev/null)" || {
    tooling_profile_error="tooling.ref must name the branch to float on in $file"
    return 1
  }
  [[ ! "$tooling_ref" =~ ^[0-9a-f]{40}$ ]] || {
    tooling_profile_error="tooling.ref names a branch; to freeze a revision write it to .agent-tooling/hold"
    return 1
  }
  # check-ref-format accepts a leading dash; refuse it so the ref never reads as an option.
  if [[ "$tooling_ref" == -* ]] || ! git check-ref-format "refs/heads/$tooling_ref" >/dev/null 2>&1; then
    tooling_profile_error="tooling.ref is not a valid branch name: $tooling_ref"
    return 1
  fi
}

tooling_hold_read() {  # hold file; sets hold_sha, empty when no hold exists
  local file="$1"
  tooling_profile_error=""
  hold_sha=""
  [[ -e "$file" ]] || return 0
  hold_sha="$(tr -d '\n' < "$file")"
  { [[ "$hold_sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$(wc -c < "$file")" -le 41 ]]; } || {
    tooling_profile_error="$file must contain exactly one full lowercase commit SHA"
    return 1
  }
}

tooling_claude_settings_valid() {  # settings file, tooling ref
  jq -e --arg ref "$2" '
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.source == "github" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.repo == "boxlite-ai/agent-tooling" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.ref == $ref and
    .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
  ' "$1" >/dev/null 2>&1
}

tooling_codex_marketplace_valid() {  # marketplace file, tooling ref
  [[ -r "$1" ]] || return 1
  jq -e --arg ref "$2" '
    any(.plugins[];
      .name == "boxlite-agent-tooling" and
      .source.source == "git-subdir" and
      .source.url == "https://github.com/boxlite-ai/agent-tooling.git" and
      .source.ref == $ref and
      .source.path == "./plugins/boxlite-agent-tooling" and
      .policy.installation == "INSTALLED_BY_DEFAULT" and
      .policy.authentication == "ON_INSTALL" and
      .category == "Developer Tools")
  ' "$1" >/dev/null 2>&1
}
