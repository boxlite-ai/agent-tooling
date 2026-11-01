#!/usr/bin/env bash
# Sourceable writing checks owned by boxlite-writing. Requires Bash, Perl, and jq.
# Existing function names, arguments, diagnostics, and statuses remain compatible.
# No host state, transcript access, stdin consumption, or output on successful load.
# Numeric policy is read inside calls; Markdown prose is never runtime input.
[[ -f "$(dirname "${BASH_SOURCE[0]}")/policy.sh" &&
   -r "$(dirname "${BASH_SOURCE[0]}")/policy.sh" ]] || {
  printf 'boxlite-writing: policy loader unavailable\n' >&2; return 2;
}
# shellcheck source=policy.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/policy.sh" || return 2

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
      # Group each optional outer pipe with its whitespace: without a pipe,
      # adjacent whitespace runs would retry every split on a failing match.
      if ($line =~ /\|/ && $index < $#lines &&
          $lines[$index + 1] =~ /^\s*(?:\|\s*)?:?-+:?\s*(?:\|\s*:?-+:?\s*)*(?:\|\s*)?$/ &&
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
  local counts _total paragraph_words item_words limits _summary _short paragraph_max item_max
  limits="$(boxlite_writing_rules limits)" || return 2
  read -r _summary _short paragraph_max item_max <<< "$limits"
  counts="$(reply_summary_word_counts "${1-}")" || return 2
  read -r _total paragraph_words item_words <<< "$counts"
  (( paragraph_words > paragraph_max \
     || item_words > item_max )) && return 0
  return 1
}

# Short replies read whole; their exemption is independent of paragraph density.
# 0 when short, 1 when longer, 2 when the text could not be counted.
reply_summary_is_short() {  # text
  local text="${1-}" counts total limits _summary short_max _paragraph _item
  limits="$(boxlite_writing_rules limits)" || return 2
  read -r _summary short_max _paragraph _item <<< "$limits"
  # Text over 8000 characters is never short, which bounds the counter's work before
  # the TL;DR check applies its own limit.
  (( ${#text} <= 8000 )) || return 1
  counts="$(reply_summary_word_counts "$text")" || return 2
  read -r total _ <<< "$counts"
  [[ "$total" =~ ^[0-9]+$ ]] || return 2
  (( total <= short_max ))
}

concise_writing_check_summary() { # Markdown, anywhere|first, optional word limit|policy, optional no-hint
  local location="${2:-anywhere}" max_words="${3:-0}" summary counts status=0 verb=add
  local limits summary_max _short _paragraph _item
  limits="$(boxlite_writing_rules limits)" || {
    printf 'Writing policy unavailable: repair boxlite-writing/rules.json\n'; return 1;
  }
  read -r summary_max _short _paragraph _item <<< "$limits"
  [[ "$max_words" != policy ]] || max_words="$summary_max"
  local skill_hint='; apply boxlite-writing'
  # Name the skill unless the caller appends its own reminder, as the PR gate does for
  # GitHub writing denials.
  [[ "${4:-}" != no-hint ]] || skill_hint=''
  if (( ${#1} > 262144 )); then
    printf 'TL;DR not checked: text over 262144 characters; shorten it\n'
    return 1
  fi
  # Accept an ATX heading and prose, never an example or a hidden comment.
  # Parser exits distinguish missing heading (3), misplaced heading (4), and missing prose (5).
  summary="$(printf '%s' "$1" | perl -CSD -0777 -e '
    my $text = <STDIN> // "";
    $text =~ s/<!--.*?(?:-->|\z)//sg;
    my ($fence, $level, $seen) = ("", 0, 0);
    my @summary;
    for my $line (split /\n/, $text) {
      $line =~ s/\r$//;
      if (length $fence) {
        push @summary, $line if $level;
        my $marker = substr $fence, 0, 1;
        $fence = "" if $line =~ /^ {0,3}\Q$fence\E\Q$marker\E*[ \t]*$/;
        next;
      }
      if ($line =~ /^ {0,3}(`{3,}|~{3,})/) {
        $fence = $1; $seen = 1; push @summary, $line if $level; next;
      }
      if ($line =~ /^ {0,3}(\#{1,6})[ \t]+(.*)$/) {
        my ($depth, $heading) = (length($1), $2);
        last if $level && $depth <= $level;
        # Strip the closing sequence from the reversed text: anchored at its start, the
        # match runs once instead of from every blank in a long run.
        $heading = reverse $heading;
        $heading =~ s/\A[ \t]*\#*[ \t]+//;
        $heading = reverse $heading;
        if (!$level && $heading =~ /^TL;DR$/i) {
          exit 4 if $ARGV[0] eq "first" && $seen;
          $level = $depth; next;
        }
      }
      push @summary, $line if $level;
      next if $line =~ /^[ \t]*$/;
      $seen = 1;
    }
    exit 3 unless $level;
    my $summary = join "\n", @summary;
    $summary =~ s/\A(?:[ \t]*\n)+//;
    # The summary opens with a paragraph (CommonMark 0.31.2, 4.8) that starts with a word,
    # emphasis, a link or a code span (6.1). A first character also admits a list item
    # (5.2), a thematic break (4.1), a footnote or link reference definition (4.7), a
    # setext heading (4.3) or a GFM table (4.10), so those are refused by shape. Keep
    # each pattern linear: no two unbounded whitespace runs may match the same spaces.
    my ($first, @rest) = split /\n/, $summary;
    $first //= "";
    exit 5 unless $first =~ /\A {0,3}(?:\\?[\p{L}\p{N}*_\[]|(`{1,2})(?!`).+?(?<!`)\1(?!`))/
      && $summary =~ /[\p{L}\p{N}]/;
    my $break = qr/(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})\z/;
    exit 5 if $first =~ /\A {0,3}(?:(?:[*+-]|[0-9]{1,9}[.)])(?:[ \t]|\z)|$break|\[\^[^\]\s]+\]:)/
      || $first =~ /\A {0,3}\[[^\]]+\]:(?:[ \t]*(?:<[^>]*>|\S+)(?:[ \t]+(?:"[^"]*"|\x27[^\x27]*\x27|\([^)]*\)))?)?[ \t]*\z/
      || ($rest[0] // "") =~ /\A {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*(?:\|[ \t]*)?\z/;
    # The paragraph runs until a blank line or a block that interrupts it; an underline
    # first makes it a heading.
    for (@rest) {
      last if /\A[ \t]*\z/;
      exit 5 if /\A {0,3}(?:=+|-+)[ \t]*\z/;
      last if /\A {0,3}(?:`{3,}|~{3,}|>|#{1,6}(?:[ \t]|\z)|(?:[*+-]|1[.)])[ \t]+\S|$break)/;
    }
    print $summary;
  ' "$location")" || status=$?
  if (( status == 0 )); then
    counts="$(reply_summary_word_counts "$summary")" || status=6
    [[ -n "$counts" ]] || status=6
  fi
  # One line each: the failed condition, then a literal fix that passes when followed.
  # Checker failures omit the skill hint: rewording cannot repair them.
  # shellcheck disable=SC2016 # Render literal Markdown headings, never shell expansion.
  case "$status" in
    0) (( max_words == 0 || ${counts%% *} <= max_words )) && return 0
       printf 'TL;DR has %s words (limit %s): keep one short sentence, then a same-level heading like `## Details`%s\n' \
         "${counts%% *}" "$max_words" "$skill_hint" ;;
    3) [[ "$location" != first ]] || verb='start with'
       printf 'TL;DR heading missing: %s `## TL;DR`, one short sentence, then `## Details` before more text%s\n' \
         "$verb" "$skill_hint" ;;
    4) printf 'TL;DR not first: move `## TL;DR` and its sentence to the top%s\n' "$skill_hint" ;;
    5) printf 'TL;DR summary missing or invalid: under `## TL;DR`, start one plain sentence with a word or inline code%s\n' \
         "$skill_hint" ;;
    6) printf 'TL;DR word counter failed: fix the counter; rewording will not help\n' ;;
    *) printf 'TL;DR parser (perl) failed: fix it; rewording will not help\n' ;;
  esac
  return 1
}

boxlite_writing_check_body() { # body [comment]
  local body="$1" kind="${2-}" density=0
  if [[ "$body" != *[![:space:]]* ]]; then
    printf 'GitHub text is empty.'
    return 1
  fi
  local limits summary_max _short paragraph_max item_max
  limits="$(boxlite_writing_rules limits)" || {
    printf 'GitHub writing policy unavailable: repair boxlite-writing/rules.json'; return 1;
  }
  read -r summary_max _short paragraph_max item_max <<< "$limits"
  # No length limit: GitHub enforces its own, and these checks stay linear (#310).
  # Complete artifacts need room for evidence, so no total word cap applies. A leading
  # TL;DR already gives readers the short version, so its details may also be dense.
  concise_writing_check_summary "$body" first "$summary_max" no-hint >/dev/null && return 0
  reply_summary_is_dense "$body" || density=$?
  # shellcheck disable=SC2016 # Render literal Markdown headings, never shell expansion.
  case "$density" in
    # The PR gate appends the shared skill reminder to every writing denial. A comment
    # within one paragraph's budget reads whole; documents keep their summary.
    1) [[ "$kind" == comment ]] && reply_summary_is_short "$body" && return 0
       concise_writing_check_summary "$body" anywhere "$summary_max" no-hint; return $? ;;
    0) printf 'GitHub text has a paragraph over %s words or a list item over %s words: shorten them, or start with `## TL;DR` and one short sentence.' \
         "$paragraph_max" "$item_max" ;;
    *) printf 'GitHub text could not be counted.' ;;
  esac
  return 1
}
