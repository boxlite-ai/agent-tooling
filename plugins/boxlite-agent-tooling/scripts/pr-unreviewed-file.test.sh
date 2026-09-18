#!/usr/bin/env bash
# Tests for scripts/pr-unreviewed-file.sh, the CI step that commits UNREVIEWED.md to a pull
# request nobody has reviewed and reports the gate on the pull request's own head commit.
#
# A stub gh answers the pull request's head sha, the file lookup, the pull request's
# commits and what one of them changed, and records the file and statuses it is asked to
# create, so each case asserts what the script would send to GitHub rather than a value
# this suite built.
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

cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls"
case "$*" in
  *"--jq .head.sha")  # the pull request's live head
    [[ "${STUB_HEAD_EXIT:-0}" == 0 ]] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; }
    printf '%s\n' "${STUB_HEAD-0123456789abcdef0123456789abcdef01234567}"
    ;;
  "api -X GET "*contents*)
    case "${STUB_GET:-absent}" in
      present) printf '{"name":"UNREVIEWED.md"}\n' ;;
      absent) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api --paginate "*commits*)
    printf 'aaaa\tdorianzheng\ttrue\tfeat: the change\n'
    case "${STUB_MARKED:-no}" in
      yes) printf '%s\tgithub-actions[bot]\ttrue\tchore: mark pull request unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      spoof-author) printf '%s\tdorianzheng\ttrue\tchore: mark pull request unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      spoof-unverified) printf '%s\tgithub-actions[bot]\tfalse\tchore: mark pull request unreviewed\n' "$STUB_MARK_COMMIT_SHA" ;;
      no) : ;;
      capped)  # every commit GitHub will list, none of them a marking commit
        for n in $(seq 2 250); do printf 'c%s\tdorianzheng\ttrue\tfeat: change %s\n' "$n" "$n"; done ;;
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
  rm -f "$TMP/gh-calls" "$TMP/put-body" "$TMP/status-body"
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
read_live_head() { grep -qx "api repos/$BASE_REPO/pulls/7 --jq .head.sha" "$TMP/gh-calls"; }
never_read_event_sha() { ! grep -q "$EVENT_SHA" "$TMP/gh-calls"; }
looked_up_marker_at() { grep -q -- "-f ref=$1" "$TMP/gh-calls"; }
never_created() { ! grep -q '^api -X PUT ' "$TMP/gh-calls"; }
status_says() {  # sha, state
  [[ "$(jq -r '.state' "$TMP/status-body" 2>/dev/null)" == "$2" \
     && "$(jq -r '.context' "$TMP/status-body" 2>/dev/null)" == "Author reviewed the PR" ]] \
    && grep -qx "api -X POST repos/$BASE_REPO/statuses/$1 --input -" "$TMP/gh-calls"
}
marked_unreviewed() {
  local content
  content="$(jq -r '.content | @base64d' "$TMP/put-body" 2>/dev/null)"
  [[ "$rc" == 1 && "$err" == *Unreviewed* ]] \
    && grep -qx "api -X PUT repos/$BASE_REPO/contents/UNREVIEWED.md --input - --jq .commit.sha" "$TMP/gh-calls" \
    && [[ "$(jq -r '.branch' "$TMP/put-body")" == feat/thing \
          && "$(jq -r '.message' "$TMP/put-body")" == "chore: mark pull request unreviewed" \
          && "$content" == "# Unreviewed"* && "$content" == *"merged without review." ]] \
    && status_says "$MARKED_SHA" failure
}

event "$TMP/opened.json" opened "$BASE_REPO"
event "$TMP/sync.json" synchronize "$BASE_REPO"

echo "## An unmarked pull request gets the file and a failing gate"
run_script "$TMP/opened.json" STUB_GET=absent STUB_MARKED=no
marked_unreviewed; report "a new PR without the file gets it, and the gate fails on that commit" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"
read_live_head; report "the head comes from the pull request, not the event payload" $? \
  "calls=$(cat "$TMP/gh-calls")"
never_read_event_sha; report "the event's own sha is never read" $? "calls=$(cat "$TMP/gh-calls")"
looked_up_marker_at "$HEAD_SHA"; report "the file is looked up at that live head" $? \
  "calls=$(cat "$TMP/gh-calls")"
# A first run that failed, or a PR older than this workflow, must not pass on a later event.
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=no
marked_unreviewed; report "a later event marks a PR that was never marked" $? "rc=$rc err=$err"

echo "## Only GitHub's own marking commit counts as proof"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=added
reviewed_passes() { [[ "$rc" == 0 ]] && status_says "$HEAD_SHA" success && never_created; }
reviewed_passes; report "a signed bot commit that added the file, then deleted, passes on the head" $? \
  "rc=$rc calls=$(cat "$TMP/gh-calls") status=$(cat "$TMP/status-body" 2>/dev/null)"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=spoof-author STUB_MARK_FILES=added
marked_unreviewed; report "the same subject from a human is not proof" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=spoof-unverified STUB_MARK_FILES=added
marked_unreviewed; report "an unsigned commit with that subject is not proof" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=none
marked_unreviewed; report "a marking commit that added nothing is not proof" $? "rc=$rc err=$err"
# Marking again would be marked again on the next event too: a loop no author can escape.
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=capped
capped_list_fails_closed() { [[ "$rc" == 2 && "$err" == *250* ]] && never_created; }
capped_list_fails_closed; report "a PR too long for GitHub to list is not marked or passed" $? \
  "rc=$rc err=$err"

echo "## The file still present always fails, on the head"
run_script "$TMP/sync.json" STUB_GET=present STUB_MARKED=yes STUB_MARK_FILES=added
present_fails() { [[ "$rc" == 1 ]] && status_says "$HEAD_SHA" failure && never_created; }
present_fails; report "a head that still carries the file fails, even after a marking commit" $? \
  "rc=$rc calls=$(cat "$TMP/gh-calls")"

echo "## A fork is reported on its own head, never marked or passed"
event "$TMP/fork.json" opened someone/agent-tooling
run_script "$TMP/fork.json" STUB_GET=absent STUB_MARKED=no
fork_reported() {
  [[ "$rc" == 1 && "$err" == *someone/agent-tooling* ]] \
    && status_says "$HEAD_SHA" failure && never_created
}
fork_reported; report "a fork PR gets a failing gate in the base repo, and is never marked" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"

echo "## Failures fail closed"
run_script "$TMP/sync.json" STUB_HEAD_EXIT=1
exited 2; report "an unreadable head fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_HEAD=nonsense
exited 2; report "a head that is not a sha fails closed" $? "rc=$rc"
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
run_script "$TMP/sync.json" STUB_GET=present STUB_STATUS_EXIT=1
exited 2; report "a failed gate report on a present file fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" STUB_GET=absent STUB_MARKED=yes STUB_MARK_FILES=added STUB_STATUS_EXIT=1
exited 2; report "a failed gate report on a reviewed PR fails closed" $? "rc=$rc"
run_script "$TMP/fork.json" STUB_STATUS_EXIT=1
exited 2; report "a failed gate report on a fork fails closed" $? "rc=$rc"
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
