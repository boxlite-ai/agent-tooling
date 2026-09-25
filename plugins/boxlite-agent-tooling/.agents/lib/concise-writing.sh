#!/usr/bin/env bash
# Shared summary check and prompt renderer. Requires reply-summary.sh and perl;
# rendering also needs subagent.sh.
# Source only; callers own dependency checks, host delivery and failure policy.

concise_writing_check_summary() { # Markdown, anywhere|first, optional word limit
  local location="${2:-anywhere}" max_words="${3:-0}" summary counts status=0 problem
  if (( ${#1} > 262144 )); then
    printf '## TL;DR\n\nThe text is too long to check for a TL;DR section.\n'
    return 1
  fi
  # Accept an ATX heading and prose, never an example or a hidden comment.
  # Exit 3: no TL;DR heading; 4: text before it; 5: no summary prose under it.
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
    counts="$(reply_summary_word_counts "$summary")" || status=1
  fi
  # Name the failed condition: a generic reminder leads agents to reword a valid sentence.
  case "$status" in
    0) (( max_words == 0 || ${counts%% *} <= max_words )) && return 0
       problem="The TL;DR section has ${counts%% *} words, over the $max_words-word limit. It runs until the next heading: keep one short sentence there and start a new heading after it." ;;
    3) problem='Add a visible TL;DR heading followed by one short sentence.'
       [[ "$location" != first ]] || problem='Begin with a TL;DR heading followed by one short sentence.' ;;
    4) problem='Move the TL;DR section to the start; nothing may come before its heading.' ;;
    5) problem='Follow the TL;DR heading with one short sentence that opens with a word, not a symbol, list, table, quote, or code.' ;;
    *) problem='The TL;DR section could not be checked.' ;;
  esac
  printf '## TL;DR\n\n%s\n' "$problem"
  return 1
}

concise_writing_prompt() { # tooling-root
  local prompt
  prompt="$(subagent_prompt concise-writing "$1" max_words=60)" || return $?
  if [[ "$prompt" != *[![:space:]]* ]]; then
    printf 'concise-writing: empty prompt: %s/.agents/prompts/concise-writing.md\n' "$1" >&2
    return 1
  fi
  printf '%s' "$prompt"
}
