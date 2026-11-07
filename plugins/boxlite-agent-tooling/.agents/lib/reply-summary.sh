#!/usr/bin/env bash
# Shared reply measurements: the Markdown word counter behind the TL;DR limit, the
# structure limits of boxlite-writing, and the bounded reader that recovers the Stop
# gate's last reply from the transcript. Source this file; it performs no work on
# load. Requires sourced verdict-audit-state.sh, reply-summary.pl beside this file,
# and perl 5.22+ and jq on PATH; callers own those checks and all reporting.

# The structure limits of boxlite-writing's Limits section; reply-summary.test.sh
# fails when that text and these values drift apart.
reply_summary_max_sentences=3
reply_summary_max_sentence_words=25
reply_summary_min_list_items=2
reply_summary_max_list_items=7
reply_summary_min_table_columns=2
reply_summary_max_table_columns=5
reply_summary_short_max_words=80
# The same snapshot bound the verdict check puts on the transcript it reads.
reply_summary_snapshot_max_bytes=262144

_reply_summary_measure() {  # mode [limits...]; text on stdin
  perl "$(dirname "${BASH_SOURCE[0]}")/reply-summary.pl" "$@"
}

# Words in the whole text, as reply-summary.pl counts them.
reply_summary_word_count() {  # text -> total
  local total
  total="$(printf '%s\n' "${1-}" | _reply_summary_measure total 2>/dev/null)" || return 1
  [[ "$total" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$total"
}

# One line per broken structure limit: rule, count, limit, excerpt, tab-separated.
# Empty output means every limit holds; status 1 means the text could not be measured.
reply_summary_structure() {  # text -> report
  local report
  report="$(printf '%s\n' "${1-}" | _reply_summary_measure structure \
    "$reply_summary_max_sentences" "$reply_summary_max_sentence_words" \
    "$reply_summary_min_list_items" "$reply_summary_max_list_items" \
    "$reply_summary_min_table_columns" "$reply_summary_max_table_columns" 2>/dev/null)" || return 1
  printf '%s' "$report"
}

# 0 when short, 1 when longer, 2 when the text could not be counted.
reply_summary_is_short() {  # text
  local text="${1-}" total
  # Text over 8000 characters is never short; longer text needs a TL;DR.
  (( ${#text} <= 8000 )) || return 1
  total="$(reply_summary_word_count "$text")" || return 2
  (( total <= reply_summary_short_max_words ))
}

# The transcript's final turn, read by the verdict check's own bounded snapshot
# reader. The snapshot goes to a fresh path in the caller's scratch directory.
_reply_summary_snapshot() {  # transcript-path scratch-dir -> bounded JSON
  local snapshot="$2/final-turn.json" identity state
  [[ -n "${1-}" && -f "$1" && ! -L "$1" && -d "${2-}" ]] || return 1
  # shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh, which callers source.
  identity="$(verdict_audit_snapshot_final_turn_identity "$1" "$snapshot" \
    "$verdict_audit_final_turn_max_bytes" "$reply_summary_snapshot_max_bytes" \
    2>/dev/null)" || return 1
  state="$(verdict_audit_read_regular_state "$snapshot" \
    "$reply_summary_snapshot_max_bytes" json "$identity" 2>/dev/null)" || return 1
  verdict_audit_unlink_if_identity "$snapshot" "$identity" 2>/dev/null || true
  [[ "$state" == *$'\n'* ]] || return 1
  printf '%s' "${state#*$'\n'}"
}

reply_summary_last_text() { # transcript-path scratch-dir -> last assistant text
  _reply_summary_snapshot "$1" "$2" | jq -er 'select(.truncated == false) |
    [.records[] | select(.kind == "assistant") | .texts | join("\n")] | last // ""'
}
