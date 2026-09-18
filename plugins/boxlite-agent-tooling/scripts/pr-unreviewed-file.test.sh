#!/usr/bin/env bash
# Tests for scripts/pr-unreviewed-file.sh, the CI step that commits UNREVIEWED.md to a pull
# request nobody has reviewed and takes the merge button away until someone deletes it.
#
# A stub gh answers the pull request lookup, the file lookup, the pull request's commits and
# what one of them changed, and records the file, status and draft mutation it is asked for,
# so each case asserts what the script would send to GitHub rather than a value this suite
# built.
#
# Run with:  bash plugins/boxlite-agent-tooling/scripts/pr-unreviewed-file.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$PLUGIN_ROOT/scripts/pr-unreviewed-file.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
rc=""
err=""
BASE_REPO="boxlite-ai/agent-tooling"
# The sha in the event payload differs from the live head on purpose: nothing may read it.
EVENT_SHA="1111111111111111111111111111111111111111"
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
MARKED_SHA="89abcdef89abcdef89abcdef89abcdef89abcdef"
MARK_COMMIT_SHA="fedcba9876543210fedcba9876543210fedcba98"
NODE_ID="PR_kwDOAbCdEf"

cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls"
case "$*" in
  *"--jq (.head.sha // \"\"), (.node_id // \"\"), (.draft | tostring)"*)  # the pull request
    [[ "${STUB_PR_EXIT:-0}" == 0 ]] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; }
    printf '%s\n%s\n%s\n' "${STUB_HEAD-0123456789abcdef0123456789abcdef01234567}" \
      "${STUB_NODE_ID-PR_kwDOAbCdEf}" "${STUB_DRAFT:-false}"
    ;;
  "api -X GET "*contents*)
    case "${STUB_GET:-absent}" in
      present) printf '{"name":"UNREVIEWED.md"}\n' ;;
      absent) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api --paginate "*commits*)
    printf 'aaaa\tdorianzheng\tdorianzheng\ttrue\tfeat: the change\n'
    case "${STUB_MARKED:-no}" in
      yes) printf '%s\tgithub-actions[bot]\tweb-flow\ttrue\tchore: mark pull request #7 unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      spoof-author) printf '%s\tdorianzheng\tdorianzheng\ttrue\tchore: mark pull request #7 unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      spoof-committer)  # the bot address as author email, signed by the author
        printf '%s\tgithub-actions[bot]\tdorianzheng\ttrue\tchore: mark pull request #7 unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      spoof-unverified) printf '%s\tgithub-actions[bot]\tweb-flow\tfalse\tchore: mark pull request #7 unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      other-pr)  # a genuine marking commit, merged in from another pull request
        printf '%s\tgithub-actions[bot]\tweb-flow\ttrue\tchore: mark pull request #6 unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      no) : ;;
      capped)  # every commit GitHub will list, none of them a marking commit
        for n in $(seq 2 250); do printf 'c%s\tdorianzheng\tdorianzheng\ttrue\tfeat: change %s\n' "$n" "$n"; done ;;
      just-under)  # one short of the cap, so an absent marking commit is provable
        for n in $(seq 2 249); do printf 'c%s\tdorianzheng\tdorianzheng\ttrue\tfeat: change %s\n' "$n" "$n"; done ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  *".files"*)  # what one commit changed
    case "${STUB_MARK_FILES:-added}" in
      added) printf 'added UNREVIEWED.md\n' ;;
      none) printf 'modified README.md\n' ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api graphql "*)
    printf '%s\n' "$*" > "$STUB_DIR/graphql-call"
    exit "${STUB_DRAFT_EXIT:-0}"
    ;;
  "api -X PUT "*)
    cat > "$STUB_DIR/put-body"
    printf '%s\n' "${STUB_NEW_SHA-89abcdef89abcdef89abcdef89abcdef89abcdef}"
    exit "${STUB_PUT_EXIT:-0}"
    ;;
  "api -X POST "*statuses*)
    cat > "$STUB_DIR/status-body"
    exit "${STUB_STATUS_EXIT:-0}"
    ;;
  *) exit 3 ;;
esac
STUB
chmod +x "$TMP/gh"

event() {  # file, action, head repo
  jq -n --arg action "$2" --arg head_repo "$3" --arg sha "$EVENT_SHA" '
    {action: $action,
     repository: {full_name: "boxlite-ai/agent-tooling"},
     pull_request: {number: 7,
                    head: {sha: $sha, ref: "feat/thing", repo: {full_name: $head_repo}}}}' > "$1"
}

run_script() {  # event file, then NAME=value overrides for the stub
  local file="$1"
  shift
  rm -f "$TMP/gh-calls" "$TMP/put-body" "$TMP/status-body" "$TMP/graphql-call"
  err="$(env STUB_DIR="$TMP" GH_BIN="$TMP/gh" STUB_MARK_COMMIT_SHA="$MARK_COMMIT_SHA" "$@" \
    bash "$SCRIPT" "$file" 2>&1 >/dev/null)"
  rc=$?
}

report() {  # description, predicate exit status, details on failure
  if [[ "$2" == 0 ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (%s)\n' "$1" "$3"
  fi
}

exited() { [[ "$rc" == "$1" ]]; }
failed_before_github() { [[ "$rc" == 2 && ! -e "$TMP/gh-calls" ]]; }
read_live_head() { grep -q "api repos/$BASE_REPO/pulls/7 " "$TMP/gh-calls"; }
never_read_event_sha() { ! grep -q "$EVENT_SHA" "$TMP/gh-calls"; }
looked_up_marker_at() { grep -q -- "-f ref=$1" "$TMP/gh-calls"; }
never_created() { ! grep -q '^api -X PUT ' "$TMP/gh-calls"; }
drafted() { [[ -e "$TMP/graphql-call" ]] && grep -q "convertPullRequestToDraft" "$TMP/graphql-call" \
  && grep -q -- "-f id=$NODE_ID" "$TMP/graphql-call"; }
never_drafted() { [[ ! -e "$TMP/graphql-call" ]]; }
statused_marking_commit() {
  [[ "$(jq -r '.state' "$TMP/status-body" 2>/dev/null)" == failure \
     && "$(jq -r '.context' "$TMP/status-body" 2>/dev/null)" == "Author reviewed the PR" ]] \
    && grep -qx "api -X POST repos/$BASE_REPO/statuses/$MARKED_SHA --input -" "$TMP/gh-calls"
}
marked_unreviewed() {
  local content
  content="$(jq -r '.content | @base64d' "$TMP/put-body" 2>/dev/null)"
  [[ "$rc" == 1 && "$err" == *Unreviewed* ]] \
    && grep -qx "api -X PUT repos/$BASE_REPO/contents/UNREVIEWED.md --input - --jq .commit.sha" "$TMP/gh-calls" \
    && [[ "$(jq -r '.branch' "$TMP/put-body")" == feat/thing \
          && "$(jq -r '.message' "$TMP/put-body")" == "chore: mark pull request #7 unreviewed" \
          && "$content" == "# Unreviewed"* && "$content" == *"merged without review." \
          && "$content" == *"delete this file in a commit and mark the pull request ready for review."* ]] \
    && statused_marking_commit && drafted
}

event "$TMP/opened.json" opened "$BASE_REPO"
event "$TMP/sync.json" synchronize "$BASE_REPO"

echo "## An unmarked pull request gets the file, a failing gate and draft"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no
marked_unreviewed; report "a new PR without the file gets it, the gate fails on that commit, and it is drafted" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"
read_live_head; report "the head comes from the pull request, not the event payload" $? \
  "calls=$(cat "$TMP/gh-calls")"
never_read_event_sha; report "the event's own sha is never read" $? "calls=$(cat "$TMP/gh-calls")"
looked_up_marker_at "$HEAD_SHA"; report "the file is looked up at that live head" $? \
  "calls=$(cat "$TMP/gh-calls")"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no STUB_DRAFT=true
never_drafted; report "a pull request already in draft is not converted again" $? \
  "calls=$(cat "$TMP/gh-calls")"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no STUB_DRAFT_EXIT=1
refused_draft_is_loud() { [[ "$rc" == 1 && "$err" == *"could not convert"* && "$err" == *Unreviewed* ]]; }
refused_draft_is_loud; report "a refused draft conversion says so and still reports unreviewed" $? \
  "rc=$rc err=$err"
# A first run that failed, or a PR older than this workflow, must not pass on a later event.
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=no
marked_unreviewed; report "a later event marks a PR that was never marked" $? "rc=$rc err=$err"

echo "## Only GitHub's own marking commit counts as proof"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=added
reviewed_passes() { [[ "$rc" == 0 ]] && never_created && never_drafted; }
reviewed_passes; report "a signed bot commit that added the file, then deleted, passes" $? \
  "rc=$rc calls=$(cat "$TMP/gh-calls")"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=spoof-author STUB_MARK_FILES=added
marked_unreviewed; report "the same subject from a human is not proof" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=spoof-committer STUB_MARK_FILES=added
marked_unreviewed; report "the bot as author but a person as committer is not proof" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=spoof-unverified STUB_MARK_FILES=added
marked_unreviewed; report "an unsigned commit with that subject is not proof" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=other-pr STUB_MARK_FILES=added
marked_unreviewed; report "a genuine marking commit for another pull request is not proof here" $? \
  "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=none
marked_unreviewed; report "a marking commit that added nothing is not proof" $? "rc=$rc err=$err"
# Marking again would be marked again on the next event too: a loop no author can escape.
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=capped
capped_list_fails_closed() { [[ "$rc" == 2 && "$err" == *250* ]] && never_created && never_drafted; }
capped_list_fails_closed; report "a PR too long for GitHub to list is not marked or passed" $? \
  "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=just-under
marked_unreviewed; report "one commit short of that limit is still marked normally" $? \
  "rc=$rc err=$err"

echo "## The file still present always fails"
run_script "$TMP/sync.json" STUB_GET=present STUB_MARKED=yes STUB_MARK_FILES=added
present_fails() { [[ "$rc" == 1 ]] && never_created && drafted; }
present_fails; report "a head that still carries the file fails and is drafted, even after a marking commit" $? \
  "rc=$rc calls=$(cat "$TMP/gh-calls")"

echo "## A fork is drafted and reported, never marked or passed"
event "$TMP/fork.json" opened someone/agent-tooling
run_script "$TMP/fork.json" STUB_GET=absent STUB_MARKED=no
fork_reported() { [[ "$rc" == 1 && "$err" == *someone/agent-tooling* ]] && never_created && drafted; }
fork_reported; report "a fork PR is drafted and reported unreviewed, never marked" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"

echo "## Failures fail closed"
run_script "$TMP/sync.json" STUB_PR_EXIT=1
exited 2; report "an unreadable pull request fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_HEAD=nonsense
exited 2; report "a head that is not a sha fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_NODE_ID=
exited 2; report "a pull request with no node id fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_GET=error
exited 2; report "a failed file lookup fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=error
exited 2; report "a failed commit-list read fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=error
exited 2; report "a failed read of a marking commit fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no STUB_PUT_EXIT=1
exited 2; report "a failed file creation fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no STUB_NEW_SHA=
exited 2; report "a creation that returns no commit fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no STUB_STATUS_EXIT=1
exited 2; report "a failed gate report on the marking commit fails closed" $? "rc=$rc"
jq -n '{action: "opened", repository: {full_name: "boxlite-ai/agent-tooling"},
        pull_request: {number: 0, head: {ref: "", repo: {full_name: "boxlite-ai/agent-tooling"}}}}' \
  > "$TMP/bad-identity.json"
run_script "$TMP/bad-identity.json"
failed_before_github; report "an unusable number or branch fails closed before calling GitHub" $? "rc=$rc"
printf '{not json' > "$TMP/malformed.json"
run_script "$TMP/malformed.json"
exited 2; report "a malformed event fails closed" $? "rc=$rc"
run_script "$TMP/absent.json"
exited 2; report "a missing event file fails closed" $? "rc=$rc"
jq -n '{action: "opened", issue: {number: 7}}' > "$TMP/not-a-pr.json"
run_script "$TMP/not-a-pr.json"
exited 2; report "an event without a pull request fails closed" $? "rc=$rc"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
