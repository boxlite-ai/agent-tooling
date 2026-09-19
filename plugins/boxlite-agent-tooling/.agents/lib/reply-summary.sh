#!/usr/bin/env bash
# The closing reply that stop-gate.sh asks for after a long one. Source this file; it
# performs no work on load. Requires verdict-audit-state.sh to be sourced first, and
# perl and jq on PATH; callers own those checks and all reporting.
#
# A turn that ends on a long reply gets one more message showing the result in few
# words: drawings of any kind, as many as it takes, or at most three bullet points
# where a drawing cannot express it. The long reply stays as written and the result
# follows it, so the last thing on screen is quick to read. A drawing that needs a tool
# to render or send is new tool work, so the verdict check judges that answer as usual.
# The Stop gate asks only after the verdict check has judged and allowed the turn, or a
# user's override let it end, and never twice in a row, so a model that cannot shorten
# its answer ends the turn on the next Stop instead of looping.
#
# ONE session-scoped record remembers the ask until the next Stop takes it. Its body is
# `<prompt-epoch> <mode> <tool-count>`:
#   mode        context: Claude Code continued the same turn (additionalContext), so
#                 the transcript's final turn still holds the judged turn before it
#               block: the request went back as a user message (decision:block), so
#                 the transcript's final turn starts at it
#   tool-count  tool calls in the judged turn, or - when they could not be counted
# Tool calls since the ask are what separate a restatement of an already-judged turn
# from new work, which the verdict check must judge.

# A reply over this many words of prose gets the ask. A fenced block, a drawing or code,
# is not prose, so it does not count here.
reply_summary_max_words=60
# The answer to the ask ends unjudged only up to this many words, counted everywhere,
# fenced blocks included. Words, not size: drawings may be many and large as long as
# their labels are few, while a pasted log or code dump is words and counts. Models
# overshoot a word target, so twice the ask threshold leaves room.
reply_summary_restatement_max_words=$(( 2 * reply_summary_max_words ))
# The same bounds the verdict check puts on the transcript it reads.
reply_summary_transcript_max_bytes=67108864
reply_summary_snapshot_max_bytes=262144

# A word is a whitespace-separated token holding a letter or digit, so table pipes,
# list markers and box-drawing lines do not count. Chinese and Japanese, written
# without spaces, count one word per character, the usual convention for them; Korean
# spaces its words and counts like English. The second argument skips fenced blocks
# (1) or counts them (0).
_reply_summary_words() {  # text skip-fenced(1|0)
  local words
  words="$(printf '%s\n' "${1-}" | perl -CSD -ne '
    BEGIN { $skip_fenced = shift @ARGV }
    if ($skip_fenced && /^\s*(?:```|~~~)/) { $fenced = !$fenced; next }
    next if $fenced;
    for my $token (split) {
      my $unspaced = () = $token =~ /[\p{Han}\p{Hiragana}\p{Katakana}]/g;
      (my $rest = $token) =~ s/[\p{Han}\p{Hiragana}\p{Katakana}]/ /g;
      $words += $unspaced + grep { /[\p{L}\p{N}]/ } split " ", $rest;
    }
    END { print $words + 0 }' "$2" 2>/dev/null)" || return 1
  [[ "$words" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$words"
}

# 0 when the reply is long enough to ask for the result, 1 when it is not, 2 when it
# could not be counted.
reply_summary_is_long() {  # text
  local words
  words="$(_reply_summary_words "${1-}" 1)" || return 2
  (( words > reply_summary_max_words )) && return 0
  return 1
}

# 0 only for a counted answer with few enough words to restate a judged turn.
reply_summary_fits_restatement() {  # text
  local words
  words="$(_reply_summary_words "${1-}" 0)" || return 1
  (( words <= reply_summary_restatement_max_words ))
}

# Tool calls in the transcript's final turn, read by the verdict check's own bounded
# snapshot reader. The snapshot goes to a fresh path in the caller's scratch directory.
reply_summary_tool_count() {  # transcript-path scratch-dir
  local snapshot="$2/final-turn.json" identity state count
  [[ -n "${1-}" && -f "$1" && ! -L "$1" && -d "${2-}" ]] || return 1
  identity="$(verdict_audit_snapshot_final_turn_identity "$1" "$snapshot" \
    "$reply_summary_transcript_max_bytes" "$reply_summary_snapshot_max_bytes" \
    2>/dev/null)" || return 1
  state="$(verdict_audit_read_regular_state "$snapshot" \
    "$reply_summary_snapshot_max_bytes" json "$identity" 2>/dev/null)" || return 1
  verdict_audit_unlink_if_identity "$snapshot" "$identity" 2>/dev/null || true
  [[ "$state" == *$'\n'* ]] || return 1
  count="$(printf '%s' "${state#*$'\n'}" \
    | jq -r '.evidence_summary.seen // empty' 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

reply_summary_request() {
  printf 'Your reply above runs over %s words. End the turn with one more message that shows the result in few words: drawings of any kind that express it, as many as it takes; where a drawing cannot express it, at most 3 bullet points. Put anything the user must decide last. Restate only what the reply above says; use a tool only to render or send a drawing.' \
    "$reply_summary_max_words"
}

reply_summary_record_ask() {  # record-path prompt-epoch mode tool-count
  [[ -n "${1-}" && "${2-}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
  [[ "${3-}" == context || "${3-}" == block ]] || return 1
  [[ "${4-}" =~ ^([0-9]+|-)$ ]] || return 1
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  printf '%s %s %s\n' "$2" "$3" "$4" | verdict_audit_write_atomic "$1"
}

# Removes the record reply_summary_record_ask wrote with these fields, and only that
# record: a newer ask written since stays.
reply_summary_retract_ask() {  # record-path prompt-epoch mode tool-count
  verdict_audit_remove_record_if_matches "$1" "$2 $3 $4" >/dev/null 2>&1
}

# Prints the fields of a well-formed record and removes it. A record whose removal
# fails still counts as taken, so a broken state directory can stop further asks but
# can never make the gate ask in a loop.
reply_summary_take_ask() {  # record-path -> "prompt-epoch mode tool-count"
  local body epoch mode tools extra
  body="$(verdict_audit_read_single_record "$1" 2>/dev/null)" || return 1
  verdict_audit_remove_record_if_matches "$1" "$body" >/dev/null 2>&1 || true
  read -r epoch mode tools extra <<<"$body"
  [[ "$epoch" =~ ^[A-Za-z0-9_.:-]+$ && -z "$extra" ]] || return 1
  [[ "$mode" == context || "$mode" == block ]] || return 1
  [[ "$tools" =~ ^([0-9]+|-)$ ]] || return 1
  printf '%s %s %s' "$epoch" "$mode" "$tools"
}
