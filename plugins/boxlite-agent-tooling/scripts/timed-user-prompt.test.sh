#!/usr/bin/env bash
# Test the public CLI with a deterministic clock; no real three-minute sleeps.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
expect() { jq -e "$2" <<<"$1" >/dev/null || { printf 'FAIL: %s\n' "$2" >&2; exit 1; }; }
reject() { if run "$@" >"$scratch/out" 2>"$scratch/err"; then printf 'FAIL: accepted %s\n' "$1" >&2; exit 1; fi; }

request="$(run request "$state" "$spec")"
id="$(jq -r .id <<<"$request")"
expect "$request" '.status == "pending" and .deadline == 1180'
printf '1100\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$state" "$spec")" ".id == \"$id\" and .deadline == 1180"
reject respond "$state" "$id" 'yes'
reject respond "$state" "$id" 'reviewed: '
reject respond "$state" "$id" $'reviewed: text\nextra'
expect "$(run status "$state" "$id")" '.status == "pending" and .deadline == 1180'
printf '1179\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run respond "$state" "$id" 'reviewed: verified the size boundary')" '.status == "accepted"'
printf '1181\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run status "$state" "$id")" '.status == "accepted"'
expect "$(run consume "$state" "$id")" '.status == "consumed"'
reject consume "$state" "$id"
request="$(run request "$state" "$spec")"
next_id="$(jq -r .id <<<"$request")"
[[ "$next_id" != "$id" ]]
reject respond "$state" "$id" 'reviewed: stale reply'
printf '1361\n' > "$CONFIRMATION_TEST_CLOCK"
reject respond "$state" "$next_id" 'reviewed: at the deadline'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1361'
expect "$(run fallback "$state" "$next_id")" '.fallback_delivered and .spec.fallback == "keep-draft"'
expect "$(run request "$state" "$spec")" '.status == "expired" and .deadline == 1361'

size_spec='{"binding":{"head":"second"},"prefix":"pr-size-exception:","fallback":"split","minimum_words":12}'
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
reject respond "$state" "$next_id" 'reviewed: superseded'
reject respond "$state" "$id" 'pr-size-exception: urgent'
reason='pr-size-exception: This dependency update regenerates 612 lockfile lines; splitting it from the manifest leaves the dependency graph inconsistent.'
expect "$(run respond "$state" "$id" "$reason")" '.status == "accepted" and .spec.fallback == "split"'
[[ "$(run status "$state" "$id" | jq -r .response)" == "$reason" ]]
printf '1\n' > "$CONFIRMATION_TEST_CLOCK"
reject status "$state" "$id"
printf '2000\n' > "$CONFIRMATION_TEST_CLOCK"

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
for mutation in '.status="accepted"' '.fallback_delivered=true' '.extra="unexpected"'; do
  jq "$mutation" <<<"$request" > "$scratch/state with spaces/bad-record"
  reject request "$scratch/state with spaces/bad-record" "$spec"
done
for index in 1 2 3 4; do
  run request "$scratch/state with spaces/concurrent" "$spec" >"$scratch/$index.json" &
done
wait
[[ "$(jq -sr '[.[].id] | unique | length' "$scratch/"[1-4].json)" == 1 ]]
expect "$(cat "$scratch/1.json")" '.deadline == 2180'
printf '2200\n' > "$CONFIRMATION_TEST_CLOCK"
expect "$(run request "$scratch/state with spaces/concurrent" "$spec")" '.status == "expired" and .deadline == 2180'
reject renew "$scratch/state with spaces/concurrent" "$(jq -r .id "$scratch/1.json")" 'Please request the exception again.'

state="$scratch/state with spaces/renewal.json"
request="$(run request "$state" "$size_spec")"
id="$(jq -r .id <<<"$request")"
instruction='Please request the size exception again.'
reject renew "$state" "$id" "$instruction"
run present "$state" "$id" native-question >/dev/null
printf '2380\n' > "$CONFIRMATION_TEST_CLOCK"
expired="$(run fallback "$state" "$id")"
expect "$(run request "$state" "$size_spec")" ".id == \"$id\" and .status == \"expired\" and .deadline == 2380"
reject renew "$state" "$id" ''
reject renew "$state" "$id" '   '
reject renew "$state" "$id" $'request again\nextra'
if ! renewed="$(run renew "$state" "$id" "$instruction")"; then
  printf 'FAIL: explicit human renewal could not reopen an expired PR-size attempt\n' >&2
  exit 1
fi
next_id="$(jq -r .id <<<"$renewed")"
[[ "$next_id" != "$id" ]]
expect "$renewed" '.status == "pending" and .created_at == 2380 and .deadline == 2560
  and .response == "" and .question_tool_id == "" and (.fallback_delivered | not)'
[[ "$(jq -c .spec <<<"$renewed")" == "$(jq -c .spec <<<"$expired")" ]]
archive="$state.expired-$id.json"
expect "$(cat "$archive")" ".request.id == \"$id\" and .request.status == \"expired\"
  and .user_request == \"$instruction\" and .successor_id == \"$next_id\" and .renewed_at == 2380"
[[ "$(jq -c .request "$archive")" == "$expired" ]]
reject respond "$state" "$id" "$reason"
reject native-reply "$state" "$id" '{"tool_use_id":"native-question","answer":"stale"}'
reject renew "$state" "$id" "$instruction"
expect "$(run request "$state" "$size_spec")" ".id == \"$next_id\" and .deadline == 2560"
expect "$(run respond "$state" "$next_id" "$reason")" '.status == "accepted"'
reject renew "$state" "$next_id" "$instruction"

for type in symlink fifo directory regular; do
  state="$scratch/state with spaces/renew-$type.json"
  request="$(run request "$state" "$size_spec")"
  id="$(jq -r .id <<<"$request")"
  jq '.created_at -= 181 | .deadline -= 181' "$state" > "$scratch/expired"
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
printf '2560\n' > "$CONFIRMATION_TEST_CLOCK"
for index in 1 2 3 4; do
  (if run renew "$state" "$id" "$instruction" >"$scratch/renew-$index.json" 2>"$scratch/renew-$index.err";
    then printf 'accepted\n'; else printf 'rejected\n'; fi) >"$scratch/result-$index" &
done
wait
[[ "$(cat "$scratch/"result-* | grep -c '^accepted$')" == 1 ]]
expect "$(cat "$state")" '.status == "pending" and .deadline == 2740'

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
  jq '.created_at -= 181 | .deadline -= 181' "$state" > "$scratch/expired"
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
    expect "$(cat "$state")" ".id == \"$successor\" and .deadline == 2740 and .status == \"pending\" and .response == \"\""
  fi
  before="$(cat "$state")"
  archived="$(cat "$archive")"
  reject renew "$state" "$id" "$instruction"
  if [[ "$phase" == before ]]; then
    [[ "$(cat "$scratch/err")" == *'inspect any existing archive before retrying'* ]]
  fi
  [[ "$(cat "$state")" == "$before" && "$(cat "$archive")" == "$archived" ]]
done
printf 'timed-user-prompt: all lifecycle, deadline, unsafe-state, and concurrency checks passed\n'
