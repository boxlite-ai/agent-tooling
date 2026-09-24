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
state="$scratch/repo/.agents/state/pr-size-request.json"
spec="$(jq -nc --arg repo "$repo" --arg head "$(git rev-parse HEAD)" \
  '{binding:{root:$repo,head:$head,branch:"feature",session:"test"},prefix:"pr-size-exception:",fallback:"split",minimum_words:12}')"
bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$spec" >/dev/null
stop() { printf '%s' '{"session_id":"test"}' | bash "$plugin/scripts/continue-timed-prompts.sh"; }
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("Deadline:"))' <<<"$out" >/dev/null
out="$(printf '%s' '{"session_id":"test"}' | bash "$plugin/.agents/hooks/stop-gate.sh")"
jq -e '.decision=="block" and (.reason|contains("Deadline:"))' <<<"$out" >/dev/null
[[ -z "$(printf '%s' '{"session_id":"other"}' | bash "$plugin/scripts/continue-timed-prompts.sh")" ]]
jq '.created_at -= 181 | .deadline -= 181' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("split") or contains("small"))' <<<"$out" >/dev/null
jq -e '.reason | contains("one tracking issue") and contains("checklist")' <<<"$out" >/dev/null \
  || { printf 'FAIL: size timeout continuation must default to one tracking issue with a checklist\n' >&2; exit 1; }
[[ -z "$(stop)" ]]
spec="$(jq '.prefix="reviewed:"|.fallback="keep-draft"|.minimum_words=1' <<<"$spec")"
state="$scratch/repo/.agents/state/pr-review-request.json"
bash "$plugin/scripts/timed-user-prompt.sh" request "$state" "$spec" >/dev/null
jq '.created_at -= 181 | .deadline -= 181' "$state" > "$scratch/expired"
mv "$scratch/expired" "$state"
out="$(stop)"
jq -e '.decision=="block" and (.reason|contains("No review acknowledgment was granted"))' <<<"$out" >/dev/null
[[ -z "$(stop)" ]]
printf 'timed continuations: pending, scope, size timeout, and review timeout passed\n'
