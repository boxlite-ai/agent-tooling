#!/usr/bin/env bash
# Exercise Stop continuations without sleeping or contacting GitHub.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q -b feature "$scratch/repo"
git -C "$scratch/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
cd "$scratch/repo"
repo="$(pwd -P)"
export CLAUDE_PROJECT_DIR="$repo"
mkdir -p .agents/state
state="$repo/.agents/state/pr-size-request.json"
spec="$(jq -nc --arg repo "$repo" --arg head "$(git rev-parse HEAD)" \
  '{binding:{root:$repo,head:$head,branch:"feature",session:"test"},prefix:"pr-size-exception:",fallback:"split"}')"
bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$spec" >/dev/null
stop() { printf '%s' '{"session_id":"test"}' | bash "$plugin/scripts/continue-timed-prompts.sh"; }
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("Deadline:"))' <<<"$out" >/dev/null
out="$(printf '%s' '{"session_id":"test"}' | bash "$plugin/.agents/hooks/stop-gate.sh")"
jq -e '.decision=="block" and (.reason|contains("Deadline:"))' <<<"$out" >/dev/null
[[ -z "$(printf '%s' '{"session_id":"other"}' | bash "$plugin/scripts/continue-timed-prompts.sh")" ]]
jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("split") or contains("small"))' <<<"$out" >/dev/null
jq -e '.reason | contains("one tracking issue") and contains("checklist")' <<<"$out" >/dev/null \
  || { printf 'FAIL: size timeout continuation must default to one tracking issue with a checklist\n' >&2; exit 1; }
jq -e '.reason | contains("Only a new explicit human request permits renewal")' <<<"$out" >/dev/null
[[ -z "$(stop)" ]]
choice_spec="$(jq '.binding.choice="split"' <<<"$spec")"
request="$(bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$choice_spec")"
jq -nc --arg id "$(jq -r .id <<<"$request")"   '{hook_event_name:"UserPromptSubmit",session_id:"test",prompt:("pr-size-exception: " + $id + " Split PR")}' |
  bash "$plugin/.agents/hooks/cancel-verdict-audit.sh" >/dev/null
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("chose Split PR"))' <<<"$out" >/dev/null
[[ -z "$(stop)" ]]
spec="$(jq '.prefix="reviewed:"|.fallback="keep-draft"' <<<"$spec")"
state="$repo/.agents/state/pr-review-request.json"
bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$spec" >/dev/null
jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("No review acknowledgment was granted"))' <<<"$out" >/dev/null
[[ -z "$(stop)" ]]
# A design decision keeps the agent working until its deadline, then keeps edits blocked.
spec="$(jq '.prefix="design-decision:"|.fallback="keep-blocked"' <<<"$spec")"
state="$repo/.agents/state/design-decision-request.json"
bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$spec" >/dev/null
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("pending design-decision") and contains("Deadline:"))' <<<"$out" >/dev/null \
  || { printf 'FAIL: a pending design decision must keep the agent working: %s\n' "$out" >&2; exit 1; }
jq '.created_at -= 301 | .deadline -= 301' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("edits stay blocked") and contains("Silence never overrules"))' <<<"$out" >/dev/null \
  || { printf 'FAIL: a design-decision timeout must keep edits blocked: %s\n' "$out" >&2; exit 1; }
# Redesign approval asks once and never waits: the draft stays unposted until approved (#334).
jq -e '.reason | contains("Ask once in plain text") and contains("Approve the exact redesign text")
  and contains("Do not wait for a reply") and contains("Keep the draft unposted")
  and contains("Silence never overrules or approves")' <<<"$out" >/dev/null \
  || { printf 'FAIL: redesign approval must ask once, not wait, and keep the draft unposted: %s\n' "$out" >&2; exit 1; }
[[ -z "$(stop)" ]]
jq '.version=1 | .deadline=.created_at+180' "$state" > "$scratch/unsupported"
cp "$scratch/unsupported" "$state"
if stop >"$scratch/out" 2>"$scratch/error"; then
  printf 'FAIL: unsupported state did not block continuation\n' >&2
  exit 1
fi
[[ ! -s "$scratch/out" ]]
grep -Fq "unsupported request at $state" "$scratch/error"
cmp "$state" "$scratch/unsupported"
printf 'timed continuations: pending, scope, size, review, and design-decision timeouts passed\n'
