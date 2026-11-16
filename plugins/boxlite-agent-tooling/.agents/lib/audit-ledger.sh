# shellcheck shell=bash
# Unresolved-findings ledger (design #563): findings a stuck commit/push loop proceeded
# past, and the labels a human dismissed. Requires sourced verdict-audit-state.sh and jq;
# source only. Writers hold no lock here, so two sessions writing at once can lose a
# line; each attempt is written at most once.

audit_ledger_max_entries=200

audit_ledger_path() {  # repository root -> ledger path
  printf '%s/.agents/state/audit-ledger.jsonl' "$1"
}

# Prints the ledger's JSON lines. The json read mode keeps every line; record mode
# accepts a single line only.
audit_ledger_read() {  # ledger path
  local snapshot
  snapshot="$(verdict_audit_read_regular_state "$1" 4194304 json)" || return 1
  # The first line is the mtime; an empty ledger has nothing after it.
  [[ "$snapshot" != *$'\n'* ]] || printf '%s' "${snapshot#*$'\n'}"
}

# Appends one entry for the latest attempt of a validated history; an entry for the
# same attempt is written once.
audit_ledger_record() {  # repository root, history JSON, branch, head
  local path existing="" entry
  path="$(audit_ledger_path "$1")"
  if [[ -e "$path" || -L "$path" ]]; then
    existing="$(audit_ledger_read "$path")" || return 2
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
  _audit_ledger_append "$path" "$existing" "$entry"
}

_audit_ledger_append() {  # ledger path, existing lines, new entry
  { [[ -z "$2" ]] || printf '%s\n' "$2"; printf '%s\n' "$3"; } \
    | tail -n "$audit_ledger_max_entries" | verdict_audit_write_atomic "$1"
}

# Prints the branch's open labels, gate@head7:ID, one per line: recorded finding labels
# minus the labels a human dismissed. Fails when the ledger cannot be read.
audit_ledger_open_labels() {  # repository root, branch
  local path ledger
  path="$(audit_ledger_path "$1")"
  [[ -e "$path" || -L "$path" ]] || return 0
  ledger="$(audit_ledger_read "$path")" || return 1
  jq -rs --arg branch "$2" '
    map(select(.branch == $branch)) as $entries
    | [$entries[] | select(.kind == "dismissal") | .label] as $dismissed
    | [$entries[] | select(has("findings")) | . as $entry | .findings[]
       | "\($entry.gate)@\($entry.head[0:7]):\(.id)"] | unique - $dismissed | .[]' \
    <<<"$ledger" 2>/dev/null
}

# Prints, one JSON line each, the branch's finding entries with no `filed` record, keeping
# only their open findings; entries left with none are omitted.
audit_ledger_unfiled_entries() {  # repository root, branch
  local path ledger
  path="$(audit_ledger_path "$1")"
  [[ -e "$path" || -L "$path" ]] || return 0
  ledger="$(audit_ledger_read "$path")" || return 1
  jq -cs --arg branch "$2" '
    map(select(.branch == $branch)) as $entries
    | [$entries[] | select(.kind == "dismissal") | .label] as $dismissed
    | [$entries[] | select(.kind == "filed") | [.gate, .attempt_id]] as $filed
    | $entries[] | select(has("findings") and ([.gate, .attempt_id] | IN($filed[]) | not))
    | . as $entry
    | .findings |= map(select("\($entry.gate)@\($entry.head[0:7]):\(.id)" | IN($dismissed[]) | not))
    | select(.findings | length > 0)' <<<"$ledger" 2>/dev/null
}

audit_ledger_mark_filed() {  # repository root, branch, gate, attempt id, issue URL
  local path existing="" entry
  path="$(audit_ledger_path "$1")"
  existing="$(audit_ledger_read "$path")" || return 2
  entry="$(jq -nc --argjson now "$(date +%s)" --arg branch "$2" --arg gate "$3" --arg attempt "$4" \
    --arg url "$5" '{recorded_at:$now, kind:"filed", branch:$branch, gate:$gate, attempt_id:$attempt, url:$url}')" \
    || return 2
  _audit_ledger_append "$path" "$existing" "$entry"
}

# Records a human dismissal of one open label. Prints why on failure: status 1 for an
# invalid request, 2 when the ledger cannot be read or written.
audit_ledger_dismiss() {  # repository root, branch, label, reason
  local path labels existing="" entry
  if [[ -z "${4//[[:space:]]/}" || ${#4} -gt 280 ]]; then
    printf 'a nonempty reason of at most 280 characters is required'; return 1
  fi
  labels="$(audit_ledger_open_labels "$1" "$2")" || { printf 'the ledger cannot be read'; return 2; }
  if ! grep -qxF -- "$3" <<<"$labels"; then
    printf '%s is not an open finding on branch %s' "$3" "$2"; return 1
  fi
  path="$(audit_ledger_path "$1")"
  existing="$(audit_ledger_read "$path")" || { printf 'the ledger cannot be read'; return 2; }
  entry="$(jq -nc --argjson now "$(date +%s)" --arg branch "$2" --arg label "$3" --arg reason "$4" \
    '{recorded_at:$now, kind:"dismissal", branch:$branch, label:$label, reason:$reason}')" || return 2
  _audit_ledger_append "$path" "$existing" "$entry" || { printf 'the ledger cannot be written'; return 2; }
}
