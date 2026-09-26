#!/usr/bin/env bash
# Shared summary check and skill reminder. Requires reply-summary.sh and perl.
# Source only; callers own dependency checks, host delivery and failure policy.

concise_writing_check_summary() { # Markdown, anywhere|first, optional word limit
  local location="${2:-anywhere}" max_words="${3:-0}" summary counts status=0 problem correction
  if (( ${#1} > 262144 )); then
    printf '## TL;DR\n\nThe text exceeds the 262144-character inspection limit.\n\n## Correction\n\nShorten the text below the inspection limit before retrying.\n'
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
    exit 5 unless $summary =~ /\A {0,3}\\?[\p{L}\p{N}*_\[]/ && $summary =~ /[\p{L}\p{N}]/;
    print $summary;
  ' "$location")" || status=$?
  if (( status == 0 )); then
    counts="$(reply_summary_word_counts "$summary")" || status=6
    [[ -n "$counts" ]] || status=6
  fi
  # Give a complete correction: rewording the summary cannot fix a section boundary.
  # shellcheck disable=SC2016 # Render literal Markdown headings, never shell expansion.
  case "$status" in
    0) (( max_words == 0 || ${counts%% *} <= max_words )) && return 0
       problem="The TL;DR section has ${counts%% *} words; limit $max_words."
       correction='Keep one short sentence and start a new section (for example, `## Details` after `## TL;DR`); only a heading of the same or higher level ends the summary.' ;;
    3) problem='Missing a Markdown TL;DR heading.'
       correction='Use the literal line `## TL;DR`, then one short sentence and a peer heading such as `## Details` before supporting text; a bold label is not a heading.'
       [[ "$location" != first ]] || correction="Begin the reply with it. $correction" ;;
    4) problem='The TL;DR heading appears after other content.'
       correction='Move the TL;DR heading and its summary to the beginning, before any other visible text.' ;;
    5) problem='TL;DR summary prose is missing or malformed.'
       correction='Put one short sentence beginning with a word directly below the heading, outside lists, tables, quotes, and code.' ;;
    6) problem='The TL;DR section could not be counted.'
       correction='Check the word-counter dependency before retrying; rewording the reply will not repair the checker.' ;;
    *) problem='The TL;DR section could not be inspected.'
       correction='Check the Markdown-parser dependency before retrying; rewording the reply will not repair the checker.' ;;
  esac
  printf '## TL;DR\n\n%s\n\n## Correction\n\n%s\n' "$problem" "$correction"
  return 1
}

concise_writing_reminder() {
  printf '%s' 'Use the boxlite-writing skill to shorten this response.'
}
