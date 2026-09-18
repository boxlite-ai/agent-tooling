#!/usr/bin/env bash
# Tests for scripts/pr-unreviewed-file.sh, the CI step that commits UNREVIEWED.md to a pull
# request and passes only once that file was added and then deleted.
#
# A stub gh answers the contents lookup and the pull request's commit list, and records the
# file and status it is asked to create, so each case asserts what the script would send to
# GitHub rather than a value this suite built.
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
HEAD_SHA="0123456789abcdef0123456789abcdef01234567"
MARKED_SHA="89abcdef89abcdef89abcdef89abcdef89abcdef"
SPOOF_SHA="fedcba9876543210fedcba9876543210fedcba98"
MARKER_B64="$(printf '%s\n' \
  '# Unreviewed' \
  '' \
  'Nobody has reviewed this pull request yet. After reading the diff, delete this file in a commit.' \
  '' \
  'If this file is on the default branch, the pull request that added it was merged without review.' \
  | base64 | tr -d '\n')"

cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh-calls"
case "$*" in
  "api -X GET "*"/status")
    case "${STUB_MARK_STATUS:-no}" in
      yes)
        printf '{"statuses":[{"context":"Author reviewed the PR","state":"failure","description":"UNREVIEWED.md is in this pull request"}]}\n'
        exit 0
        ;;
      no) printf '{"statuses":[]}\n'; exit 0 ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api -X GET "*)
    ref=""
    if [[ "$*" =~ -f\ ref=([^[:space:]]+) ]]; then
      ref="${BASH_REMATCH[1]}"
    fi
    case "$ref" in
      feat/thing) mode="${STUB_GET_HEAD:-absent}" ;;
      "${STUB_MARK_SHA:-89abcdef89abcdef89abcdef89abcdef89abcdef}") mode="${STUB_GET_MARK:-absent}" ;;
      *) mode="${STUB_GET_OTHER:-absent}" ;;
    esac
    case "$mode" in
      present)
        if [[ "$*" == *"--jq .content"* ]]; then
          printf '%s\n' "${STUB_MARKER_B64}"
        else
          printf '{"name":"UNREVIEWED.md"}\n'
        fi
        exit 0
        ;;
      absent) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api --paginate "*commits*)
    case "${STUB_MARKED:-no}" in
      yes) printf '%s\t%s\n%s\t%s\n' "${STUB_MARK_SHA:-89abcdef89abcdef89abcdef89abcdef89abcdef}" \
        'chore: mark pull request unreviewed' "$HEAD_SHA" 'feat: the change'; exit 0 ;;
      no) printf '%s\t%s\n' "$HEAD_SHA" 'feat: the change'; exit 0 ;;
      spoof) printf '%s\t%s\n%s\t%s\n' "${STUB_SPOOF_SHA:-fedcba9876543210fedcba9876543210fedcba98}" 'chore: mark pull request unreviewed' \
        "$HEAD_SHA" 'feat: the change'; exit 0 ;;
      *) printf 'gh: Server Error (HTTP 500)\n' >&2; exit 1 ;;
    esac
    ;;
  "api -X PUT "*)
    cat > "$STUB_DIR/put-body"
    printf '%s\n' "${STUB_NEW_SHA-89abcdef89abcdef89abcdef89abcdef89abcdef}"
    exit "${STUB_PUT_EXIT:-0}"
    ;;
  "api -X POST "*)
    cat > "$STUB_DIR/status-body"
    exit "${STUB_STATUS_EXIT:-0}"
    ;;
esac
exit 3
STUB
chmod +x "$TMP/gh"

event() {  # file, action, head repo, head sha
  jq -n --arg action "$2" --arg head_repo "$3" --arg sha "$4" '
    {action: $action,
     repository: {full_name: "boxlite-ai/agent-tooling"},
     pull_request: {number: 7,
                    head: {sha: $sha, ref: "feat/thing", repo: {full_name: $head_repo}}}}' > "$1"
}

event_pull_request_target() {  # file, action, head repo, head sha
  jq -n --arg action "$2" --arg head_repo "$3" --arg sha "$4" '
    {action: $action,
     repository: {full_name: "boxlite-ai/agent-tooling"},
     pull_request: {number: 7,
                    head: {sha: $sha, ref: "feat/thing", repo: {full_name: $head_repo}},
                    base: {repo: {full_name: "boxlite-ai/agent-tooling"}}},
     sender: {login: "octocat"}}' > "$1"
}

run_script() {  # event file, tip lookup (present|absent|error), marked (yes|no|spoof|error),
                # creation exit code, status exit code, commit the creation returns
  rm -f "$TMP/gh-calls" "$TMP/put-body" "$TMP/status-body"
  local mark_get=absent mark_status=no
  case "$3" in
    yes) mark_get=present; mark_status=yes ;;
  esac
  err="$(STUB_DIR="$TMP" STUB_GET_HEAD="$2" STUB_GET_MARK="$mark_get" STUB_MARKED="$3" \
    STUB_MARK_STATUS="$mark_status" STUB_MARK_SHA="${6-$MARKED_SHA}" STUB_SPOOF_SHA="$SPOOF_SHA" \
    STUB_MARKER_B64="$MARKER_B64" \
    STUB_PUT_EXIT="${4:-0}" STUB_STATUS_EXIT="${5:-0}" STUB_NEW_SHA="${6-$MARKED_SHA}" GH_BIN="$TMP/gh" \
    bash "$SCRIPT" "$1" 2>&1 >/dev/null)"
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
exited_without_creating() { [[ "$rc" == "$1" ]] && ! grep -q '^api -X PUT ' "$TMP/gh-calls" 2>/dev/null; }
failed_before_github() { [[ "$rc" == 2 && ! -e "$TMP/gh-calls" ]]; }
looked_up_branch_tip() { grep -qx "api -X GET repos/boxlite-ai/agent-tooling/contents/UNREVIEWED.md -f ref=feat/thing" "$TMP/gh-calls"; }
created_in() { grep -qx "api -X PUT repos/$1/contents/UNREVIEWED.md --input - --jq .commit.sha" "$TMP/gh-calls"; }
marked_unreviewed() {
  local content
  content="$(jq -r '.content | @base64d' "$TMP/put-body" 2>/dev/null)"
  [[ "$rc" == 1 && "$err" == *Unreviewed* ]] \
    && created_in boxlite-ai/agent-tooling \
    && [[ "$(jq -r '.branch' "$TMP/put-body")" == feat/thing \
          && "$(jq -r '.message' "$TMP/put-body")" == "chore: mark pull request unreviewed" \
          && "$content" == "# Unreviewed"* \
          && "$content" == *"merged without review." ]]
}
reported_gate_on_marking_commit() {
  [[ "$(jq -r '.context' "$TMP/status-body" 2>/dev/null)" == "Author reviewed the PR" \
     && "$(jq -r '.state' "$TMP/status-body" 2>/dev/null)" == failure ]] \
    && grep -qx "api -X POST repos/boxlite-ai/agent-tooling/statuses/$MARKED_SHA --input -" "$TMP/gh-calls"
}

echo "## An unmarked pull request gets the file, on any event"
event "$TMP/opened.json" opened boxlite-ai/agent-tooling "$HEAD_SHA"
run_script "$TMP/opened.json" absent no
marked_unreviewed; report "a new PR without the file gets it and fails" $? "rc=$rc err=$err"
looked_up_branch_tip; report "the lookup reads the branch tip, not the event sha" $? \
  "calls=$(cat "$TMP/gh-calls")"
reported_gate_on_marking_commit; report "the marking commit gets the failing gate itself" $? \
  "calls=$(cat "$TMP/gh-calls") status=$(cat "$TMP/status-body" 2>/dev/null)"

event_pull_request_target "$TMP/target-opened.json" opened boxlite-ai/agent-tooling "$HEAD_SHA"
run_script "$TMP/target-opened.json" absent no
marked_unreviewed; report "a pull_request_target payload marks an unreviewed PR the same way" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"

# The hole this closes: a first run that failed, or a PR older than the workflow, has no
# marking commit. Reading the missing file as "reviewed" would pass it green forever.
event "$TMP/sync.json" synchronize boxlite-ai/agent-tooling "$HEAD_SHA"
run_script "$TMP/sync.json" absent no
marked_unreviewed; report "a later event marks a PR that was never marked" $? "rc=$rc err=$err"
run_script "$TMP/sync.json" absent spoof
marked_unreviewed; report "a spoofed subject without a marker commit is ignored and re-marked" $? \
  "rc=$rc err=$err calls=$(cat "$TMP/gh-calls")"

echo "## Deleting the file passes only after it was added"
run_script "$TMP/sync.json" absent yes
exited_without_creating 0; report "a PR whose marking commit is present and file deleted passes" $? "rc=$rc"
event "$TMP/reopened.json" reopened boxlite-ai/agent-tooling "$HEAD_SHA"
run_script "$TMP/reopened.json" absent yes
exited_without_creating 0; report "reopening a cleared PR does not add the file again" $? "rc=$rc"
run_script "$TMP/opened.json" present yes
exited_without_creating 1; report "the file still present fails even after a marking commit" $? "rc=$rc"
run_script "$TMP/sync.json" present no
exited_without_creating 1; report "new commits with the file still present fail" $? "rc=$rc"

# Two quick pushes queue a run holding an older event sha than the branch tip. Reading the
# tip is what stops it passing a branch that still carries the file.
event "$TMP/stale.json" synchronize boxlite-ai/agent-tooling "fedcba9876543210fedcba9876543210fedcba98"
run_script "$TMP/stale.json" present yes
stale_run_blocked() { [[ "$rc" == 1 ]] && looked_up_branch_tip && ! grep -q '^api -X PUT ' "$TMP/gh-calls"; }
stale_run_blocked; report "an older event sha cannot pass a tip that still has the file" $? \
  "rc=$rc calls=$(cat "$TMP/gh-calls")"

echo "## A fork is reported, never marked or passed"
# The workflow token belongs to the base repository, so a fork's branch cannot be written.
event "$TMP/fork.json" opened someone/agent-tooling "$HEAD_SHA"
run_script "$TMP/fork.json" absent no
fork_reported() { [[ "$rc" == 1 && "$err" == *someone/agent-tooling* && ! -e "$TMP/gh-calls" ]]; }
fork_reported; report "a fork PR is reported unreviewed, never marked or passed" $? "rc=$rc err=$err"

echo "## Failures fail closed"
run_script "$TMP/sync.json" error no
exited 2; report "a failed lookup fails closed" $? "rc=$rc"
run_script "$TMP/sync.json" absent error
exited 2; report "a failed commit-list read fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" absent no 1
exited 2; report "a failed file creation fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" absent no 0 1
exited 2; report "a failed gate report on the marking commit fails closed" $? "rc=$rc"
run_script "$TMP/opened.json" absent no 0 0 ""
exited 2; report "a creation that returns no commit fails closed" $? "rc=$rc"
jq -n '{action: "opened", repository: {full_name: "boxlite-ai/agent-tooling"},
        pull_request: {number: 0, head: {ref: "", repo: {full_name: "boxlite-ai/agent-tooling"}}}}' \
  > "$TMP/bad-identity.json"
run_script "$TMP/bad-identity.json" absent no
failed_before_github; report "an unusable number or branch fails closed before calling GitHub" $? "rc=$rc"
printf '{not json' > "$TMP/malformed.json"
run_script "$TMP/malformed.json" absent no
exited 2; report "a malformed event fails closed" $? "rc=$rc"
run_script "$TMP/absent.json" absent no
exited 2; report "a missing event file fails closed" $? "rc=$rc"
jq -n '{action: "opened", issue: {number: 7}}' > "$TMP/not-a-pr.json"
run_script "$TMP/not-a-pr.json" absent no
exited 2; report "an event without a pull request fails closed" $? "rc=$rc"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
