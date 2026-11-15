# shellcheck shell=bash
# Unresolved-findings ledger (design #563): findings a stuck commit/push loop proceeded
# past. Requires sourced verdict-audit-state.sh and jq; source only. The caller reads
# history separately and holds no lock here, so two sessions writing at once can lose a
# line; each attempt is written at most once.

audit_ledger_max_entries=200

audit_ledger_path() {  # repository root -> ledger path
  printf '%s/.agents/state/audit-ledger.jsonl' "$1"
}

# Appends one entry for the latest attempt of a validated history; an entry for the
# same attempt is written once.
audit_ledger_record() {  # repository root, history JSON, branch, head
  local path existing="" entry
  path="$(audit_ledger_path "$1")"
  if [[ -e "$path" || -L "$path" ]]; then
    existing="$(verdict_audit_read_regular_state "$path" 4194304 record)" || return 2
  fi
  entry="$(jq -c -L "$(dirname "${BASH_SOURCE[0]}")" --arg branch "$3" --arg head "$4" \
    --argjson now "$(date +%s)" '
    include "audit-loop";
    {recorded_at:$now, gate:.context.gate, branch:$branch, head:$head,
     attempt_id:.attempts[-1].id,
     class:(audit_loop_history_rounds | audit_loop_class),
     findings:[.registry[] | select(.status | IN("open","not_assessed"))
       | {id, severity:(.severity // "critical"), invariant, behavior, criterion, evidence}]}' <<<"$2")" \
    || return 2
  if [[ -n "$existing" ]] && jq -e -s --argjson entry "$entry" \
      'any(.[]; .attempt_id == $entry.attempt_id and .gate == $entry.gate)' <<<"$existing" >/dev/null; then
    return 0
  fi
  { [[ -z "$existing" ]] || printf '%s\n' "$existing"; printf '%s\n' "$entry"; } \
    | tail -n "$audit_ledger_max_entries" | verdict_audit_write_atomic "$path"
}
