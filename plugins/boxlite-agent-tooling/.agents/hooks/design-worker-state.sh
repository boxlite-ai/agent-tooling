#!/usr/bin/env bash
# Explicit clone-wide transaction entry for design binding and research logs.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for library in verdict-audit-state reply-summary concise-writing design-doc; do
  # shellcheck source=/dev/null
  source "$plugin_root/.agents/lib/$library.sh" || exit 2
done
design_doc_binding() { _design_doc_binding "$@"; }
case "${1:-}" in
  binding) shift; _design_doc_binding "$@" ;;
  log) _design_doc_log_store "$2" ;;
  *) exit 2 ;;
esac
