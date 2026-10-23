#!/usr/bin/env bash
# Shared summary check and skill reminder. Requires reply-summary.sh and perl.
# Source only; callers own dependency checks, host delivery and failure policy.

concise_writing_check_summary() { # Markdown, anywhere|first, optional word limit, optional no-hint
  local location="${2:-anywhere}" max_words="${3:-0}" summary counts status=0 verb=add
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
        $heading =~ s/[ \t]+\#*[ \t]*$//;
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

concise_writing_reminder() {
  local root reminder
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 2
  # shellcheck source=subagent.sh
  source "$root/.agents/lib/subagent.sh" || return 2
  reminder="$(subagent_prompt reminders/concise-writing-reminder "$root")" || return 2
  printf '%s' "$reminder"
}
