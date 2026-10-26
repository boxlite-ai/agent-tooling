#!/usr/bin/env bash
# Register, verify, or print the design doc for the current worktree and branch, or
# record the research auditor's verdict (stdin) for its live content.
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
# Keep bind for existing callers; register avoids Claude Code's worktree false positive.
case "${1:-}:$#" in
  register:2|bind:2) design_doc_binding bind "$PWD" "$2" ;;
  check:1) design_doc_binding check "$PWD" ;;
  research:1) design_doc_research_record "$PWD" ;;
  show:1) design_doc_show "$PWD" ;;
  *) printf 'usage: design-doc.sh register <URL> | check | research < verdict.json | show\n' >&2; exit 2 ;;
esac
