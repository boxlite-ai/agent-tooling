#!/usr/bin/env bash
# Exercise the shared word counter (#259) and the structure limits (#419).
# shellcheck disable=SC2016 # Markdown backticks in fixtures are literal.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./reply-summary.sh
source "$LIB_DIR/reply-summary.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
expect() { # name, expected total, Markdown
  local actual status=0
  actual="$(reply_summary_word_count "$3")" || status=$?
  if [[ "$status" == 0 && "$actual" == "$2" ]]; then
    ok "$1"
  else
    bad "$1 (got '$actual', exit $status; want '$2', exit 0)"
  fi
}
rules() { # Markdown -> "rule count" pairs of the structure report, space-joined
  reply_summary_structure "$1" | cut -f1,2 | tr '\t\n' '  ' | sed 's/ $//'
}
expect_structure() { # name, expected "rule count" pairs (empty: every limit holds), Markdown
  local actual status=0
  actual="$(rules "$3")" || status=$?
  if [[ "$status" == 0 && "$actual" == "$2" ]]; then
    ok "$1"
  else
    bad "$1 (got '$actual', exit $status; want '$2')"
  fi
}
timed() { # name, expected structure pairs, Markdown; generation is outside the interval.
  local start elapsed actual timed_status
  start="$(perl -MTime::HiRes=time -e 'print time')"
  # Bound the actual checker process, without replacing its code or input: a pending
  # alarm survives exec.
  actual="$(
    perl() { command perl -e 'alarm 10; exec "perl", @ARGV or exit 127' -- "$@"; }
    rules "$3"
  )" && timed_status=0 || timed_status=$?
  elapsed="$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' -- "$start")"
  if [[ "$timed_status" == 0 && "$actual" == "$2" ]]; then
    ok "$1"
  else
    bad "$1 (got '$actual', exit $timed_status; want '$2', exit 0)"
  fi
  if perl -e 'exit($ARGV[0] < 2 ? 0 : 1)' -- "$elapsed"; then
    ok "$1 within 2 s ($elapsed s)"
  else
    bad "$1 took $elapsed s (limit 2 s)"
  fi
}
words() { printf 'word %.0s' $(seq "$1"); }

echo 'Totals count every word, tables included'
expect piped          4 $'| a | b |\n| --- | --- |\n| 1 | 2 |'
expect unicode_words  4 $'| 中 | あ |\n| - | - |\n| 字 | ア |'
expect quoted_table   6 $'> | a | b |\n> | --- | --- |\n> | 1 | 2 |\n\nPlain text.'
expect prose          3 'One two three.'

echo 'Short-text threshold'
eighty="$(words 40)"$'\n\n'"$(words 40)"
status=0; reply_summary_is_short "$eighty" || status=$?
[[ "$status" == 0 ]] && ok short_80 || bad "short_80 (exit $status)"
status=0; reply_summary_is_short "$eighty"$'\n\nword' || status=$?
[[ "$status" == 1 ]] && ok long_81 || bad "long_81 (exit $status)"

echo 'Rule boundaries: the in-limit case passes, the next one breaks'
expect_structure prose_3      '' 'One. Two. Three.'
expect_structure prose_4      'prose 4' 'One. Two. Three. Four.'
expect_structure item_3       '' $'- One. Two. Three.\n- Next.'
expect_structure item_4       'item 4' $'- One. Two. Three. Four.\n- Next.'
expect_structure words_25     '' "$(words 24)word."
expect_structure words_26     'sentence 26' "$(words 25)word."
expect_structure items_1      'list 1' '- Only.'
expect_structure items_2      '' $'- One.\n- Two.'
expect_structure items_7      '' "$(printf -- '- Item.\n%.0s' {1..7})"
expect_structure items_8      'list 8' "$(printf -- '- Item.\n%.0s' {1..8})"
expect_structure loose_items  '' $'1. One.\n\n2. Two.'
expect_structure columns_1    'table 1' $'| a |\n| --- |\n| 1 |'
expect_structure columns_5    '' $'| a | b | c | d | e |\n|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 |'
expect_structure columns_6    'table 6' $'| a | b | c | d | e | f |\n|---|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 | 6 |'
expect_structure sub_items_2  '' $'- One.\n  - A.\n  - B.\n- Two.'
expect_structure sub_items_3  '' $'- One.\n  - A.\n  - B.\n  - C.\n- Two.'
expect_structure sub_items_1  'sublist 1' $'- One.\n  - Inner.\n- Two.'
expect_structure sub_items_4  'sublist 4' $'- One.\n  - A.\n  - B.\n  - C.\n  - D.\n- Two.'
expect_structure depth_3      '' $'- One.\n  - A.\n    - x.\n    - y.\n  - B.\n- Two.'
expect_structure depth_4      'depth 4' $'- One.\n  - A.\n    - x.\n      - deep.\n      - deeper.\n    - y.\n  - B.\n- Two.'
expect_structure sibling_back '' $'1. One.\n   - A.\n   - B.\n2. Two.\n   - C.\n   - D.'
expect_structure top_items_7  '' $'- One.\n  - A.\n  - B.\n- 2.\n- 3.\n- 4.\n- 5.\n- 6.\n- 7.'
expect_structure list_then_prose '' $'- One.\n- Two.\n\nAfter the list.'

echo 'Table recognition: tables are skipped, malformed delimiters remain prose'
# The header holds four sentences: a recognized table skips them, prose counts them.
head='One. Two. | Three. Four.'
expect_structure piped          '' $'| '"$head"$' |\n| --- | --- |\n| 1 | 2 |'
expect_structure pipeless       '' "$head"$'\n--- | ---\n1 | 2'
expect_structure leading_pipe   '' "$head"$'\n| --- | ---\n1 | 2'
expect_structure trailing_pipe  '' "$head"$'\n--- | --- |\n1 | 2'
expect_structure aligned        '' "$head | c"$'\n:- | :-: | -:\n1 | 2 | 3'
expect_structure tabs_and_cr    '' "$head"$'\n\t:-\t|\t-:\t\r\n1 | 2'
expect_structure unicode_spaces '' "$head"$'\n　:-　|　-:　\n1 | 2'
expect_structure escaped_pipe   '' $'| a\\|b. '"$head"$' |\n| --- | --- |\n| 1 | 2 |'
expect_structure suffix         'prose 4' "$head"$'\n---   x'
expect_structure column_count   'prose 5' "$head"$'\n| --- |\n1 | 2'
expect_structure empty_cell     'prose 4' "$head"$'\n--- || ---\n1 | 2'
expect_structure missing_hyphen 'prose 4' "$head"$'\n--- | :\n1 | 2'
expect_structure inner_space    'prose 4' "$head"$'\n: --- | ---\n1 | 2'
expect_structure extra_colon    'prose 4' "$head"$'\n::--- | ---\n1 | 2'

echo 'Masks: no false split or merge'
expect_structure no_false_split '' 'Bump to v1.2.3 now. Edit stop-gate.sh, e.g. 5 items, and see https://example.com/a.b?x=1 too. Mr. Smith, No. 3 and `a. b` agree.'
expect_structure bold_label     '' '**Fix.** One. Two.'
expect_structure no_false_merge 'prose 4' 'First one. #388 is next. 2 tests run. `make` runs last.'
expect_structure link_target    '' 'See [the guide](https://example.com/a.b. c). Done.'
expect_structure cjk_sentences  'prose 4' '它失败了。然后重试。再来一次。最后一次。'
expect_structure cjk_long       '' "$(printf '字%.0s' {1..40})。"
expect_structure html_comment   '' $'<!-- One. Two. Three. Four. -->\nDone.'

echo 'Skipped blocks are not counted'
four='One. Two. Three. Four.'
expect_structure fence          '' $'```\n'"$four"$'\n```'
expect_structure item_fence     'prose 4' $'- ```\n  '"$four"$'\n  ```\n- Two.\n\n'"$four"
expect_structure quote          '' "> $four"
expect_structure table_cells    '' $'| a | b |\n|---|---|\n| '"$four"' | '"$(words 30)"' |'
expect_structure heading        '' "## $(words 30)"
expect_structure summary_words  '' $'## TL;DR\n\n'"$(words 29)word."$'\n\n## Details\n\nDone.'
expect_structure details_words  'sentence 30' $'## TL;DR\n\nShort.\n\n## Details\n\n'"$(words 29)word."

echo 'Excerpts are cut by characters'
excerpt="$(reply_summary_structure "$(printf '它失败了。%.0s' {1..20})" | cut -f4)"
if perl -CSD -ne 'chomp; exit(length == 61 && /\x{2026}$/ ? 0 : 1)' <<<"$excerpt"; then
  ok cjk_excerpt
else
  bad "cjk_excerpt (got '$excerpt')"
fi

echo 'Limits match the boxlite-writing skill'
skill="$LIB_DIR/../skills/boxlite-writing/SKILL.md"
for phrase in "at most ${reply_summary_max_sentence_words} words" \
  "${reply_summary_min_list_items}–${reply_summary_max_list_items} items" \
  "sub-lists of ${reply_summary_min_sublist_items}–${reply_summary_max_sublist_items} items" \
  "at most ${reply_summary_max_list_depth} levels" \
  "${reply_summary_min_table_columns}–${reply_summary_max_table_columns} columns" \
  "up to three for connected reasoning" "or three for connected reasoning"; do
  if grep -qF -- "$phrase" "$skill"; then ok "skill says: $phrase"; else bad "skill lacks: $phrase"; fi
done
[[ "$reply_summary_max_sentences" == 3 ]] && ok 'three sentences' || bad "max sentences is $reply_summary_max_sentences"

echo 'Linear parsing: long whitespace runs and delimiter rows'
spaces="$(perl -e 'print " " x 200000')"
timed suffix_spaces    '' $'a | b\n---'"${spaces}x"
timed prefix_spaces    '' $'a | b\n'"${spaces}---x"
timed last_cell_spaces '' $'a | b\n--- | ---'"${spaces}x"
timed valid_suffix     '' $'a | b\n--- | ---'"$spaces"
timed many_cells       '' $'a | b\n'"$(perl -e 'print "-|" x 100000')x"
timed heading_spaces   '' "## a${spaces}b"
timed sentence_spaces  '' "One.${spaces}two"
timed long_sentence    'sentence 60000' "$(perl -e 'print "word " x 60000')."
timed open_brackets    '' "$(perl -e 'print "[" x 100000')"
timed close_runs       '' "$(perl -e 'print "](" x 50000')"
timed broken_links     '' "$(perl -e 'print "[a](" x 25000')"
timed star_rule        '' "$(perl -e 'print "*" x 100000')"

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
