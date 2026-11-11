#!/usr/bin/env bash
# Register/read a design, inspect a host-owned run, or store a research log/reflection.
set -uo pipefail
unset design_worker_proof design_worker_deadline
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in jq perl git curl python3; do
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
  run:1)
    if design_doc_binding edit "$PWD" >/dev/null 2>&1; then
      printf 'design-doc: current design authority is complete\n'
      exit 0
    fi
    directory="$(git rev-parse --absolute-git-dir)" || exit 2
    record="$(verdict_audit_read_regular_state "$directory/agent-tooling-design-worker.json" 1048576 record)" || exit 2
    jq -e '.status=="consumed"' <<<"$record" >/dev/null || exit 2
    printf 'design-doc: assigned worker result recorded; retry the edit gate\n'
    ;;
  verdict:1|advice:1)
    printf 'design-doc: result recording requires a gate-owned worker; request the design runner\n' >&2
    exit 2
    ;;
  reflect:1) design_doc_audit_reflect "$PWD" ;;
  log:1) design_doc_log_store "$PWD" ;;
  show:1) design_doc_show "$PWD" ;;
  show:2) design_doc_show "$2" ;;
  *) printf 'usage: design-doc.sh register <URL> | check | run | log < research-log.md | reflect < reflection.json | show [repo-root]\n' >&2; exit 2 ;;
esac
