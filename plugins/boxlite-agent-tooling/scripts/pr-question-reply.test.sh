#!/usr/bin/env bash
# Exercise the actual UserPromptSubmit receiver against timed PR requests.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
    | BOXLITE_HOOK_HOST=codex CLAUDE_PROJECT_DIR="$PWD" bash "$hook" > "$scratch/reply"
}
request() {
  jq -nc --arg prefix "$2" --arg fallback "$3" --arg repo "$PWD" --arg head "${4:-$head}" '
    {prefix:$prefix,fallback:$fallback,minimum_words:1,
     binding:{repo:$repo,root:$repo,branch:"fixture",head:$head,session:"operator"}}' \
    | bash "$cli" request "$1" "$(cat)" | jq -er .id
}
pending() { jq -e '.status=="pending" and .response==""' "$1" >/dev/null; }
failures=0
size="$state/pr-size-request.json"
review="$state/pr-review-request.json"
marker="$state/pr-reviewed.json"
printf '1000\n' > "$PR_REPLY_CLOCK"
size_id="$(request "$size" 'pr-size-exception:' split)"
review_id="$(request "$review" 'reviewed:' keep-draft)"
submit 'Bypass limit'
submit 'pr-size-exception: 00000000000000000000000000000000 Bypass limit'
submit "pr-size-exception: $size_id Bypass limit" wrong-session
submit 'reviewed: verified the fixture' wrong-session
pending "$size"
pending "$review"
[[ ! -e "$marker" ]]
printf '1299\n' > "$PR_REPLY_CLOCK"
submit "pr-size-exception: $size_id Bypass limit"
if ! jq -e '.status=="accepted" and .response=="Bypass limit" and .deadline==1300' "$size" >/dev/null; then
  printf 'FAIL: a timely size choice did not reach the request through UserPromptSubmit\n' >&2
  failures=$((failures + 1))
fi
submit 'reviewed: verified the fixture'
if ! jq -e '.status=="accepted" and .response=="reviewed: verified the fixture" and .deadline==1300' "$review" >/dev/null \
   || ! jq -e --arg request "$review_id" --arg head "$head" '
     . == {branch:"fixture",head:$head,message:"reviewed: verified the fixture",request:$request}
   ' "$marker" >/dev/null 2>&1; then
  printf 'FAIL: a timely review reply did not record authority through UserPromptSubmit\n' >&2
  failures=$((failures + 1))
fi
[[ "$failures" == 0 ]]

# Late replies, changed HEAD, and multiple-line size commands authorize nothing.
rm -f "$size" "$review" "$marker"
printf '1500\n' > "$PR_REPLY_CLOCK"
size_id="$(request "$size" 'pr-size-exception:' split)"
request "$review" 'reviewed:' keep-draft 0000000000000000000000000000000000000000 >/dev/null
submit 'reviewed: this belongs to another head'
pending "$review"
submit "$(printf 'pr-size-exception: %s Bypass limit\nextra text' "$size_id")"
pending "$size"
rm -f "$review"
request "$review" 'reviewed:' keep-draft >/dev/null
printf '1800\n' > "$PR_REPLY_CLOCK"
submit "pr-size-exception: $size_id Bypass limit"
submit 'reviewed: this is at the deadline'
[[ ! -e "$marker" ]]
jq -se 'all(.[]; .response=="")' "$size" "$review" >/dev/null

# The split label is never authorization, and a failed marker write stays blocked.
rm -f "$size" "$review"
printf '1900\n' > "$PR_REPLY_CLOCK"
size_id="$(request "$size" 'pr-size-exception:' split)"
submit "pr-size-exception: $size_id Split PR"
jq -e '.status=="declined" and .response=="Split PR"' "$size" >/dev/null
review_id="$(request "$review" 'reviewed:' keep-draft)"
mkdir "$marker"
submit 'reviewed: verified recovery'
[[ -d "$marker" ]]
grep -q 'was not recorded' "$scratch/reply"
rmdir "$marker"
submit 'reviewed: another response cannot replace it'
[[ ! -e "$marker" ]]
submit 'reviewed: verified recovery'
jq -e --arg id "$review_id" '.request==$id and .message=="reviewed: verified recovery"' "$marker" >/dev/null
printf 'PR replies: typed acceptance, binding, deadline, split, and marker recovery passed\n'
