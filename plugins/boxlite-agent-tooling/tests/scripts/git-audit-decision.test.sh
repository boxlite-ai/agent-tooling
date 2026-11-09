#!/usr/bin/env bash
# A completed failed round comes from the public history transition, not a seeded counter.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../audit/fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
cd -P "$scratch/repo"
git -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.test commit -qm fixture --allow-empty
mkdir -p .agents/state
mkdir "$scratch/bin"
export AUDIT_DECISION_TEST_CLOCK="$scratch/clock"
printf '1000\n' > "$AUDIT_DECISION_TEST_CLOCK"
cat > "$scratch/bin/date" <<'CLOCK'
#!/usr/bin/env bash
cat "$AUDIT_DECISION_TEST_CLOCK"
CLOCK
chmod +x "$scratch/bin/date"
export PATH="$scratch/bin:$PATH" CLAUDE_PROJECT_DIR="$PWD"
cli="$plugin/scripts/audit-reflection.sh"
scope="git-$(printf decision-session | git hash-object --stdin)"
head="$(git rev-parse HEAD)"
prepare() {
  jq -nc --argjson context "$context" --arg id "$1" --arg head "$head" \
    '{context:$context,attempt:{id:$id,binding:{head:$head},snapshot:{diff:"candidate"},deadline:4102444800}}' \
    | bash "$cli" prepare "$state"
}
record_error() {
  jq -nc --argjson context "$context" --arg id "$1" \
    '{context:$context,id:$id,outcome:{verdict:"ERROR",evidence:"runner failed"}}' \
    | bash "$cli" record "$state" >/dev/null
}
select_kind() {
  kind="$1"; state="$scratch/$kind.json"
  context="$(jq -nc --arg root "$PWD" --arg session "$scope" --arg gate "$kind" \
    '{repo_root:$root,session:$session,epoch:"0",branch:"feature",gate:$gate}')"
  decision="$PWD/.agents/state/$kind-audit-decision-request-$scope.json"
}
reject_prepare() {
  local before
  before="$(cat "$state")"
  if prepare "$1" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: unexpected audit preparation %s\n' "$1" >&2; exit 1
  fi
  [[ "$(cat "$state")" == "$before" ]]
}
for kind in commit push verdict; do
  select_kind "$kind"
  for id in a1 a2 a3; do
    audit_test_submit_due "$cli" "$state"
    prepare "$id" >/dev/null
    record_error "$id"
  done
  audit_test_submit_due "$cli" "$state"
  if [[ "$kind" == verdict ]]; then
    prepare a4 >/dev/null
  else
    if prepare a4 >"$scratch/out" 2>"$scratch/err"; then
      printf 'FAIL: fourth %s audit launched without a human-choice checkpoint\n' "$kind" >&2
      exit 1
    fi
    [[ "$(cat "$scratch/err")" == *"audit-decision:"* ]]
    jq -e '.attempts | length == 3' "$state" >/dev/null
  fi
done
printf 'PASS: Git pauses after three failures; verdict audits retain their budget\n'

prompt_cli="$plugin/scripts/timed-user-prompt.sh"
select_kind commit
original_id="$(jq -r .id "$decision")"
cp "$decision" "$scratch/valid-decision"
for unsafe in symlink fifo directory malformed; do
  rm "$decision"
  case "$unsafe" in
    symlink) ln -s "$scratch/valid-decision" "$decision" ;;
    fifo) mkfifo "$decision" ;;
    directory) mkdir "$decision" ;;
    malformed) printf '{}\n' > "$decision" ;;
  esac
  reject_prepare a4
  rm -rf "$decision"
  cp "$scratch/valid-decision" "$decision"
done
pids=()
for n in 1 2 3; do
  (if prepare "concurrent$n" >"$scratch/concurrent$n.out" 2>"$scratch/concurrent$n.err"; then exit 1; fi) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
jq -e --arg id "$original_id" '.id==$id and .deadline==1300' "$decision" >/dev/null
jq -e '.attempts | length==3' "$state" >/dev/null
printf 'PASS: unsafe request paths block; concurrent retries preserve one checkpoint\n'

user_prompt() {
  jq -nc --arg prompt "$1" '{hook_event_name:"UserPromptSubmit",
    session_id:"decision-session",prompt:$prompt}' \
    | bash "$plugin/.agents/hooks/cancel-verdict-audit.sh"
}
select_kind push
id="$(jq -r .id "$decision")"
if bash "$prompt_cli" respond "$decision" "$id" Stop >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: agent-relayed decision accepted\n' >&2; exit 1
fi
printf '1299\n' > "$AUDIT_DECISION_TEST_CLOCK"
user_prompt "push-audit-decision: $id Stop" >"$scratch/reply"
[[ "$(cat "$scratch/reply")" == *"retained the failed audit cycle"* ]]
jq -e --arg id "$id" '.status=="accepted" and .response==("push-audit-decision: " + $id + " Stop")' "$decision" >/dev/null
if bash "$prompt_cli" consume "$decision" "$id" >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: consumption could reopen a stopped checkpoint\n' >&2; exit 1
fi

select_kind commit
id="$(jq -r .id "$decision")"
reject_prepare a4
jq -e --arg id "$id" '.id==$id and .deadline==1300 and .status=="pending"' "$decision" >/dev/null
stop_request() {
  printf '%s' '{"session_id":"decision-session"}' | bash "$plugin/scripts/continue-timed-prompts.sh"
}
stop_request | jq -e '.decision=="block" and (.reason | contains("Deadline:"))' >/dev/null
printf '1300\n' > "$AUDIT_DECISION_TEST_CLOCK"
stop_request | jq -e '.decision=="block" and (.reason | contains("Reflect again (Recommended)"))' >/dev/null
prepare a4 >/dev/null
jq -e '.status=="expired" and .fallback_delivered and .response==""' "$decision" >/dev/null
jq -e '(.attempts | length)==4 and .attempts[2].outcome.verdict=="ERROR"' "$state" >/dev/null
# A canceled preflight handoff does not spend the selected completed round.
jq -nc --argjson context "$context" '{context:$context,id:"a4",
  outcome:{verdict:"CANCELED",evidence:"native-to-headless handoff"}}' | bash "$cli" record "$state" >/dev/null
audit_test_submit_due "$cli" "$state"
prepare handoff >/dev/null
record_error handoff
reject_prepare a5
next_id="$(jq -r .id "$decision")"
[[ "$next_id" != "$id" ]]
jq -e '.deadline==1600 and .status=="pending"' "$decision" >/dev/null

answer="commit-audit-decision: $next_id Reflect again"
user_prompt "$answer" >"$scratch/reply"
[[ "$(cat "$scratch/reply")" == *"retained the failed audit cycle"* ]]
[[ ! -e ".agents/state/verdict-prompt-epoch.$scope" ]]
jq -e '.status=="accepted"' "$decision" >/dev/null
reject_prepare a5
[[ "$(cat "$scratch/err")" == *"reflection required"* ]]
audit_test_submit_due "$cli" "$state"
prepare a5 >/dev/null
assessment="$(audit_test_assessment "$state")"
jq -nc --argjson context "$context" --argjson assessment "$assessment" \
  '{context:$context,id:"a5",outcome:{verdict:"PASS",evidence:"observed check",reflection_review:$assessment}}' \
  | bash "$cli" record "$state" >/dev/null
prepare next-cycle >/dev/null
jq -e '(.attempts | length)==1 and (.closed | length)==1
  and ([.closed[0].attempts[] | select(.outcome.verdict=="ERROR")] | length)==4' "$state" >/dev/null
select_kind push
reject_prepare a4
[[ "$(cat "$scratch/err")" == *"human chose Stop"* ]]
printf 'PASS: typed Stop persists; timeout and text replies preserve history and require reflection\n'

select_kind commit
record_error next-cycle
for attempt in plain2 plain3; do
  audit_test_submit_due "$cli" "$state"
  prepare "$attempt" >/dev/null
  record_error "$attempt"
done
reject_prepare plain4
plain_id="$(jq -r .id "$decision")"
user_prompt "commit-audit-decision: $plain_id Stop" >"$scratch/reply"
[[ "$(cat "$scratch/reply")" == *"retained the failed audit cycle"* ]]
[[ ! -e ".agents/state/verdict-prompt-epoch.$scope" ]]
reject_prepare plain4
[[ "$(cat "$scratch/err")" == *"human chose Stop"* ]]
jq -e '(.attempts | length)==3 and (.closed | length)==1' "$state" >/dev/null

# New prompts, mixed instructions and replayed replies keep ordinary epoch revocation.
user_prompt "$answer" >/dev/null
[[ -s ".agents/state/verdict-prompt-epoch.$scope" ]]
epoch="$(cat ".agents/state/verdict-prompt-epoch.$scope")"
user_prompt "$answer
also change the task" >/dev/null
[[ "$(cat ".agents/state/verdict-prompt-epoch.$scope")" != "$epoch" ]]
printf 'PASS: replay and mixed text cannot preserve old authority\n'

# A version-1 Stop decision must block even when an ordinary prompt advances the session epoch.
select_kind push
jq '.version=1 | del(.accepted_at) | .question_tool_id="old-card" | .response="Stop"
  | .spec.minimum_words=1' "$decision" > "$scratch/version1-stop"
cp "$scratch/version1-stop" "$decision"
user_prompt 'Continue with the current task' >/dev/null
new_epoch="$(cat ".agents/state/verdict-prompt-epoch.$scope")"
context="$(jq -c --arg epoch "$new_epoch" '.epoch=$epoch' <<<"$context")"
state="$scratch/push-new-epoch.json"
next_action="$(jq -nc --argjson context "$context" '{context:$context}' |
  bash "$cli" next-action "$state")"
jq -e --arg path "$decision" '.action=="stop" and (.reason|contains($path))' <<<"$next_action" >/dev/null
if prepare after-version1-stop >"$scratch/out" 2>"$scratch/err"; then
  printf 'FAIL: unsupported Stop allowed a new audit cycle\n' >&2
  exit 1
fi
[[ ! -e "$state" ]]
grep -Fq "unsupported request at $decision" "$scratch/err"
cmp "$scratch/version1-stop" "$decision"
printf 'PASS: unsupported Stop survives epoch changes without retry or fallback\n'

# Detached checkouts use the same HEAD branch binding in all host paths.
git -c core.hooksPath=/dev/null checkout --detach -q
scope="git-$(printf detached-session | git hash-object --stdin)"
select_kind commit
context="$(jq -c '.branch="HEAD"' <<<"$context")"
state="$scratch/detached.json"
for attempt in detached1 detached2 detached3; do
  audit_test_submit_due "$cli" "$state"
  prepare "$attempt" >/dev/null
  record_error "$attempt"
done
reject_prepare detached4
id="$(jq -r .id "$decision")"
printf '%s' '{"session_id":"detached-session"}' \
  | bash "$plugin/scripts/continue-timed-prompts.sh" \
  | jq -e --arg id "$id" '.decision=="block" and (.reason|contains($id))' >/dev/null
# Expiry grants retries, but never extends the eight-failure safety budget.
for n in 4 5 6 7 8; do
  printf '%s\n' "$(jq -r .deadline "$decision")" > "$AUDIT_DECISION_TEST_CLOCK"
  audit_test_submit_due "$cli" "$state"
  prepare "detached$n" >/dev/null
  record_error "detached$n"
  reject_prepare "detached$((n+1))"
done
[[ "$(cat "$scratch/err")" == *"audit history exhausted"* ]]
jq -e '.attempts | length==8 and all(.[]; .outcome.verdict=="ERROR")' "$state" >/dev/null
printf 'PASS: detached checkout choices work; retries retain the hard failure budget\n'
