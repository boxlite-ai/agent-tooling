#!/usr/bin/env bash
# Exercise review renewal through the public CLI and both host prompt routes.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin/tests/lib/assert.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
export PR_RENEWAL_CLOCK="$scratch/clock"
cat > "$scratch/bin/date" <<'CLOCK'
#!/usr/bin/env bash
cat "$PR_RENEWAL_CLOCK"
CLOCK
chmod +x "$scratch/bin/date"
export PATH="$scratch/bin:$PATH"
cd -P "$scratch/repo"
git init -q -b fixture
git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
cli="$plugin/scripts/timed-user-prompt.sh"
state="$PWD/.agents/state/pr-review-request.json"
instruction='Please renew the review request.'
run() { bash "$cli" "$@"; }
expect() {
  if jq -e "$2" <<<"$1" >/dev/null; then ok "$3"; else bad "$3"; assert_result; fi
}
reject() {
  if run "$@" >"$scratch/out" 2>"$scratch/err"; then
    bad "rejected $1"; assert_result
  fi
  ok "rejected $1"
}
submit() {
  jq -nc --arg prompt "$1" --arg session "${2:-operator}" --arg cwd "$PWD" \
    '{hook_event_name:"UserPromptSubmit",session_id:$session,prompt:$prompt,cwd:$cwd}' \
    | BOXLITE_HOOK_HOST="$host" CLAUDE_PROJECT_DIR="$PWD" \
      bash "$plugin/.agents/hooks/cancel-verdict-audit.sh" >"$scratch/reply"
}
for host in claude codex; do
  rm -f "$state"
  printf '1000\n' > "$PR_RENEWAL_CLOCK"
  spec="$(jq -nc --arg root "$PWD" --arg head "$(git rev-parse HEAD)" \
    '{prefix:"reviewed:",fallback:"keep-draft",
      binding:{root:$root,branch:"fixture",head:$head,session:"operator"}}')"
  original="$(run request "$state" "$spec")"
  old_id="$(jq -r .id <<<"$original")"
  reject renew "$state" "$old_id" "$instruction"
  printf '1300\n' > "$PR_RENEWAL_CLOCK"
  expired="$(run fallback "$state" "$old_id")"
  reject renew "$state" "$old_id" ''
  reject renew "$state" "$old_id" '   '
  reject renew "$state" "$old_id" $'renew\nextra'
  if ! renewed="$(run renew "$state" "$old_id" "$instruction" 2>"$scratch/err")"; then
    bad "$host expired review can be explicitly renewed" "$(cat "$scratch/err")"
    assert_result
  fi
  id="$(jq -r .id <<<"$renewed")"
  expect "$renewed" ".id != \"$old_id\" and .status == \"pending\" and .deadline == 1600
    and .created_at == 1300 and .accepted_at == null and .response == \"\" and (.fallback_delivered | not)" \
    "$host renewal creates an unapproved replacement"
  check_eq "$host binding preserved" "$(jq -c .spec <<<"$renewed")" "$(jq -c .spec <<<"$expired")"
  archive="$state.expired-$old_id.json"
  check_eq "$host expired record preserved" "$(jq -c .request "$archive")" "$expired"
  expect "$(cat "$archive")" ".successor_id == \"$id\" and .renewed_at == 1300
    and .user_request == \"$instruction\"" "$host archive links the successor and instruction"
  reject renew "$state" "$old_id" "$instruction"
  reject renew "$state" "$id" "$instruction"
  reject consume "$state" "$id"
  expect "$(run request "$state" "$spec")" ".id == \"$id\" and .deadline == 1600" \
    "$host ordinary retry does not renew"
  submit "reviewed: $old_id checked the old request"
  submit "reviewed: $id checked the replacement" wrong-session
  expect "$(cat "$state")" '.status == "pending" and .response == ""' "$host stale and foreign replies grant nothing"
  printf '1599\n' > "$PR_RENEWAL_CLOCK"
  submit "reviewed: $id checked the replacement"
  expect "$(cat "$state")" '.status == "accepted" and .accepted_at == 1599' "$host fresh timely reply accepted"
  reject renew "$state" "$id" "$instruction"
  expect "$(run consume "$state" "$id")" '.status == "consumed"' "$host replacement consumed once"
  reject consume "$state" "$id"
  reject renew "$state" "$id" "$instruction"

  printf '2000\n' > "$PR_RENEWAL_CLOCK"
  id="$(run request "$state" "$spec" | jq -r .id)"
  printf '2300\n' > "$PR_RENEWAL_CLOCK"
  id="$(run renew "$state" "$id" "$instruction" | jq -r .id)"
  printf '2600\n' > "$PR_RENEWAL_CLOCK"
  submit "reviewed: $id at the deadline"
  expect "$(run status "$state" "$id")" '.status == "expired" and .response == ""' "$host deadline grants nothing"
  id="$(run renew "$state" "$id" "$instruction" | jq -r .id)"
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm changed
  submit "reviewed: $id checked a superseded head"
  expect "$(cat "$state")" '.status == "pending"' "$host changed HEAD denies a renewed reply"
done

# Reuse the same serialization boundary for competing review renewals.
printf '3000\n' > "$PR_RENEWAL_CLOCK"
state="$PWD/.agents/state/concurrent-review.json"
id="$(run request "$state" "$spec" | jq -r .id)"
printf '3300\n' > "$PR_RENEWAL_CLOCK"
for attempt in 1 2; do
  (run renew "$state" "$id" "$instruction" >"$scratch/$attempt.json" 2>"$scratch/$attempt.err" \
    && printf success >"$scratch/$attempt.status" || printf denied >"$scratch/$attempt.status") &
done
wait
check_eq 'one concurrent renewal wins' "$(grep -l '^success$' "$scratch/"[12].status | wc -l | tr -d ' ')" 1
successor="$(jq -r .successor_id "$state.expired-$id.json")"
expect "$(cat "$state")" ".id == \"$successor\" and .status == \"pending\" and .accepted_at == null" \
  'archive and active successor agree'

# An existing archive is immutable and cannot authorize a replacement.
state="$PWD/.agents/state/archive-collision.json"
id="$(run request "$state" "$spec" | jq -r .id)"
printf '3600\n' > "$PR_RENEWAL_CLOCK"
before="$(run status "$state" "$id")"
printf 'prior history\n' > "$state.expired-$id.json"
reject renew "$state" "$id" "$instruction"
check_eq 'archive collision preserves active request' "$(cat "$state")" "$before"
check_eq 'archive collision preserves history' "$(cat "$state.expired-$id.json")" 'prior history'

# Storage faults preserve history even if the caller loses a successful response.
fault_plugin="$scratch/fault-plugin"
mkdir -p "$fault_plugin/scripts" "$fault_plugin/.agents/lib"
cp "$cli" "$fault_plugin/scripts/"
cp "$plugin/.agents/lib/"{timed-user-prompt,verdict-audit-state}.sh "$fault_plugin/.agents/lib/"
cp "$plugin/.agents/lib/user-question-policy.jq" "$fault_plugin/.agents/lib/"
cat >> "$fault_plugin/.agents/lib/verdict-audit-state.sh" <<'FAULT'
verdict_audit_write_atomic() {
  [[ "$PR_RENEWAL_WRITE_FAULT" != before ]] || return 1
  verdict_audit_write_atomic_identity "$1" >/dev/null || return 1
  return 1
}
FAULT
for phase in before after; do
  printf '4000\n' > "$PR_RENEWAL_CLOCK"
  state="$PWD/.agents/state/fault-$phase.json"
  id="$(run request "$state" "$spec" | jq -r .id)"
  printf '4300\n' > "$PR_RENEWAL_CLOCK"
  expired="$(run status "$state" "$id")"
  if PR_RENEWAL_WRITE_FAULT="$phase" bash "$fault_plugin/scripts/timed-user-prompt.sh" \
      renew "$state" "$id" "$instruction" >"$scratch/out" 2>"$scratch/err"; then
    bad "$phase publication failure reported"; assert_result
  fi
  successor="$(jq -r .successor_id "$state.expired-$id.json")"
  check_eq "$phase failure archives original" "$(jq -c .request "$state.expired-$id.json")" "$expired"
  if [[ "$phase" == before ]]; then
    check_eq 'pre-publication failure preserves expired request' "$(cat "$state")" "$expired"
  else
    expect "$(cat "$state")" ".id == \"$successor\" and .status == \"pending\" and .accepted_at == null" \
      'lost success response leaves an unapproved successor'
  fi
  before="$(cat "$state")"
  reject renew "$state" "$id" "$instruction"
  check_eq "$phase retry preserves active state" "$(cat "$state")" "$before"
done
assert_result
