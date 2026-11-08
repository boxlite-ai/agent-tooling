#!/usr/bin/env bash
# Exercise the actual UserPromptSubmit receiver against timed PR requests.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo/.agents/state"
export PR_REPLY_CLOCK="$scratch/clock"
cat > "$scratch/bin/date" <<'CLOCK'
#!/usr/bin/env bash
cat "$PR_REPLY_CLOCK"
CLOCK
chmod +x "$scratch/bin/date"
export PATH="$scratch/bin:$PATH"
cd -P "$scratch/repo"
git init -q -b fixture
git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm initial
head="$(git rev-parse HEAD)"
state="$PWD/.agents/state"
cli="$plugin/scripts/timed-user-prompt.sh"
hook="$plugin/.agents/hooks/cancel-verdict-audit.sh"
submit() {
  jq -nc --arg prompt "$1" --arg session "${2:-operator}" --arg cwd "$PWD" \
    '{hook_event_name:"UserPromptSubmit",session_id:$session,prompt:$prompt,cwd:$cwd}' \
    | BOXLITE_HOOK_HOST="${host:-codex}" CLAUDE_PROJECT_DIR="$PWD" bash "$hook" > "$scratch/reply"
}
request() {
  jq -nc --arg prefix "$2" --arg fallback "$3" --arg repo "$PWD" --arg head "${4:-$head}" '
    {prefix:$prefix,fallback:$fallback,
     binding:{repo:$repo,root:$repo,branch:"fixture",head:$head,session:"operator"}}' \
    | bash "$cli" request "$1" "$(cat)" | jq -er .id
}
pending() { jq -e '.status=="pending" and .response==""' "$1" >/dev/null; }
size="$state/pr-size-request.json"
review="$state/pr-review-request.json"
marker="$state/pr-reviewed.json"
for host in codex claude; do
  rm -f "$size" "$review"
  printf '1000\n' > "$PR_REPLY_CLOCK"
  size_id="$(request "$size" 'pr-size-exception:' split)"
  review_id="$(request "$review" 'reviewed:' keep-draft)"
  size_reply="pr-size-exception: $size_id Bypass limit"
  review_reply="reviewed: $review_id verified the fixture"
  submit 'Bypass limit'
  submit "$size_reply" wrong-session
  submit "$review_reply" wrong-session
  submit 'reviewed: response to a superseded request'
  if ! pending "$review"; then
    printf 'FAIL: an unbound review reply authorized the current request\n' >&2
    exit 1
  fi
  submit 'pr-size-exception: 00000000000000000000000000000000 Bypass limit'
  submit 'reviewed: 00000000000000000000000000000000 verified another request'
  submit "$(printf '%s\nextra' "$size_reply")"
  pending "$size"
  pending "$review"

  printf '1299\n' > "$PR_REPLY_CLOCK"
  submit "$size_reply"
  jq -e --arg reply "$size_reply" '.status=="accepted" and .response==$reply and .deadline==1300' "$size" >/dev/null
  submit "$review_reply"
  jq -e --arg reply "$review_reply" '.status=="accepted" and .response==$reply and .accepted_at==1299' "$review" >/dev/null
  [[ ! -e "$marker" ]]
  printf '1300\n' > "$PR_REPLY_CLOCK"
  submit "$review_reply"
  jq -e '.accepted_at==1299' "$review" >/dev/null
done

# A changed HEAD and a reply at the deadline grant nothing.
rm -f "$size" "$review"
printf '1500\n' > "$PR_REPLY_CLOCK"
size_id="$(request "$size" 'pr-size-exception:' split)"
review_id="$(request "$review" 'reviewed:' keep-draft 0000000000000000000000000000000000000000)"
submit "reviewed: $review_id belongs to another head"
pending "$review"
rm -f "$review"
review_id="$(request "$review" 'reviewed:' keep-draft)"
printf '1800\n' > "$PR_REPLY_CLOCK"
submit "pr-size-exception: $size_id Bypass limit"
submit "reviewed: $review_id at the deadline"
jq -se 'all(.[]; .response=="")' "$size" "$review" >/dev/null

rm -f "$size"
printf '1900\n' > "$PR_REPLY_CLOCK"
size_id="$(request "$size" 'pr-size-exception:' split)"
submit "pr-size-exception: $size_id Split PR"
jq -e '.status=="declined"' "$size" >/dev/null

# Replacing an unsupported record never starts another request or relays its response.
jq '.version=1 | del(.accepted_at) | .question_tool_id=""' "$review" > "$scratch/legacy"
cp "$scratch/legacy" "$review"
submit "reviewed: $review_id verified old target"
grep -Fq "unsupported request at $review" "$scratch/reply"
cmp "$scratch/legacy" "$review"
printf 'PR replies: host routing, binding, deadlines, split, and unsupported state passed\n'
