#!/usr/bin/env bash
# Register or verify the design doc for the current worktree and branch.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in jq perl git curl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'design-doc: required command missing: %s\n' "$dependency" >&2; exit 2;
  }
done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin_root/.agents/lib/verdict-audit-state.sh" || exit 2
# shellcheck source=../.agents/lib/reply-summary.sh
source "$plugin_root/.agents/lib/reply-summary.sh" || exit 2
# shellcheck source=../.agents/lib/concise-writing.sh
source "$plugin_root/.agents/lib/concise-writing.sh" || exit 2
# shellcheck source=../.agents/lib/design-doc.sh
source "$plugin_root/.agents/lib/design-doc.sh" || exit 2
case "${1:-}:$#" in
  bind:2) design_doc_binding bind "$PWD" "$2" ;;
  check:1) design_doc_binding check "$PWD" ;;
  *) printf 'usage: design-doc.sh bind <URL> | check\n' >&2; exit 2 ;;
esac
