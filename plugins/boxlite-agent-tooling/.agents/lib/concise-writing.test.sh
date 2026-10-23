#!/usr/bin/env bash
# Tests for .agents/lib/concise-writing.sh: what may open a TL;DR summary (#257).
#
# The summary's first block must be a paragraph that opens with a word, emphasis, a
# link or a closed code span of one or two backticks. Each row puts Markdown under
# `## TL;DR` and expects the verdict GitHub's renderer implies; rows marked narrowed
# are paragraphs denied on purpose. Lines built to make a pattern backtrack must
# finish within 2 s.
#
# Run with:  bash .agents/lib/concise-writing.test.sh
# Exits non-zero on any failure.
# shellcheck disable=SC2016 # Markdown backticks in cases and feedback are literal.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./reply-summary.sh
source "$LIB_DIR/reply-summary.sh"
# shellcheck source=./concise-writing.sh
source "$LIB_DIR/concise-writing.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
expect() {  # name allow|deny markdown-under-the-heading
  local actual=allow
  concise_writing_check_summary "## TL;DR"$'\n\n'"$3" first 39 >/dev/null || actual=deny
  if [[ "$actual" == "$2" ]]; then ok "$1"; else bad "$1 (got $actual, want $2)"; fi
}

echo "Paragraph openings"
expect word                 allow 'A plain sentence.'
expect emphasis             allow '*Bold* move here.'
expect strong_italic        allow '***Bold italic*** text.'
expect dunder               allow '__init__.py is loaded first.'
expect link                 allow '[Link](https://example.com) text.'
expect link_def_like        allow '[WIP]: still drafting the API.'
expect escaped_star         allow '\* is a literal asterisk.'
expect decimal              allow '1.5x faster builds.'
expect year                 allow '2026 brought faster builds.'
expect ten_digits           allow '1234567890. is not a list.'

echo "Code spans (CommonMark 6.1)"
expect code_one             allow '`stop-gate.sh` now leads every reply.'
expect spec329_double       allow '`` foo ` bar `` is one span.'
expect spec339_double       allow '``foo`bar`` is one span.'
expect spec349_unclosed     deny  '`foo``bar`` is not.'
expect unclosed             deny  '`foo is not closed.'
expect three_ticks_narrowed deny  '```foo``` bar.'
expect two_lines_narrowed   deny  $'`foo\nbar` baz.'

echo "Code blocks, quotes, headings, HTML"
expect fence_backtick       deny  $'```\nA concise answer.\n```'
expect fence_tilde          deny  $'~~~\nA concise answer.\n~~~'
expect indented_code        deny  '    code here'
expect quote                deny  '> quoted text'
expect atx_deeper           deny  '### Sub heading'
expect html                 deny  '<b>Bold</b> text.'
expect issue_ref            deny  '#120 now passes.'

echo "Lists (5.2)"
expect list_star            deny  '* item one'
expect list_dash            deny  '- item one'
expect list_plus            deny  '+ item one'
expect list_ordered_dot     deny  '1. item one'
expect list_ordered_paren   deny  '1) item one'
expect list_code            deny  '* `foo` item'
expect task_list            deny  '* [ ] task'
expect empty_bullet         deny  $'*\nFoo bar.'
expect empty_ordered        deny  $'1.\nFoo bar.'

echo "Thematic breaks (4.1) and definitions (4.7, footnotes)"
expect break_star           deny  $'***\nFoo bar.'
expect break_spaced         deny  $'* * *\nFoo bar.'
expect break_underscore     deny  $'___\nFoo bar.'
expect link_def             deny  '[foo]: https://example.com'
expect link_def_title       deny  '[foo]: https://example.com "Title"'
expect link_def_angle       deny  '[foo]: <https://example.com/a b>'
expect footnote_def         deny  '[^1]: A footnote.'

echo "Setext headings (4.3) and what follows a sentence"
expect setext_eq            deny  $'Some heading\n==='
expect setext_dash          deny  $'Some heading\n---'
expect setext_code          deny  $'`foo` heading\n==='
expect setext_multi         deny  $'Foo\nbar\n==='
expect setext_list2         deny  $'Foo\n2. bar\n==='
expect setext_after_blank   allow $'Foo bar.\n\n==='
expect list_after_sentence  allow $'Foo:\n- a\n- b'
expect break_after_sentence allow $'Foo bar.\n***'
expect fence_after_sentence allow $'Add this config:\n```yaml\n---\nkey: value\n```'
expect quote_after_sentence allow $'Foo bar.\n> quote\n---'

echo "GFM tables (4.10)"
expect table_piped          deny  $'| a | b |\n| --- | --- |\n| 1 | 2 |'
expect table_pipeless       deny  $'a | b\n--- | ---\n1 | 2'
expect table_code           deny  $'`a` | b\n--- | ---\n1 | 2'
expect table_one_col        deny  $'Foo bar\n|---|'
expect table_mismatch_narrowed deny $'Foo bar\n--- | ---'
expect table_after_sentence allow $'Intro line.\na | b\n--- | ---'

echo "Denial"
denial="$(concise_writing_check_summary $'## TL;DR\n\n* item one' first 39)"
want='TL;DR summary missing or invalid: under `## TL;DR`, start one plain sentence with a word or inline code; apply boxlite-writing'
if [[ "$denial" == "$want" ]]; then ok denial_names_inline_code; else bad "denial_names_inline_code (got $denial)"; fi

echo "Linear patterns"
long() { perl -e 'print $ARGV[0] x $ARGV[1]' -- "$1" "$2"; }
timed() {  # name allow|deny markdown-under-the-heading
  local start elapsed
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  expect "$@"
  elapsed="$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' -- "$start")"
  if perl -e 'exit($ARGV[0] < 2 ? 0 : 1)' -- "$elapsed"; then ok "$1 within 2 s"; else bad "$1 took $elapsed s"; fi
}
timed delimiter_spaces_tail  allow "Foo"$'\n'"---$(long ' ' 200000)x"
timed delimiter_many_cells   allow "Foo"$'\n'"$(long '-|' 100000)x"
timed span_unclosed_long     deny  "\`$(long a 200000)"
timed span_double_ticks_long deny  "\`\`$(long 'a`' 100000)"
timed link_label_unclosed    allow "[$(long a 200000)"
timed link_dest_spaces_tail  allow "[a]: b$(long ' ' 200000)x"
timed link_colon_spaces_tail allow "[a]:$(long ' ' 200000)x y"
timed break_alternating      allow "Foo"$'\n'"*$(long ' *' 100000)x"
timed underline_spaces_tail  allow "Foo"$'\n'"$(long '=' 100000)$(long ' ' 100000)x"
timed underline_dash_spaces  deny  "Foo"$'\n'"-$(long ' ' 200000)"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
