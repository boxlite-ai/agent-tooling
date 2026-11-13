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
spec='{"binding":{"head":"first"},"prefix":"reviewed:","fallback":"keep-draft"}'
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
for host in claude codex; do
  instruction="$(BOXLITE_HOOK_HOST="$host" BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1 \
    CLAUDE_AFK_TIMEOUT_MS=300000 bash -c '
      source "$1/.agents/lib/user-question.sh"
      user_question instruction "$1" "$2"
    ' fixture "$plugin" "$request")"
  [[ "$instruction" == *"plain text"* && "$instruction" == *"reviewed:"* \
     && "$instruction" == *"1300"* && "$instruction" != *AskUserQuestion* \
     && "$instruction" != *request_user_input_async* ]] || {
    printf 'FAIL: %s must use one timed text question\n' "$host" >&2
    exit 1
  }
done
printf '1100\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$state" "$spec")" ".id == \"$id\" and .deadline == 1300"
reject respond "$state" "$id" 'yes'
reject_hook prompt-reply "$state" "$id" 'Bypass limit'
reject_hook prompt-reply "$state" "$id" 'Split PR'
reject_hook prompt-reply "$state" "$id" "reviewed: $id "
reject_hook prompt-reply "$state" "$id" "$(printf 'reviewed: %s text\nextra' "$id")"
printf '1181\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "pending" and .deadline == 1300'
printf '1299\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(hook_run prompt-reply "$state" "$id" "reviewed: $id verified the size boundary")" '.status == "accepted"'
printf '1301\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "accepted"'
expect "$(run consume "$state" "$id")" '.status == "consumed"'
reject consume "$state" "$id"
request="$(run request "$state" "$spec")"
next_id="$(jq -r .id <<<"$request")"
[[ "$next_id" != "$id" ]]
reject_hook prompt-reply "$state" "$id" "reviewed: $id stale reply"
printf '1601\n' > "$CONFIRMATION_TEST_CLOCK"
reject_hook prompt-reply "$state" "$next_id" "reviewed: $next_id at the deadline"
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1601'
expect "$(run fallback "$state" "$next_id")" '.fallback_delivered and .spec.fallback == "keep-draft"'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1601'

size_spec='{"binding":{"head":"second"},"prefix":"pr-size-exception:","fallback":"split"}'
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
reject_hook prompt-reply "$state" "$next_id" "reviewed: $next_id superseded"
reject_hook prompt-reply "$state" "$id" "pr-size-exception: $id urgent"
reason="pr-size-exception: $id Bypass limit"
expect "$(hook_run prompt-reply "$state" "$id" "$reason")" '.status == "accepted" and .spec.fallback == "split"'
[[ "$(run status "$state" "$id" | jq -r .response)" == "$reason" ]]
printf '1\n' > "$CONFIRMATION_TEST_CLOCK"
reject status "$state" "$id"
printf '2000\n' > "$CONFIRMATION_TEST_CLOCK"

choice_state="$scratch/state with spaces/choice.json"
request="$(run request "$choice_state" "$size_spec")"
choice_id="$(jq -r .id <<<"$request")"
split="pr-size-exception: $choice_id Split PR"
expect "$(hook_run prompt-reply "$choice_state" "$choice_id" "$split")" '.status == "declined"'
expect "$(run request "$choice_state" "$size_spec")" ".id == \"$choice_id\" and .status == \"declined\""
reject consume "$choice_state" "$choice_id"
reject_hook prompt-reply "$choice_state" "$choice_id" "pr-size-exception: $choice_id Bypass limit"
expect "$(run fallback "$choice_state" "$choice_id")" '.fallback_delivered and .status == "declined"'
request="$(run renew "$choice_state" "$choice_id" 'Ask me again.')"
expect "$(cat "$choice_state.expired-$choice_id.json")" '.request.status == "declined"'
choice_id="$(jq -r .id <<<"$request")"
expect "$(hook_run prompt-reply "$choice_state" "$choice_id" "pr-size-exception: $choice_id Bypass limit")" '.status == "accepted"'
reject_hook prompt-reply "$choice_state" "$choice_id" "pr-size-exception: $choice_id Bypass limit"
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
expect "$(run renew "$scratch/state with spaces/concurrent" "$(jq -r .id "$scratch/1.json")" \
  'Please renew the review request.')" '.status == "pending" and .deadline == 2700 and .accepted_at == null'

state="$scratch/state with spaces/renewal.json"
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
instruction='Please request the size exception again.'
reject renew "$state" "$id" "$instruction"
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
  and .response == "" and .accepted_at == null and (.fallback_delivered | not)'
[[ "$(jq -c .spec <<<"$renewed")" == "$(jq -c .spec <<<"$expired")" ]]
archive="$state.expired-$id.json"
expect "$(cat "$archive")" ".request.id == \"$id\" and .request.status == \"expired\"
  and .user_request == \"$instruction\" and .successor_id == \"$next_id\" and .renewed_at == 2700"
[[ "$(jq -c .request "$archive")" == "$expired" ]]
reject_hook prompt-reply "$state" "$next_id" "pr-size-exception: $id Bypass limit"
reject renew "$state" "$id" "$instruction"
expect "$(run request "$state" "$size_spec")" ".id == \"$next_id\" and .deadline == 3000"
expect "$(hook_run prompt-reply "$state" "$next_id" "pr-size-exception: $next_id Bypass limit")" '.status == "accepted"'
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
cp "$plugin/.agents/lib/user-question-policy.jq" "$fault_plugin/.agents/lib/"
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

# Unsupported records block without granting authority, applying fallback, or changing bytes.
printf '4000\n' > "$CONFIRMATION_TEST_CLOCK"
state="$scratch/state with spaces/unsupported"
for deadline in 4180 4300; do
  request="$(run request "$state" "$spec")"
  id="$(jq -r .id <<<"$request")"
  jq --argjson deadline "$deadline" '
    del(.accepted_at) | .version=1 | .deadline=$deadline | .question_tool_id=""
    | .status="accepted" | .response="reviewed: older reply"
    | .spec.minimum_words=1' <<<"$request" > "$state"
  cp "$state" "$scratch/before"
  reject request "$state" "$spec"
  grep -Fq "unsupported request at $state" "$scratch/err"
  reject consume "$state" "$id"
  reject fallback "$state" "$id"
  reject_hook prompt-reply "$state" "$id" "reviewed: $id old request"
  cmp "$state" "$scratch/before"
  rm "$state"
done
reject respond "$state" "$id" 'reviewed: old relay'
reject question "$state" "$id"

# Review acceptance is immutable, expires at the freshness boundary, and can be spent once.
printf '4500\n' > "$CONFIRMATION_TEST_CLOCK"
for age in 600 601; do
  state="$scratch/state with spaces/review-$age"
  printf '4500\n' > "$CONFIRMATION_TEST_CLOCK"
  id="$(run request "$state" "$spec" | jq -r .id)"
  expect "$(hook_run prompt-reply "$state" "$id" "reviewed: $id checked")" '.accepted_at == 4500'
  printf '%s\n' "$((4500 + age))" > "$CONFIRMATION_TEST_CLOCK"
  reject_hook prompt-reply "$state" "$id" "reviewed: $id checked"
  if [[ "$age" == 600 ]]; then
    expect "$(run consume "$state" "$id")" '.status == "consumed" and .accepted_at == 4500'
    reject consume "$state" "$id"
  else
    reject consume "$state" "$id"
    expect "$(run status "$state" "$id")" '.status == "expired" and .accepted_at == null'
  fi
done

# The deadline ends the agent wait. An explicit matching design reply can still count.
printf '6000\n' > "$CONFIRMATION_TEST_CLOCK"
research_state="$scratch/state with spaces/research.json"
research_spec='{"binding":{"head":"fifth"},"prefix":"design-decision:","fallback":"keep-blocked"}'
reject request "$research_state" "$(jq -c '.fallback = "keep-draft"' <<<"$research_spec")"
reject request "$research_state" "$(jq -c '.prefix = "reviewed:"' <<<"$research_spec")"
id="$(run request "$research_state" "$research_spec" | jq -r .id)"
reject prompt-reply "$research_state" "$id" "design-decision: $id Overrule the gaps are acceptable"
reject_hook prompt-reply "$research_state" "$id" 'Overrule'
reject_hook prompt-reply "$research_state" "$id" "design-decision: $id Overrule"
reject_hook prompt-reply "$research_state" "$id" "design-decision: $id Approve it"
expect "$(run status "$research_state" "$id")" '.status == "pending"'
printf '6301\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run fallback "$research_state" "$id")" '.fallback_delivered and .spec.fallback == "keep-blocked"'
reject renew "$research_state" "$id" 'ask me again'
expect "$(hook_run prompt-reply "$research_state" "$id" "design-decision: $id Redesign start from the findings")" \
  '.status == "accepted" and (.fallback_delivered | not)'
reject_hook prompt-reply "$research_state" "$id" "design-decision: $id Overrule twice is not allowed"
expect "$(run consume "$research_state" "$id")" '.status == "consumed"'
printf 'timed-user-prompt: lifecycle, deadlines, unsupported state, design, and concurrency passed\n'
