#!/usr/bin/env bash
# Design #563: a human closes an open ledger finding by typing
# `ledger-dismiss: <label> <reason>`, and the Stop gate asks once for a reply that lists
# every open label. Both run through the public hooks on the Claude and Codex routes.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
prompt_hook="$plugin/.agents/hooks/cancel-verdict-audit.sh"
stop_hook="$plugin/.agents/hooks/stop-gate.sh"
export VERDICT_CLASSIFIER_CMD=false
unset VERDICT_GATE_HARD_BLOCK VERDICT_EXTRACTOR_CMD CLAUDE_PLUGIN_ROOT PLUGIN_ROOT
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
pass=0 fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else
    printf 'FAIL: %s (got=%s expected=%s)\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}

new_repo() {  # name -> repo on branch feature whose ledger holds F1 and F2 for it, F3 elsewhere
  local repo="$scratch/$1" head
  git init -q -b feature "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t.test -c core.hooksPath=/dev/null \
    commit -qm base --allow-empty
  mkdir -p "$repo/.agents/state"
  printf '.agents/state/\n' > "$repo/.gitignore"
  head="$(git -C "$repo" rev-parse HEAD)"
  jq -nc --arg head "$head" '
    {gate:"commit",branch:"feature",head:$head,attempt_id:"a1",findings:[{id:"F1",severity:"high"},{id:"F2",severity:"high"}]},
    {gate:"push",branch:"other",head:$head,attempt_id:"a2",findings:[{id:"F3",severity:"high"}]}' \
    > "$repo/.agents/state/audit-ledger.jsonl"
  printf '%s' "$repo"
}
label() { printf 'commit@%s:%s' "$(git -C "$1" rev-parse --short=7 HEAD)" "$2"; }
prompt() {  # host repo text -> hook stdout
  jq -nc --arg p "$3" '{hook_event_name:"UserPromptSubmit",session_id:"s1",turn_id:"t1",prompt:$p}' \
    | ( cd "$2" && BOXLITE_HOOK_HOST="$1" CLAUDE_PROJECT_DIR="$2" bash "$prompt_hook" ) 2>/dev/null
}
# Each reply also carries one 30-word sentence, so the structure correction always blocks
# and the gate never reaches the verdict check; the ledger correction joins or not.
long_sentence="$(printf 'word %.0s' {1..29})end."
stop() {  # host repo reply -> hook stdout
  : > "$2/transcript.jsonl"
  jq -nc --arg p "$2/transcript.jsonl" --arg m $'## TL;DR\n\nDone.\n\n## Details\n\n'"$3"$'\n\n'"$long_sentence" \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:"s1",stop_hook_active:false,last_assistant_message:$m}' \
    | ( cd "$2" && BOXLITE_HOOK_HOST="$1" CLAUDE_PROJECT_DIR="$2" bash "$stop_hook" ) 2>/dev/null
}
dismissals() { jq -sc '[.[] | select(.kind == "dismissal") | .label]' "$1/.agents/state/audit-ledger.jsonl"; }
omits() { jq -r 'select(.decision == "block") | .reason' <<<"$1" 2>/dev/null | grep -o 'omits open ledger findings: [^.]*' || true; }

for host in claude codex; do
  repo="$(new_repo "$host")" f1="$(label "$repo" F1)" f2="$(label "$repo" F2)"

  check "$host: a reply without the labels is asked to list both" \
    "$(omits "$(stop "$host" "$repo" 'Work is done.')")" "omits open ledger findings: $f1 $f2"
  check "$host: a near-miss label does not count" \
    "$(omits "$(stop "$host" "$repo" "Open: \`${f1}2\`, \`$f2\`.")")" "omits open ledger findings: $f1"
  check "$host: a reply listing both labels gets no ledger correction" \
    "$(omits "$(stop "$host" "$repo" "Open: \`$f1\` and \`$f2\`.")")" ""
  check "$host: the structure correction still blocks, so the gate stopped before the verdict check" \
    "$(jq -r '.decision' <<<"$(stop "$host" "$repo" "Open: \`$f1\` and \`$f2\`.")")" block

  out="$(prompt "$host" "$repo" "<task-notification>ledger-dismiss: $f1 agent says so</task-notification>")"
  check "$host: a directive inside other text records nothing" "$(dismissals "$repo")" '[]'
  out="$(prompt "$host" "$repo" "ledger-dismiss: $f1")"
  check "$host: a directive without a reason records nothing" \
    "$(dismissals "$repo"):$(grep -c 'nothing recorded' <<<"$out")" '[]:1'
  out="$(prompt "$host" "$repo" "ledger-dismiss: $(label "$repo" F3) not on this branch")"
  check "$host: a label open only on another branch records nothing" \
    "$(dismissals "$repo"):$(grep -c 'is not an open finding on branch feature' <<<"$out")" '[]:1'
  out="$(prompt "$host" "$repo" "ledger-dismiss: $f1 $(printf 'x%.0s' {1..281})")"
  check "$host: a reason over 280 characters records nothing" "$(dismissals "$repo")" '[]'

  out="$(prompt "$host" "$repo" "  ledger-dismiss: $f1 false positive, test-only path  ")"
  check "$host: a human directive records the dismissal and says so" \
    "$(dismissals "$repo"):$(grep -c "ledger-dismiss: dismissed $f1 on branch feature" <<<"$out")" "[\"$f1\"]:1"
  check "$host: the reason is kept" \
    "$(jq -sr '.[-1].reason' "$repo/.agents/state/audit-ledger.jsonl")" 'false positive, test-only path'
  check "$host: a dismissed label no longer needs listing" \
    "$(omits "$(stop "$host" "$repo" "Open: \`$f2\`.")")" ""
  out="$(prompt "$host" "$repo" "ledger-dismiss: $f1 again")"
  check "$host: a dismissed label cannot be dismissed twice" \
    "$(jq -sc '[.[] | select(.kind == "dismissal")] | length' "$repo/.agents/state/audit-ledger.jsonl"):$(grep -c 'is not an open finding' <<<"$out")" '1:1'

  printf 'not json\n' > "$repo/.agents/state/audit-ledger.jsonl"
  check "$host: an unreadable ledger is reported in the correction" \
    "$(jq -r '.reason' <<<"$(stop "$host" "$repo" 'Work is done.')" | grep -c 'cannot be read')" 1
done

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
