#!/usr/bin/env bash
# Register, verify, or print the design doc for the current worktree and branch, record
# the design auditor's verdict or the design advisor's advice (stdin) for its live content,
# or store the reflection a later audit waits for.
set -uo pipefail
unset design_worker_proof design_worker_deadline
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
  register:2) design_doc_binding bind "$PWD" "$2" ;;
  check:1) design_doc_binding check "$PWD" ;;
  verdict:1) design_doc_audit_record "$PWD" ;;
  reflect:1) design_doc_audit_reflect "$PWD" ;;
  advice:1) design_doc_advice_record "$PWD" ;;
  log:1) design_doc_log_store "$PWD" ;;
  show:1) design_doc_show "$PWD" ;;
  show:2) design_doc_show "$2" ;;
  *) printf 'usage: design-doc.sh register <URL> | check | log < research-log.md | verdict < verdict.json | advice < advice.json | reflect < reflection.json | show [repo-root]\n' >&2; exit 2 ;;
esac
