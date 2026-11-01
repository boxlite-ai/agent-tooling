#!/usr/bin/env bash
# Render numeric policy into the skill; --check reports drift without writing.
set -euo pipefail
[[ $# == 0 || ( $# == 1 && "$1" == --check ) ]] || {
  printf 'usage: sync-rules.sh [--check]\n' >&2; exit 2;
}
skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in jq perl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'boxlite-writing: missing %s\n' "$dependency" >&2; exit 2;
  }
done
# shellcheck source=policy.sh
source "$skill_root/scripts/policy.sh"
rules="$(boxlite_writing_rules)"
table="$(printf '%s' "$rules" | jq -r '
  "| Rule | Limit | Checked by hooks |",
  "| --- | --- | --- |",
  "| TL;DR section | At most \(.enforced.summary_max_words) words | Where callers require a cap |",
  "| Short replies and comments | At most \(.enforced.short_reply_max_words) words may omit TL;DR | Yes |",
  "| GitHub paragraphs / list items | At most \(.enforced.paragraph_max_words) / \(.enforced.item_max_words) words | Unless a valid TL;DR leads |",
  "| Sentences | At most \(.guidance.sentence_max_words) words | No |",
  "| Prose blocks | \(.guidance.prose_max_sentences) sentence; up to \(.guidance.reasoning_max_sentences) for connected reasoning | No |",
  "| Lists | \(.guidance.list_min_items)–\(.guidance.list_max_items) flat items; \(.guidance.list_item_max_sentences) sentence each | No |",
  "| Tables | \(.guidance.table_min_columns)–\(.guidance.table_max_columns) columns; one-line cells | No |"
')"
table="${table//$'\r'/}"
perl -CSDA -e '
  use strict; use warnings;
  my ($check, $table, $path) = @ARGV;
  open my $in, "<:encoding(UTF-8)", $path or die "boxlite-writing: cannot read SKILL.md\n";
  local $/; my $text = <$in>; close $in;
  my ($begin, $end) = ("<!-- writing-limits:begin -->", "<!-- writing-limits:end -->");
  my $starts = () = $text =~ /\Q$begin\E/g;
  my $ends = () = $text =~ /\Q$end\E/g;
  die "boxlite-writing: expected one ordered limits block\n" unless
    $starts == 1 && $ends == 1 && $text =~ /\Q$begin\E.*?\Q$end\E/s;
  my $newline = $text =~ /\r\n/ ? "\r\n" : "\n";
  $table =~ s/\n/$newline/g;
  my $updated = $text;
  $updated =~ s/\Q$begin\E.*?\Q$end\E/$begin . $newline . $table . $newline . $end/se;
  if ($check eq "--check") {
    die "boxlite-writing: limits table is stale; run scripts\/sync-rules.sh in the skill\n"
      if $updated ne $text;
  } elsif ($updated ne $text) {
    open my $out, ">:encoding(UTF-8)", $path or die "boxlite-writing: cannot write SKILL.md\n";
    print {$out} $updated; close $out or die "boxlite-writing: cannot finish SKILL.md\n";
  }
' -- "${1-}" "$table" "$skill_root/SKILL.md"
