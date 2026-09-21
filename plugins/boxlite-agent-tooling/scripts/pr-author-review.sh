#!/usr/bin/env bash
# Publish the CLA-style author review acknowledgment for a PR's current head.
# Usage: pr-author-review.sh <github-event.json>
# Exit 0: acknowledged or irrelevant; 1: awaiting acknowledgment; 2: unknown/API error.
# The caller serializes runs per PR and bounds runtime (the workflow allows 5 minutes).
set -uo pipefail

for dependency in jq "${GH_BIN:-gh}"; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'pr-author-review: %s is required\n' "$dependency" >&2
    exit 2
  }
done
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
for library in subagent pr-author-review; do
  [[ -r "$plugin_root/.agents/lib/$library.sh" ]] || {
    printf 'pr-author-review: missing library: %s/.agents/lib/%s.sh\n' "$plugin_root" "$library" >&2
    exit 2
  }
done
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../.agents/lib/subagent.sh
source "$plugin_root/.agents/lib/subagent.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../.agents/lib/pr-author-review.sh
source "$plugin_root/.agents/lib/pr-author-review.sh"
pr_author_review_run "${1:-}" "$plugin_root"
