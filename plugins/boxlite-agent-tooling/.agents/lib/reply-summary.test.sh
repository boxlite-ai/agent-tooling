#!/usr/bin/env bash
# Exercise word counts and table recognition through the shared counter (#259).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./reply-summary.sh
source "$LIB_DIR/reply-summary.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
expect() { # name, expected total/paragraph/item counts, Markdown
  local actual status=0
  actual="$(reply_summary_word_counts "$3")" || status=$?
  if [[ "$status" == 0 && "$actual" == "$2" ]]; then
    ok "$1"
  else
    bad "$1 (got '$actual', exit $status; want '$2', exit 0)"
  fi
}
timed() { # Same inputs as expect; generation is outside the measured interval.
  local start elapsed actual_timed_counts timed_status
  start="$(perl -MTime::HiRes=time -e 'print time')"
  # Bound the actual counter process, without replacing its code or input.
  # Perl combines -e fragments; BEGIN arms the alarm before its input loop.
  actual_timed_counts="$(
    perl() { command perl -e 'BEGIN { alarm 10 }' "$@"; }
    reply_summary_word_counts "$3"
  )" && timed_status=0 || timed_status=$?
  elapsed="$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' -- "$start")"
  if [[ "$timed_status" == 0 && "$actual_timed_counts" == "$2" ]]; then
    ok "$1"
  else
    bad "$1 (got '$actual_timed_counts', exit $timed_status; want '$2', exit 0)"
  fi
  if perl -e 'exit($ARGV[0] < 2 ? 0 : 1)' -- "$elapsed"; then
    ok "$1 within 2 s ($elapsed s)"
  else
    bad "$1 took $elapsed s (limit 2 s)"
  fi
}

echo 'Table semantics: totals include tables; block maxima exclude them'
expect piped          '4 0 0' $'| a | b |\n| --- | --- |\n| 1 | 2 |'
expect pipeless       '4 0 0' $'a | b\n--- | ---\n1 | 2'
expect leading_pipe   '4 0 0' $'a | b\n| --- | ---\n1 | 2'
expect trailing_pipe  '4 0 0' $'a | b\n--- | --- |\n1 | 2'
expect aligned        '6 0 0' $'a | b | c\n:- | :-: | -:\n1 | 2 | 3'
expect one_column     '2 0 0' $'| a |\n:-:\n1'
expect tabs_and_cr    '4 0 0' $'a | b\n\t:-\t|\t-:\t\r\n1 | 2'
expect unicode_spaces '4 0 0' $'a | b\n　:-　|　-:　\n1 | 2'
expect unicode_words  '4 0 0' $'| 中 | あ |\n| - | - |\n| 字 | ア |'
expect escaped_pipe   '4 0 0' $'| a\\|b | c |\n| --- | --- |\n| 1 | 2 |'
expect quoted_table   '6 2 0' $'> | a | b |\n> | --- | --- |\n> | 1 | 2 |\n\nPlain text.'
expect item_table     '7 2 1' $'- Intro\n  | a | b |\n  | --- | --- |\n  | 1 | 2 |\n\nAfter text.'

echo 'Malformed delimiters remain prose'
expect suffix         '3 3 0' $'a | b\n---   x'
expect column_count   '4 4 0' $'a | b\n| --- |\n1 | 2'
expect empty_cell     '4 4 0' $'a | b\n--- || ---\n1 | 2'
expect missing_hyphen '4 4 0' $'a | b\n--- | :\n1 | 2'
expect inner_space    '4 4 0' $'a | b\n: --- | ---\n1 | 2'
expect extra_colon    '4 4 0' $'a | b\n::--- | ---\n1 | 2'

echo 'Linear delimiter recognition: exercise the counter with a piped header'
spaces="$(perl -e 'print " " x 200000')"
timed suffix_spaces    '3 3 0' $'a | b\n---'"${spaces}x"
timed prefix_spaces    '3 3 0' $'a | b\n'"${spaces}---x"
timed last_cell_spaces '3 3 0' $'a | b\n--- | ---'"${spaces}x"
timed valid_suffix     '2 0 0' $'a | b\n--- | ---'"$spaces"
timed valid_prefix     '2 0 0' $'a | b\n'"${spaces}--- | ---"
timed many_cells       '3 3 0' $'a | b\n'"$(perl -e 'print "-|" x 100000')x"

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
