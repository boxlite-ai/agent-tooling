#!/usr/bin/env bash
# Test the public CLI with a deterministic clock; no real five-minute sleeps.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cli="$plugin/scripts/timed-user-prompt.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/state with spaces"
export CONFIRMATION_TEST_CLOCK="$scratch/clock"
printf '1000\n' > "$CONFIRMATION_TEST_CLOCK"
cat > "$scratch/bin/date" <<'CLOCK'
#!/usr/bin/env bash
cat "$CONFIRMATION_TEST_CLOCK"
CLOCK
chmod +x "$scratch/bin/date"
export PATH="$scratch/bin:$PATH"
state="$scratch/state with spaces/request.json"
spec='{"binding":{"head":"first"},"prefix":"reviewed:","fallback":"keep-draft","minimum_words":1}'
run() { bash "$cli" "$@"; }
# Hooks call the library directly; the CLI exposes only the agent operations.
hook_run() {
  bash -c 'source "$1/.agents/lib/verdict-audit-state.sh" && source "$1/.agents/lib/timed-user-prompt.sh" \
    && shift && timed_user_prompt "$@"' hook "$plugin" "$@"
}
expect() { jq -e "$2" <<<"$1" >/dev/null || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; }
reject() { if run "$@" >"$scratch/out" 2>"$scratch/err"; then printf 'FAIL: accepted %s\n' "$1" >&2; exit 1; fi; }
reject_hook() { if hook_run "$@" >"$scratch/out" 2>"$scratch/err"; then printf 'FAIL: hook accepted %s %s\n' "$1" "${4:-}" >&2; exit 1; fi; }

request="$(run request "$state" "$spec")"
id="$(jq -r .id <<<"$request")"
expect "$request" '.status == "pending" and .deadline == 1300'
printf '1100\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$state" "$spec")" ".id == \"$id\" and .deadline == 1300"
reject respond "$state" "$id" 'yes'
reject respond "$state" "$id" 'Bypass limit'
reject respond "$state" "$id" 'Split PR'
reject respond "$state" "$id" 'reviewed: '
reject respond "$state" "$id" $'reviewed: text\nextra'
printf '1181\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "pending" and .deadline == 1300'
printf '1299\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run respond "$state" "$id" 'reviewed: verified the size boundary')" '.status == "accepted"'
printf '1301\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "accepted"'
expect "$(run consume "$state" "$id")" '.status == "consumed"'
reject consume "$state" "$id"
request="$(run request "$state" "$spec")"
next_id="$(jq -r .id <<<"$request")"
[[ "$next_id" != "$id" ]]
reject respond "$state" "$id" 'reviewed: stale reply'
printf '1601\n' > "$CONFIRMATION_TEST_CLOCK"
reject respond "$state" "$next_id" 'reviewed: at the deadline'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1601'
expect "$(run fallback "$state" "$next_id")" '.fallback_delivered and .spec.fallback == "keep-draft"'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1601'

size_spec='{"binding":{"head":"second"},"prefix":"pr-size-exception:","fallback":"split","minimum_words":12}'
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
reject respond "$state" "$next_id" 'reviewed: superseded'
reject respond "$state" "$id" 'pr-size-exception: urgent'
reason='pr-size-exception: This protocol update regenerates 612 binding-code lines; splitting the schema from generated bindings leaves incompatible interfaces.'
expect "$(run respond "$state" "$id" "$reason")" '.status == "accepted" and .spec.fallback == "split"'
[[ "$(run status "$state" "$id" | jq -r .response)" == "$reason" ]]
printf '1\n' > "$CONFIRMATION_TEST_CLOCK"
reject status "$state" "$id"
printf '2000\n' > "$CONFIRMATION_TEST_CLOCK"

choice_state="$scratch/state with spaces/choice.json"
request="$(run request "$choice_state" "$size_spec")"
choice_id="$(jq -r .id <<<"$request")"
question="$(run question "$choice_state" "$choice_id")"
expect "$question" '[.questions[0].options[].label] == ["Bypass limit","Split PR"]'
expect "$(run respond "$choice_state" "$choice_id" 'Split PR')" '.status == "declined" and .response == "Split PR"'
expect "$(run request "$choice_state" "$size_spec")" ".id == \"$choice_id\" and .status == \"declined\""
reject consume "$choice_state" "$choice_id"
reject respond "$choice_state" "$choice_id" 'Bypass limit'
expect "$(run fallback "$choice_state" "$choice_id")" '.fallback_delivered and .status == "declined"'
request="$(run renew "$choice_state" "$choice_id" 'Ask me again.')"
expect "$(cat "$choice_state.expired-$choice_id.json")" '.request.status == "declined" and .request.response == "Split PR"'
choice_id="$(jq -r .id <<<"$request")"
expect "$(run respond "$choice_state" "$choice_id" 'Bypass limit')" '.status == "accepted" and .response == "Bypass limit"'
reject respond "$choice_state" "$choice_id" 'Bypass limit'
expect "$(run status "$choice_state" "$choice_id")" '.status == "accepted"'

for type in symlink fifo directory malformed; do
  unsafe="$scratch/state with spaces/$type"
  case "$type" in
    symlink) ln -s "$state" "$unsafe" ;;
    fifo) mkfifo "$unsafe" ;;
    directory) mkdir "$unsafe" ;;
    malformed) printf '{}\n' > "$unsafe" ;;
  esac
  reject request "$unsafe" "$spec"
done
reject request "$scratch/state with spaces/invalid" '{}'
request="$(run request "$scratch/state with spaces/valid-record" "$spec")"
for mutation in '.status="accepted"' '.fallback_delivered=true' '.extra="unexpected"' '.deadline += 1'; do
  jq "$mutation" <<<"$request" > "$scratch/state with spaces/bad-record"
  reject request "$scratch/state with spaces/bad-record" "$spec"
done
for index in 1 2 3 4; do
  run request "$scratch/state with spaces/concurrent" "$spec" >"$scratch/$index.json" &
done
wait
[[ "$(jq -sr '[.[].id] | unique | length' "$scratch/"[1-4].json)" == 1 ]]
expect "$(cat "$scratch/1.json")" '.deadline == 2300'
printf '2400\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$scratch/state with spaces/concurrent" "$spec")" '.status == "expired" and .deadline == 2300'
reject renew "$scratch/state with spaces/concurrent" "$(jq -r .id "$scratch/1.json")" 'Please request the exception again.'

state="$scratch/state with spaces/renewal.json"
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
instruction='Please request the size exception again.'
reject renew "$state" "$id" "$instruction"
reject present "$state" "$id" native-question
hook_run present "$state" "$id" native-question >/dev/null
printf '2700\n' > "$CONFIRMATION_TEST_CLOCK"
expired="$(run fallback "$state" "$id")"
expect "$(run request "$state" "$size_spec")" ".id == \"$id\" and .status == \"expired\" and .deadline == 2700"
reject renew "$state" "$id" ''
reject renew "$state" "$id" '   '
reject renew "$state" "$id" $'request again\nextra'
if ! renewed="$(run renew "$state" "$id" "$instruction")"; then
  printf 'FAIL: explicit human renewal could not reopen an expired PR-size attempt\n' >&2
  exit 1
fi
next_id="$(jq -r .id <<<"$renewed")"
[[ "$next_id" != "$id" ]]
expect "$renewed" '.status == "pending" and .created_at == 2700 and .deadline == 3000
  and .response == "" and .question_tool_id == "" and (.fallback_delivered | not)'
[[ "$(jq -c .spec <<<"$renewed")" == "$(jq -c .spec <<<"$expired")" ]]
archive="$state.expired-$id.json"
expect "$(cat "$archive")" ".request.id == \"$id\" and .request.status == \"expired\"
  and .user_request == \"$instruction\" and .successor_id == \"$next_id\" and .renewed_at == 2700"
[[ "$(jq -c .request "$archive")" == "$expired" ]]
reject respond "$state" "$id" "$reason"
reject_hook native-reply "$state" "$id" '{"tool_use_id":"native-question","answer":"stale"}'
reject renew "$state" "$id" "$instruction"
expect "$(run request "$state" "$size_spec")" ".id == \"$next_id\" and .deadline == 3000"
expect "$(run respond "$state" "$next_id" "$reason")" '.status == "accepted"'
reject renew "$state" "$next_id" "$instruction"

for type in symlink fifo directory regular; do
  state="$scratch/state with spaces/renew-$type.json"
  request="$(run request "$state" "$size_spec")"
  id="$(jq -r .id <<<"$request")"
  jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
  mv "$scratch/expired" "$state"
  archive="$state.expired-$id.json"
  case "$type" in
    symlink) ln -s "$scratch/1.json" "$archive" ;;
    fifo) mkfifo "$archive" ;;
    directory) mkdir "$archive" ;;
    regular) printf 'existing archive\n' > "$archive" ;;
  esac
  before="$(cat "$state")"
  reject renew "$state" "$id" "$instruction"
  [[ "$(cat "$state")" == "$before" ]]
done

state="$scratch/state with spaces/renew-concurrent.json"
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
printf '3000\n' > "$CONFIRMATION_TEST_CLOCK"
for index in 1 2 3 4; do
  (if run renew "$state" "$id" "$instruction" >"$scratch/renew-$index.json" 2>"$scratch/renew-$index.err";
    then printf 'accepted\n'; else printf 'rejected\n'; fi) >"$scratch/result-$index" &
done
wait
[[ "$(cat "$scratch/"result-* | grep -c '^accepted$')" == 1 ]]
expect "$(cat "$state")" '.status == "pending" and .deadline == 3300'

# Inject storage faults through a fixture copy of the public CLI and its library.
fault_plugin="$scratch/fault-plugin"
mkdir -p "$fault_plugin/scripts" "$fault_plugin/.agents/lib"
cp "$cli" "$fault_plugin/scripts/"
cp "$plugin/.agents/lib/"{timed-user-prompt,verdict-audit-state}.sh "$fault_plugin/.agents/lib/"
cat >> "$fault_plugin/.agents/lib/verdict-audit-state.sh" <<'FAULT'
verdict_audit_write_atomic() {
  [[ "$CONFIRMATION_WRITE_FAULT" != before ]] || return 1
  verdict_audit_write_atomic_identity "$1" >/dev/null || return 1
  return 1 # Simulate losing the result after the authoritative write committed.
}
FAULT
for phase in before after; do
  state="$scratch/state with spaces/fault-$phase.json"
  request="$(run request "$state" "$size_spec")"
  id="$(jq -r .id <<<"$request")"
  jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
  mv "$scratch/expired" "$state"
  if CONFIRMATION_WRITE_FAULT="$phase" bash "$fault_plugin/scripts/timed-user-prompt.sh" \
      renew "$state" "$id" "$instruction" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: renewal hid a publication failure\n' >&2; exit 1
  fi
  archive="$state.expired-$id.json"
  [[ -s "$archive" && ! -s "$scratch/out" ]]
  if [[ "$phase" == before ]]; then
    expect "$(cat "$state")" ".id == \"$id\""
  else
    successor="$(jq -r .successor_id "$archive")"
    expect "$(cat "$state")" ".id == \"$successor\" and .deadline == 3300 and .status == \"pending\" and .response == \"\""
  fi
  before="$(cat "$state")"
  archived="$(cat "$archive")"
  reject renew "$state" "$id" "$instruction"
  if [[ "$phase" == before ]]; then
    [[ "$(cat "$scratch/err")" == *'inspect any existing archive before retrying'* ]]
  fi
  [[ "$(cat "$state")" == "$before" && "$(cat "$archive")" == "$archived" ]]
done

# Existing three-minute records retain their original window across an upgrade.
printf '4000\n' > "$CONFIRMATION_TEST_CLOCK"
for legacy_spec in "$spec" "$size_spec"; do
  state="$scratch/state with spaces/legacy-$(jq -r .fallback <<<"$legacy_spec").json"
  run request "$state" "$legacy_spec" | jq '.deadline = .created_at + 180 | del(.question_tool_id)' > "$scratch/legacy"
  mv "$scratch/legacy" "$state"
  id="$(jq -r .id "$state")"
  expect "$(run request "$state" "$legacy_spec")" ".id == \"$id\" and .deadline == 4180 and .status == \"pending\""
done
printf '4179\n' > "$CONFIRMATION_TEST_CLOCK"
state="$scratch/state with spaces/legacy-keep-draft.json"
expect "$(run respond "$state" "$(jq -r .id "$state")" 'reviewed: existing request')" '.status == "accepted"'
printf '4180\n' > "$CONFIRMATION_TEST_CLOCK"
state="$scratch/state with spaces/legacy-split.json"
id="$(jq -r .id "$state")"
reject respond "$state" "$id" "$reason"
expect "$(run request "$state" "$size_spec")" ".id == \"$id\" and .deadline == 4180 and .status == \"expired\""
expect "$(run renew "$state" "$id" "$instruction")" '.created_at == 4180 and .deadline == 4480 and .status == "pending"'

# Design decisions (design #309): only the human records one, through the managed
# question's hook or a typed prompt line; relayed CLI text never counts.
printf '5000\n' > "$CONFIRMATION_TEST_CLOCK"
research_state="$scratch/state with spaces/research.json"
research_spec='{"binding":{"head":"fifth"},"prefix":"design-decision:","fallback":"keep-blocked","minimum_words":1}'
reject request "$research_state" "$(jq -c '.fallback = "keep-draft"' <<<"$research_spec")"
reject request "$research_state" "$(jq -c '.prefix = "reviewed:"' <<<"$research_spec")"
id="$(run request "$research_state" "$research_spec" | jq -r .id)"
expect "$(run question "$research_state" "$id")" \
  '[.questions[0].options[].label] == ["Redesign","Reflect again","Overrule"]'
reject respond "$research_state" "$id" 'Overrule'
reject respond "$research_state" "$id" 'design-decision: Overrule the gaps are acceptable'
reject prompt-reply "$research_state" "$id" 'design-decision: Overrule the gaps are acceptable'
reject_hook prompt-reply "$research_state" "$id" 'Overrule'
reject_hook prompt-reply "$research_state" "$id" 'design-decision: Overrule'
reject_hook prompt-reply "$research_state" "$id" 'design-decision: Approve it'
expect "$(run status "$research_state" "$id")" '.status == "pending"'
expect "$(hook_run prompt-reply "$research_state" "$id" 'design-decision: Overrule the gaps are acceptable')" \
  '.status == "accepted" and .response == "design-decision: Overrule the gaps are acceptable"'
expect "$(run consume "$research_state" "$id")" '.status == "consumed"'
id="$(run request "$research_state" "$research_spec" | jq -r .id)"
hook_run present "$research_state" "$id" research-question >/dev/null
reject_hook native-reply "$research_state" "$id" '{"tool_use_id":"research-question","answer":"Approve"}'
expect "$(hook_run native-reply "$research_state" "$id" '{"tool_use_id":"research-question","answer":"Reflect again"}')" \
  '.status == "accepted" and .response == "Reflect again"'
expect "$(run consume "$research_state" "$id")" '.status == "consumed"'
# The deadline ends the agent wait, not the human's say: a late typed line still counts.
id="$(run request "$research_state" "$research_spec" | jq -r .id)"
printf '5301\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$research_state" "$research_spec")" ".id == \"$id\" and .status == \"expired\""
expect "$(run fallback "$research_state" "$id")" '.fallback_delivered and .spec.fallback == "keep-blocked"'
reject renew "$research_state" "$id" 'ask me again'
expect "$(hook_run prompt-reply "$research_state" "$id" 'design-decision: Redesign start from the findings')" \
  '.status == "accepted" and (.fallback_delivered | not)'
reject_hook prompt-reply "$research_state" "$id" 'design-decision: Overrule twice is not allowed'
size_state="$scratch/state with spaces/research-size.json"
id="$(run request "$size_state" "$size_spec" | jq -r .id)"
reject_hook prompt-reply "$size_state" "$id" 'design-decision: Overrule not for size requests'
printf 'timed-user-prompt: all lifecycle, deadline, legacy-state, unsafe-state, design-decision, and concurrency checks passed\n'
