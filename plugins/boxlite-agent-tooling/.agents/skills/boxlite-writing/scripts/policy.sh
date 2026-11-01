#!/usr/bin/env bash
# Source only. Read the skill-owned data at call time; never execute configuration.
# Requires jq. No environment overrides or defaults can mask a damaged installation.
boxlite_writing_rules() { # [limits] -> validated JSON, or four enforced limits
  local path result
  path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/rules.json" || return 2
  if [[ ! -f "$path" || -L "$path" ]] || ! result="$(jq -cers --arg mode "${1-}" '
    def keys_are($wanted): type == "object" and (keys == ($wanted | sort));
    def limits: all(.[]; type == "number" and . == floor and . > 0 and . <= 100000);
    select(length == 1) | .[0] |
    select(keys_are(["version", "enforced", "guidance"]) and .version == 1) |
    select(.enforced | keys_are(["summary_max_words", "short_reply_max_words",
      "paragraph_max_words", "item_max_words"]) and limits) |
    select(.guidance | keys_are(["sentence_max_words", "prose_max_sentences",
      "reasoning_max_sentences", "list_min_items", "list_max_items",
      "list_item_max_sentences", "table_min_columns", "table_max_columns"]) and limits) |
    select(.guidance.list_min_items <= .guidance.list_max_items and
      .guidance.table_min_columns <= .guidance.table_max_columns and
      .guidance.prose_max_sentences <= .guidance.reasoning_max_sentences) |
    if $mode == "limits" then .enforced |
      [.summary_max_words, .short_reply_max_words, .paragraph_max_words, .item_max_words] | @tsv
    elif $mode == "" then . else empty end
  ' "$path" 2>/dev/null)"; then
    printf 'boxlite-writing: missing or invalid rules.json\n' >&2
    return 2
  fi
  # Native jq on Windows may append CRLF; all policy values are validated numbers.
  result="${result//$'\r'/}"
  printf '%s\n' "$result"
}
