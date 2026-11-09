#!/usr/bin/env perl
# Markdown measurements behind reply-summary.sh; UTF-8 text on stdin.
#   total -> the word count of the whole text
#   structure MAX_SENTENCES MAX_WORDS MIN_ITEMS MAX_ITEMS MIN_SUBITEMS MAX_SUBITEMS
#             MAX_DEPTH MIN_COLUMNS MAX_COLUMNS
#         -> one line per broken limit: rule, count, limit, excerpt, tab-separated
# Requires Perl 5.22 or later for the Unicode sentence boundary \b{sb} (UAX #29).
use strict;
use warnings;
use 5.022;

binmode STDIN, ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

my $unspaced = qr/[\p{Han}\p{Hiragana}\p{Katakana}]/;

# A word is a whitespace-separated token holding a letter or digit, so table pipes,
# list markers and box-drawing lines do not count. Chinese and Japanese, written
# without spaces, count one word per character; Korean spaces its words.
sub count_words {
  my $count = 0;
  for my $token (split ' ', $_[0]) {
    my $characters = () = $token =~ /$unspaced/g;
    (my $rest = $token) =~ s/$unspaced/ /g;
    $count += $characters + grep { /[\p{L}\p{N}]/ } split ' ', $rest;
  }
  return $count;
}

sub table_cells {
  my ($row) = @_;
  $row =~ s/^\s*\|//;
  $row =~ s/(?<!\\)\|\s*$//;
  return scalar split /(?<!\\)\|/, $row, -1;
}

# Group each optional outer pipe with its whitespace: without a pipe, adjacent
# whitespace runs would retry every split on a failing match.
sub is_table_start {
  my ($header, $delimiter) = @_;
  return $header =~ /\|/ && defined $delimiter
    && $delimiter =~ /^\s*(?:\|\s*)?:?-+:?\s*(?:\|\s*:?-+:?\s*)*(?:\|\s*)?$/
    && table_cells($header) == table_cells($delimiter);
}

sub excerpt {
  (my $text = shift) =~ s/\s+/ /g;
  $text =~ s/^ | $//g;
  return length($text) > 60 ? substr($text, 0, 60) . "\x{2026}" : $text;
}

# Dots and marks inside code, URLs and abbreviations end no sentence; a middle dot
# keeps the token whole and readable.
sub neutral { (my $text = shift) =~ tr/.?!/\x{B7}\x{B7}\x{B7}/; return $text }
my $abbreviation = qr/\b(?:e\.g\.|i\.e\.|vs\.|cf\.|Mr\.|Mrs\.|Ms\.|Dr\.|Prof\.|(?:No|Fig)\.(?=\s*\d))/;

sub sentences {
  my ($text) = @_;
  # \b{sb} rescans whitespace and punctuation runs at each position. One space, and
  # one middle dot per long run of other symbols, keep every boundary and stay linear.
  $text =~ s/\s+/ /g;
  $text =~ s/[^\p{L}\p{N}\s.?!\x{3002}\x{FF01}\x{FF1F}]{9,}/\x{B7}/g;
  $text =~ s/(`+)(?!`).*?(?<!`)\1(?!`)/neutral($&)/ge;
  # Link text and targets stop at the next bracket or parenthesis, so a failed match
  # never rescans the rest of the text.
  $text =~ s/!?\[([^\[\]]*+)\]\([^()\s]*+\)/$1/g;
  $text =~ s{\bhttps?://\S*[^\s.?!,;:)]}{neutral($&)}ge;
  $text =~ s/$abbreviation/neutral($&)/ge;
  # A bold label such as "**Fix.**" or "**Fix:**" names a block; it is no sentence.
  $text =~ s/^\s*\*\*([^*]{1,60}?)[.:]\*\*/$1:/;
  my @sentences;
  # UAX #29 rule SB8 joins ". #388 is", ". 2 tests" or ". `make` runs" because a
  # lowercase letter follows; replies often start sentences with an issue number, a
  # digit or inline code.
  for my $chunk (split /(?<=[.?!])\s+(?=[#\d`])/, $text) {
    push @sentences, grep { /[\p{L}\p{N}]/ } split /\b{sb}/, $chunk;
  }
  return map { (my $sentence = $_) =~ tr/\x{B7}/./; $sentence } @sentences;
}

sub structure {
  my ($text, $max_sentences, $max_words, $min_items, $max_items, $min_subitems, $max_subitems,
    $max_depth, $min_columns, $max_columns) = @_;
  my @report;
  my $flag = sub { push @report, join "\t", $_[0], $_[1], $_[2], excerpt($_[3]) };
  $text =~ s/\r\n?/\n/g;
  $text =~ s/<!--.*?(?:-->|\z)//sg;
  my @lines = split /\n/, $text;
  my ($block, $fence, $table, $summary_next) = (undef, '', 0, 0);
  # One entry per open list level: the parent item's content indent, the current
  # item's content indent, the item count, and the first item for the excerpt.
  my @levels;
  my ($item_indent, $after_blank, $too_deep) = (0, 0, 0);

  my $close_block = sub {
    return unless $block;
    my @found = sentences($block->{text});
    $flag->($block->{kind}, scalar @found, $max_sentences, $block->{text}) if @found > $max_sentences;
    for my $sentence (@found) {
      # The TL;DR keeps its own word limit; unspaced scripts count characters.
      next if $block->{summary} || $sentence =~ $unspaced;
      my $words = count_words($sentence);
      $flag->('sentence', $words, $max_words, $sentence) if $words > $max_words;
    }
    undef $block;
  };
  my $close_level = sub {
    my $level = pop @levels;
    my ($rule, $min, $max) = @levels ? ('sublist', $min_subitems, $max_subitems)
      : ('list', $min_items, $max_items);
    $flag->($rule, $level->{items}, "$min\x{2013}$max", $level->{first})
      if $level->{items} < $min || $level->{items} > $max;
  };
  my $close_list = sub {
    $close_block->();
    $close_level->() while @levels;
    ($item_indent, $after_blank, $too_deep) = (0, 0, 0);
  };
  my $indent_of = sub { (my $indent = $_[0] =~ /^(\s*)/ ? $1 : '') =~ s/\t/    /g; length $indent };

  for my $index (0 .. $#lines) {
    my $line = $lines[$index];
    if (length $fence) {
      my $marker = substr $fence, 0, 1;
      $fence = '' if $line =~ /^\s*\Q$fence\E\Q$marker\E*\s*$/;
      next;
    }
    if ($line =~ /^\s*$/) {
      @levels ? ($after_blank = 1) : $close_block->();
      $table = 0;
      next;
    }
    my $indent = $indent_of->($line);
    # Inside a list, a line left of the item content after a blank, or any block
    # start left of it, ends the list.
    my $starts_block = $line =~ /^\s*(?:`{3,}|~{3,}|>|\#{1,6}(?:\s|$))/
      || is_table_start($line, $lines[$index + 1]);
    $close_list->() if @levels && $indent < $item_indent && ($after_blank || $starts_block)
      && $line !~ /^\s*(?:[-+*]|\d{1,9}[.)])(?:\s|$)/;
    $after_blank = 0;
    if ($line =~ /^\s*(`{3,}|~{3,})/) {
      $fence = $1;
      $close_block->() unless @levels;
      next;
    }
    if ($line =~ /^\s*>/) {
      $close_block->() unless @levels;
      next;
    }
    # Possessive runs keep long whitespace in a heading linear.
    if ($line =~ /^ {0,3}\#{1,6}(?:[ \t]++(.*))?$/) {
      $close_list->();
      $close_block->();
      $summary_next = ($1 // '') =~ /^TL;DR(?:[ \t]++\#*+)?[ \t]*+$/i;
      $table = 0;
      next;
    }
    (my $bare = $line) =~ tr/ \t//d;
    if ($line =~ /^ {0,3}[-*_]/ && $bare =~ /^(?:-{3,}|\*{3,}|_{3,})$/) {
      $close_list->();  # A thematic break ends any list.
      next;
    }
    if (is_table_start($line, $lines[$index + 1])) {
      $close_block->() unless @levels;
      my $columns = table_cells($line);
      $flag->('table', $columns, "$min_columns\x{2013}$max_columns", $line)
        if $columns < $min_columns || $columns > $max_columns;
      $table = 1;
      next;
    }
    next if $table;
    if ($line =~ /^(\s*(?:[-+*]|\d{1,9}[.)])(?:\s+|$))(.*)$/) {
      my ($prefix, $content) = ($1, $2);
      (my $width = $prefix) =~ s/\t/    /g;
      $close_block->();
      # An item at or right of the current item's content nests under it; one left of
      # its level's parent content closes that level.
      $close_level->() while @levels > 1 && $indent < $levels[-1]{parent};
      if (@levels && $indent >= $levels[-1]{content}) {
        push @levels, { parent => $levels[-1]{content}, items => 0, first => $content };
        $flag->('depth', scalar @levels, $max_depth, $content)
          if @levels > $max_depth && !$too_deep++;
      } elsif (!@levels) {
        push @levels, { parent => 0, items => 0, first => $content };
      }
      $levels[-1]{items}++;
      $levels[-1]{content} = length $width;
      $item_indent = $levels[0]{content};
      # An item may open a fence on its marker line; the fence holds code, not prose.
      if ($content =~ /^(`{3,}|~{3,})/) {
        $fence = $1;
        $content = '';
      }
      $block = { kind => 'item', text => $content };
      next;
    }
    if (!$block) {
      $close_list->() if @levels;
      $block = { kind => 'prose', text => '', summary => $summary_next };
      $summary_next = 0;
    }
    $block->{text} .= " $line";
  }
  $close_list->();
  $close_block->();
  return @report;
}

my $mode = shift // '';
my $text = do { local $/; <STDIN> } // '';
if ($mode eq 'total') {
  print count_words($text);
} elsif ($mode eq 'structure' && @ARGV == 9 && !grep { !/^[0-9]+$/ } @ARGV) {
  print "$_\n" for structure($text, @ARGV);
} else {
  die "usage: reply-summary.pl total | structure MAX_SENTENCES MAX_WORDS MIN_ITEMS MAX_ITEMS"
    . " MIN_SUBITEMS MAX_SUBITEMS MAX_DEPTH MIN_COLUMNS MAX_COLUMNS\n";
}
