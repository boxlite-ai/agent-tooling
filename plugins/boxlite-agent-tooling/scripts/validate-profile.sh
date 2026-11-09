#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: validate-profile.sh <repository-root>\n' >&2
  exit 2
}

repo_root="${1:-}"
[[ -n "$repo_root" ]] || usage
[[ -d "$repo_root" ]] || { printf 'agent-tooling: repository root does not exist: %s\n' "$repo_root" >&2; exit 1; }

profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing profile manifest: %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'agent-tooling: git is required\n' >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { printf 'agent-tooling: perl is required\n' >&2; exit 1; }

profile="$(jq -er '.profile | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: profile must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}
declared_repo="$(jq -er '.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: repository must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../.agents/lib/tooling-profile.sh
source "$plugin_root/.agents/lib/tooling-profile.sh"
tooling_profile_read "$profile_file" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }
# A hold that cannot be obeyed must fail validation, never let it quietly keep floating.
tooling_hold_read "$repo_root/.agent-tooling/hold" || { printf 'agent-tooling: %s\n' "$tooling_profile_error" >&2; exit 1; }
# The repository a consumer declares is checked against the remote it actually has,
# not against a list shipped here. Git is the authority on which repository this is,
# and a central roster would have to name private repositories inside a public plugin
# to say anything at all. An absent origin still passes: a local-only clone is a
# legitimate setup, and there is nothing to contradict.
origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"github.com"*"${declared_repo}"*|"") ;;
  *) printf 'agent-tooling: origin does not match declared repository %s: %s\n' "$declared_repo" "$origin" >&2; exit 1 ;;
esac

# Verdict state is session-scoped with opaque suffixes, and new runtime files may be
# added as the gates evolve. Fixed filename checks cannot cover that namespace. Requiring
# the directory itself to be ignored keeps every current and future state file out of
# tree hashes and commits.
git -C "$repo_root" check-ignore -q .agents/state/ || {
  printf 'agent-tooling: runtime state directory must be gitignored: .agents/state/\n' >&2
  exit 1
}

jq -e '
  .schemaVersion == 1 and
  (.checks | type == "array") and
  (.checks | length > 0) and
  all(.checks[]; (.name | type == "string" and length > 0) and (.command | type == "string" and length > 0))
' "$profile_file" >/dev/null || {
  printf 'agent-tooling: checks must be a non-empty array of name/command objects in %s\n' "$profile_file" >&2
  exit 1
}

# Every host floats on the same ref the Git gates float on.
for settings_file in "$repo_root/.claude/settings.json" "$repo_root/.github/copilot/settings.json"; do
  [[ -r "$settings_file" ]] || { printf 'agent-tooling: missing activation settings: %s\n' "$settings_file" >&2; exit 1; }
  tooling_claude_settings_valid "$settings_file" "$tooling_ref" || {
    printf 'agent-tooling: activation settings must use source.source "github" and float on tooling.ref: %s\n' "$settings_file" >&2
    exit 1
  }
done

codex_marketplace="$repo_root/.agents/plugins/marketplace.json"
[[ -r "$codex_marketplace" ]] || { printf 'agent-tooling: missing Codex marketplace: %s\n' "$codex_marketplace" >&2; exit 1; }
tooling_codex_marketplace_valid "$codex_marketplace" "$tooling_ref" || {
  printf 'agent-tooling: Codex marketplace must declare the git-subdir source, tooling.ref, install policy, authentication, and category: %s\n' "$codex_marketplace" >&2
  exit 1
}

printf 'agent-tooling: profile %s is valid for %s\n' "$profile" "$declared_repo"
