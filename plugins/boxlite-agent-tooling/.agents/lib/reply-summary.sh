#!/usr/bin/env bash
# Shared reply measurements: the Markdown word counter behind the TL;DR limit and the
# GitHub paragraph and item limits, and the bounded reader that recovers the Stop
# gate's last reply from the transcript. Source this file; it performs no work on
# load. Requires sourced verdict-audit-state.sh, and perl and jq on PATH; callers own
# those checks and all reporting.

# Readability thresholds are independent of the shared prompt's prose budget.
reply_summary_paragraph_max_words=80
reply_summary_item_max_words=40
# The same snapshot bound the verdict check puts on the transcript it reads.
reply_summary_snapshot_max_bytes=262144

# A word is a whitespace-separated token holding a letter or digit, so table pipes,
# list markers and box-drawing lines do not count. Chinese and Japanese, written
# without spaces, count one word per character, the usual convention for them; Korean
# spaces its words and counts like English. Readability is a Markdown heuristic:
# blank lines delimit paragraphs, list markers delimit items, and indented item
# continuations stay together across blank lines. Soft wraps do not split blocks.
# Fenced blocks, headings and tables with a delimiter row are excluded from the
# block maxima only.
reply_summary_word_counts() {  # text -> total largest-paragraph largest-item
  local counts
  counts="$(printf '%s\n' "${1-}" | perl -CSD -0777 -ne '
    use strict;
    use warnings;
    sub count_words {
      my $count = 0;
      for my $token (split " ", $_[0]) {
        my $unspaced = () = $token =~ /[\p{Han}\p{Hiragana}\p{Katakana}]/g;
        (my $rest = $token) =~ s/[\p{Han}\p{Hiragana}\p{Katakana}]/ /g;
        $count += $unspaced + grep { /[\p{L}\p{N}]/ } split " ", $rest;
      }
      return $count;
    }
    sub table_cells {
      my ($row) = @_;
      $row =~ s/^\s*\|//;
      $row =~ s/(?<!\\)\|\s*$//;
      return scalar split /(?<!\\)\|/, $row, -1;
    }
    my $total = count_words($_);
    my @lines = split /\n/;
    my @quoted = map { /^\s*>/ ? 1 : 0 } @lines;
    s/^\s*(?:>\s*)+// for @lines;
    my ($block_words, $is_item, $paragraph_max, $item_max) = (0, 0, 0, 0);
    my ($item_indent, $after_blank) = (0, 0);
    my ($fence, $table) = ("", 0);
    my $finish_block = sub {
      if ($is_item) {
        $item_max = $block_words if $block_words > $item_max;
      } else {
        $paragraph_max = $block_words if $block_words > $paragraph_max;
      }
      ($block_words, $is_item) = (0, 0);
      ($item_indent, $after_blank) = (0, 0);
    };
    for my $index (0 .. $#lines) {
      my $line = $lines[$index];
      if (length $fence) {
        my $marker = substr $fence, 0, 1;
        $fence = "" if $line =~ /^\s*\Q$fence\E\Q$marker\E*\s*$/;
        next;
      }
      if ($line =~ /^\s*$/) {
        $is_item ? ($after_blank = 1) : $finish_block->();
        $table = 0;
        next;
      }
      if ($after_blank) {
        my ($indent) = $line =~ /^(\s*)/;
        $indent =~ s/\t/    /g;
        $finish_block->() if length($indent) < $item_indent;
        $after_blank = 0;
      }
      if ($line =~ /^\s*(`{3,}|~{3,})/) {
        $fence = $1;
        $finish_block->() unless $is_item;
        $table = 0;
        next;
      }
      if ($line =~ /^\s*\#{1,6}(?:\s|$)/) {
        $finish_block->();
        $table = 0;
        next;
      }
      $table = 0 if $index && $quoted[$index] != $quoted[$index - 1];
      if ($line =~ s/^(\s*(?:[-+*]|[0-9]+[.)])\s+)//) {
        my $prefix = $1;
        $prefix =~ s/\t/    /g;
        $finish_block->();
        $is_item = 1;
        $item_indent = length $prefix;
        $table = 0;
      }
      if ($line =~ /\|/ && $index < $#lines &&
          $lines[$index + 1] =~ /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/ &&
          table_cells($line) == table_cells($lines[$index + 1])) {
        $finish_block->() unless $is_item;
        $table = 1;
        next;
      }
      next if $table;
      $block_words += count_words($line);
    }
    $finish_block->();
    print "$total $paragraph_max $item_max";
  ' 2>/dev/null)" || return 1
  [[ "$counts" =~ ^[0-9]+[[:space:]][0-9]+[[:space:]][0-9]+$ ]] || return 1
  printf '%s' "$counts"
}

# 0 when a paragraph or list item is over its limit, 1 when none is, 2 when the text
# could not be counted.
reply_summary_is_dense() {  # text
  local counts _total paragraph_words item_words
  counts="$(reply_summary_word_counts "${1-}")" || return 2
  read -r _total paragraph_words item_words <<< "$counts"
  (( paragraph_words > reply_summary_paragraph_max_words \
     || item_words > reply_summary_item_max_words )) && return 0
  return 1
}

# A text within one paragraph's word budget reads whole, so it needs no summary.
# 0 when short, 1 when longer, 2 when the text could not be counted.
reply_summary_is_short() {  # text
  local text="${1-}" counts total
  # Text over the 8000-character GitHub writing cap is never short, which bounds the
  # counter's work before the TL;DR check applies its own limit.
  (( ${#text} <= 8000 )) || return 1
  counts="$(reply_summary_word_counts "$text")" || return 2
  read -r total _ <<< "$counts"
  [[ "$total" =~ ^[0-9]+$ ]] || return 2
  (( total <= reply_summary_paragraph_max_words ))
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
