#!/usr/bin/env bash
# Exercise the public gate with a recording GitHub API double, without remote writes.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$PLUGIN_ROOT/scripts/pr-author-review.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
OLD_SHA=1111111111111111111111111111111111111111
BASE_REPO=boxlite-ai/agent-tooling
pass=0
fail=0
rc=0

cat > "$TEST_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
method=GET
endpoint=""
filter="."
shift
while (( $# )); do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --jq) filter="$2"; shift 2 ;;
    --input) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
body=null
[[ "$method" == GET ]] || body="$(cat)"
jq -nc --arg method "$method" --arg endpoint "$endpoint" --argjson body "$body" \
  '{method:$method,endpoint:$endpoint,body:$body}' >> "$STUB_DIR/calls"
if [[ "$endpoint" == *"${STUB_ERROR_ENDPOINT:-__never__}"* && "$method" == "${STUB_ERROR_METHOD:-$method}" ]]; then
  printf 'gh: Server Error (HTTP 500)\n' >&2
  exit 1
fi
if [[ -n "${STUB_ERROR_STATUS:-}" && "$(jq -r '.state // ""' <<<"$body")" == "$STUB_ERROR_STATUS" ]]; then
  printf 'gh: Server Error (HTTP 500)\n' >&2
  exit 1
fi
case "$method $endpoint" in
  "GET repos/boxlite-ai/agent-tooling/pulls/7")
    count=0
    [[ ! -f "$STUB_DIR/pr-reads" ]] || count="$(cat "$STUB_DIR/pr-reads")"
    count=$((count + 1)); printf '%s' "$count" > "$STUB_DIR/pr-reads"
    if [[ -f "$STUB_DIR/pr-$count.json" ]]; then
      jq -r "$filter" "$STUB_DIR/pr-$count.json"
    elif (( count > 1 )) && [[ -f "$STUB_DIR/pr-next.json" ]]; then
      jq -r "$filter" "$STUB_DIR/pr-next.json"
    else
      jq -r "$filter" "$STUB_DIR/pr.json"
    fi
    ;;
  "GET repos/boxlite-ai/agent-tooling/issues/7/comments?"*)
    page="${endpoint##*&page=}"
    if [[ -f "$STUB_DIR/comments-$page.json" ]]; then
      cat "$STUB_DIR/comments-$page.json"
    else
      printf '[]\n'
    fi
    ;;
  "GET repos/boxlite-ai/agent-tooling/issues/comments/"*)
    if [[ -f "$STUB_DIR/comment-live.json" ]]; then
      cat "$STUB_DIR/comment-live.json"
    else
      id="${endpoint##*/}"
      jq -s --argjson id "$id" 'add | .[] | select(.id == $id)' "$STUB_DIR"/comments-*.json
    fi
    ;;
  "GET repos/boxlite-ai/agent-tooling/commits/"*"/pulls?"*)
    cat "$STUB_DIR/associated.json"
    ;;
  "POST repos/boxlite-ai/agent-tooling/statuses/"*) printf '{}\n' ;;
  "POST repos/boxlite-ai/agent-tooling/issues/7/comments") printf '{"id":90}\n' ;;
  "PATCH repos/boxlite-ai/agent-tooling/issues/comments/"*) printf '{}\n' ;;
  "POST graphql")
    if [[ -f "$STUB_DIR/draft-response.json" ]]; then
      cat "$STUB_DIR/draft-response.json"
    else
      printf '{"data":{"convertPullRequestToDraft":{"pullRequest":{"id":"PR_test","isDraft":true}}}}\n'
    fi
    ;;
  *) printf 'unexpected API operation: %s %s\n' "$method" "$endpoint" >&2; exit 3 ;;
esac
STUB
chmod +x "$TEST_DIR/gh"

reset_case() {
  rm -f "$TEST_DIR"/*.json "$TEST_DIR/calls" "$TEST_DIR/pr-reads"
  jq -n --arg sha "$HEAD_SHA" --arg repo "$BASE_REPO" '
    {number:7,state:"open",node_id:"PR_test",draft:false,author_association:"CONTRIBUTOR",
     user:{id:42,login:"author",type:"User"},base:{repo:{full_name:$repo}},
     head:{sha:$sha,ref:"feature",repo:{full_name:"contributor/agent-tooling"}}}' > "$TEST_DIR/pr.json"
  jq -n --arg sha "$OLD_SHA" --arg repo "$BASE_REPO" '
    {action:"opened",repository:{full_name:$repo},pull_request:{number:7,
     head:{sha:$sha,ref:"feature",repo:{full_name:"contributor/agent-tooling"}}}}' > "$TEST_DIR/event.json"
  printf '[]\n' > "$TEST_DIR/comments-1.json"
  printf '[]\n' > "$TEST_DIR/associated.json"
}

acknowledge() {
  jq -n --arg body "${1:-/reviewed $HEAD_SHA}" '
    [{id:80,user:{id:42,login:"author",type:"User"},body:$body,
      created_at:"2026-09-20T00:00:00Z",updated_at:"2026-09-20T00:00:00Z"}]' > "$TEST_DIR/comments-1.json"
}

run_gate() {
  env STUB_DIR="$TEST_DIR" GH_BIN="$TEST_DIR/gh" "$@" \
    bash "$SCRIPT" "$TEST_DIR/event.json" > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr"
  rc=$?
}

report() {
  if "$2"; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (exit=%s)\n' "$1" "$rc"
    cat "$TEST_DIR/stderr"
  fi
}

pending() {
  [[ "$rc" == 1 ]] && jq -se --arg sha "$HEAD_SHA" '
    [.[] | select(.endpoint == "repos/boxlite-ai/agent-tooling/statuses/" + $sha)] |
    length > 0 and .[-1].body.state == "pending" and
    .[-1].body.context == "Author reviewed the PR"' "$TEST_DIR/calls" >/dev/null
}

acknowledged() {
  [[ "$rc" == 0 ]] && jq -se --arg sha "$HEAD_SHA" '
    [.[] | select(.endpoint == "repos/boxlite-ai/agent-tooling/statuses/" + $sha)] |
    length == 2 and .[0].body.state == "pending" and .[1].body.state == "success" and
    .[1].body.context == "Author reviewed the PR"' "$TEST_DIR/calls" >/dev/null
}

no_success() {
  jq -se 'all(.[]; .body.state != "success")' "$TEST_DIR/calls" >/dev/null
}

failed_closed() { [[ "$rc" == 2 ]] && no_success; }
skipped() { [[ "$rc" == 0 && ! -e "$TEST_DIR/calls" ]]; }
invalid_event() { [[ "$rc" == 2 && ! -e "$TEST_DIR/calls" ]]; }

comment_event() {
  jq -n --arg repo "$BASE_REPO" --arg action "${1:-created}" --arg sha "$OLD_SHA" '
    {action:$action,repository:{full_name:$repo},issue:{number:7,pull_request:{}},
     comment:{id:80,user:{id:42,type:"User"},body:("/reviewed " + $sha)}}' > "$TEST_DIR/event.json"
}

edit_json() { # file, jq transformation
  jq "$2" "$1" > "$TEST_DIR/edited.json" && mv "$TEST_DIR/edited.json" "$1"
}

only_pr_metadata_writes() {
  jq -se 'all(.[]; .method == "GET" or
    (.endpoint | test("^repos/boxlite-ai/agent-tooling/(statuses/[0-9a-f]{40}|issues/7/comments|issues/comments/[0-9]+)$")) or
    (.method == "POST" and .endpoint == "graphql" and
      (.body.query | contains("convertPullRequestToDraft")) and
      (.body.query | contains("markPullRequestReadyForReview") | not)))' \
    "$TEST_DIR/calls" >/dev/null
}

draft_requested() {
  jq -se '[.[] | select(.method == "POST" and .endpoint == "graphql")] |
    length == 1 and (.[0].body.query | contains("convertPullRequestToDraft")) and
    .[0].body.variables.input.pullRequestId == "PR_test"' "$TEST_DIR/calls" >/dev/null
}

drafted() { pending && draft_requested; }
no_draft_write() { jq -se 'all(.[]; .endpoint != "graphql")' "$TEST_DIR/calls" >/dev/null; }
pending_without_draft_write() { pending && no_draft_write; }
acknowledged_without_draft_write() { acknowledged && no_draft_write; }

prompt_has_live_sha() {
  jq -se --arg sha "$HEAD_SHA" --arg old "$OLD_SHA" '
    [.[] | select(.method == "POST" and (.endpoint | endswith("/comments")))] |
    length == 1 and (.[0].body.body | contains("/reviewed " + $sha)) and
    (.[0].body.body | contains($old) | not)' "$TEST_DIR/calls" >/dev/null
}

reset_case
run_gate
report "an external fork without acknowledgment stays pending" pending
report "instructions name the live SHA instead of the event SHA" prompt_has_live_sha
report "an unacknowledged fork PR is converted to draft" drafted
report "the gate writes only PR comments, statuses, and draft state" only_pr_metadata_writes
pending_before_draft() {
  jq -se '.[1].body.state == "pending" and
    ([.[] | .endpoint] | index("graphql")) > 1' "$TEST_DIR/calls" >/dev/null
}
report "pending status is published before drafting" pending_before_draft
prompt_explains_ready() {
  jq -se 'any(.[]; .method == "POST" and (.endpoint | endswith("/comments")) and
    (.body.body | contains("Ready for review")))' "$TEST_DIR/calls" >/dev/null
}
report "instructions explain how to leave draft after acknowledging" prompt_explains_ready

reset_case
edit_json "$TEST_DIR/pr.json" '.draft = true'
run_gate
report "an existing draft stays pending without another draft mutation" pending_without_draft_write

reset_case
edit_json "$TEST_DIR/event.json" '.action = "ready_for_review"'
run_gate
report "marking ready without acknowledgment returns the PR to draft" drafted

reset_case
acknowledge
run_gate
report "a reviewed ready PR is not drafted" acknowledged_without_draft_write

reset_case
edit_json "$TEST_DIR/pr.json" '.draft = true'
acknowledge
run_gate
report "acknowledgment preserves a draft until its author marks ready" acknowledged_without_draft_write

reset_case
run_gate STUB_ERROR_ENDPOINT=graphql
report "a failed draft mutation fails the handler and leaves pending status" failed_closed

for response in '{}' \
  '{"data":{"convertPullRequestToDraft":{"pullRequest":{"id":"PR_test","isDraft":false}}}}' \
  '{"data":{"convertPullRequestToDraft":{"pullRequest":{"id":"another_PR","isDraft":true}}}}' \
  '{"errors":[{"message":"denied"}],"data":{"convertPullRequestToDraft":{"pullRequest":{"id":"PR_test","isDraft":true}}}}'; do
  reset_case
  printf '%s\n' "$response" > "$TEST_DIR/draft-response.json"
  run_gate
  report "an unconfirmed draft conversion fails closed: $response" failed_closed
done

for invalid in '.node_id = ""' '.node_id = null' '.draft = "false"' 'del(.draft)'; do
  reset_case
  edit_json "$TEST_DIR/pr.json" "$invalid"
  run_gate
  report "invalid draft identity/state fails before mutation: $invalid" failed_closed
done

reset_case
jq -n --arg repo "$BASE_REPO" '{repository:{full_name:$repo},inputs:{pr_number:"7"}}' > "$TEST_DIR/event.json"
run_gate
report "manual dispatch payloads are no longer accepted" invalid_event

reset_case
comment_event created
edit_json "$TEST_DIR/event.json" '.comment.body = "/recheck-author-review"'
run_gate
report "a human recheck comment publishes instructions without acknowledging" pending

reset_case
comment_event created
edit_json "$TEST_DIR/event.json" '.comment.user.type = "Bot"'
run_gate
report "new bot comments are ignored before GitHub calls" skipped

reset_case
comment_event deleted
edit_json "$TEST_DIR/event.json" '.comment.user.type = "Bot"'
run_gate
report "deleting the bot instructions recreates the live-head prompt" prompt_has_live_sha

reset_case
jq -n --arg repo "$BASE_REPO" --arg sha "$HEAD_SHA" \
  '{action:"checks_requested",repository:{full_name:$repo},merge_group:{head_sha:$sha}}' > "$TEST_DIR/event.json"
run_gate
queue_acknowledged() {
  [[ "$rc" == 0 ]] && jq -se --arg sha "$HEAD_SHA" '
    length == 1 and .[0].method == "POST" and
    .[0].endpoint == "repos/boxlite-ai/agent-tooling/statuses/" + $sha and
    .[0].body.state == "success" and .[0].body.context == "Author reviewed the PR"' "$TEST_DIR/calls" >/dev/null
}
report "queue commits carry forward the required PR admission check" queue_acknowledged
run_gate STUB_ERROR_STATUS=success
queue_write_failed() { [[ "$rc" == 2 ]] && grep -q 'could not publish queue status' "$TEST_DIR/stderr"; }
report "queue status write errors fail the handler" queue_write_failed

for invalid in \
  '{"repository":{"full_name":"boxlite-ai/agent-tooling"},"inputs":{"pr_number":"7/../8"}}' \
  '{"repository":{"full_name":"boxlite-ai/agent-tooling"},"inputs":{"pr_number":"0"}}' \
  '{"repository":{"full_name":"boxlite-ai/agent-tooling"},"merge_group":{"head_sha":"bad"},"action":"checks_requested"}' \
  '{"repository":{"full_name":"boxlite-ai/agent-tooling"},"merge_group":{"head_sha":"0123456789abcdef0123456789abcdef01234567"},"action":"destroyed"}'; do
  reset_case
  printf '%s\n' "$invalid" > "$TEST_DIR/event.json"
  run_gate
  report "invalid dispatch or queue events fail before GitHub: $invalid" invalid_event
done

reset_case
edit_json "$TEST_DIR/pr.json" '.head.repo.full_name = "boxlite-ai/agent-tooling"'
run_gate
report "same-repository PRs require the same acknowledgment" pending
report "an unacknowledged same-repository PR is also drafted" drafted

for action in created edited deleted; do
  reset_case
  comment_event "$action"
  acknowledge
  run_gate
  report "$action events recompute from live comments, not the payload body" acknowledged
done

for body in "/reviewed $OLD_SHA" '/reviewed 0123456' "I say /reviewed $HEAD_SHA" \
  "/reviewed $HEAD_SHA extra" "/reviewed  $HEAD_SHA"; do
  reset_case
  acknowledge "$body"
  run_gate
  report "only the exact command for the current full SHA counts: $body" pending
done

reset_case
acknowledge $'  /reviewed '"$HEAD_SHA"$'\r\n'
run_gate
report "surrounding whitespace is harmless" acknowledged

for transformation in '.[0].user.id = 43' '.[0].user.type = "Bot"' \
  '.[0].updated_at = "2026-09-20T00:01:00Z"'; do
  reset_case
  acknowledge
  edit_json "$TEST_DIR/comments-1.json" "$transformation"
  run_gate
  report "another author, a bot, or an edited comment cannot acknowledge: $transformation" pending
done

reset_case
acknowledge
edit_json "$TEST_DIR/pr.json" '.user.type = "Bot"'
run_gate
report "a bot PR is not silently exempted" pending

reset_case
comment_event deleted
run_gate
report "deleting the only acknowledgment revokes success" pending
report "deleting the only acknowledgment drafts the PR" drafted

reset_case
acknowledge
jq '.[0] | .body = "withdrawn"' "$TEST_DIR/comments-1.json" > "$TEST_DIR/comment-live.json"
run_gate
report "an acknowledgment changed since pagination does not pass" pending
report "an edited acknowledgment drafts the PR" drafted

reset_case
acknowledge
mv "$TEST_DIR/comments-1.json" "$TEST_DIR/comments-2.json"
jq -n '[range(1;101) | {id:.,user:{id:43,type:"User"},body:"unrelated"}]' > "$TEST_DIR/comments-1.json"
run_gate
report "an acknowledgment on the second page is found" acknowledged

reset_case
for page in $(seq 1 10); do
  jq -n '[range(1;101) | {id:.,body:"unrelated"}]' > "$TEST_DIR/comments-$page.json"
done
run_gate
report "a full 1000-comment scan fails closed instead of silently truncating" failed_closed

reset_case
acknowledge
jq -n --arg sha "$HEAD_SHA" '[{number:8,state:"open",head:{sha:$sha}}]' > "$TEST_DIR/associated.json"
run_gate
report "another open PR sharing the head cannot inherit this acknowledgment" pending
report "an acknowledgment blocked by a shared head keeps the PR in draft" drafted

reset_case
acknowledge
jq -n --arg sha "$HEAD_SHA" '[{number:8,state:"closed",head:{sha:$sha}}]' > "$TEST_DIR/associated.json"
run_gate
report "a closed PR sharing the head does not block acknowledgment" acknowledged

reset_case
acknowledge
jq --arg sha "$OLD_SHA" '.head.sha = $sha' "$TEST_DIR/pr.json" > "$TEST_DIR/pr-next.json"
run_gate
head_change_pending() {
  [[ "$rc" == 1 ]] && no_success && jq -se --arg sha "$OLD_SHA" '
    any(.[]; .endpoint == "repos/boxlite-ai/agent-tooling/statuses/" + $sha and .body.state == "pending")' \
    "$TEST_DIR/calls" >/dev/null
}
report "a head change during evaluation requires acknowledgment of the new head" head_change_pending
report "an unacknowledged replacement head drafts the PR" draft_requested

reset_case
for read_count in $(seq 1 6); do
  sha="$(printf '%040d' "$read_count")"
  jq --arg sha "$sha" '.head.sha = $sha' "$TEST_DIR/pr.json" > "$TEST_DIR/pr-$read_count.json"
done
run_gate
report "continuously changing heads stop after three attempts" failed_closed

# Capture a production-generated prompt, then feed it back as an existing bot comment.
reset_case
run_gate
jq -s '[.[] | select(.method == "POST" and (.endpoint | endswith("/comments"))) |
  {id:90,user:{id:41898282,login:"github-actions[bot]",type:"Bot"},body:.body.body}]' \
  "$TEST_DIR/calls" > "$TEST_DIR/comments-1.json"
edit_json "$TEST_DIR/pr.json" '.draft = true'
rm "$TEST_DIR/calls" "$TEST_DIR/pr-reads"
run_gate
no_prompt_write() {
  pending && jq -se 'all(.[]; .method == "GET" or (.endpoint | contains("/statuses/")))' "$TEST_DIR/calls" >/dev/null
}
report "an unchanged bot prompt is neither duplicated nor edited" no_prompt_write

comment_event edited
edit_json "$TEST_DIR/event.json" '.comment.user.type = "Bot"'
edit_json "$TEST_DIR/comments-1.json" '.[0].body += " outdated"'
rm "$TEST_DIR/calls" "$TEST_DIR/pr-reads"
run_gate
patched_prompt() {
  pending && jq -se 'any(.[]; .method == "PATCH" and .endpoint == "repos/boxlite-ai/agent-tooling/issues/comments/90")' \
    "$TEST_DIR/calls" >/dev/null
}
report "editing the bot instructions repairs the prompt in place" patched_prompt

edit_json "$TEST_DIR/comments-1.json" '.[0].user = {id:43,login:"github-actions[bot]",type:"User"}'
rm "$TEST_DIR/calls" "$TEST_DIR/pr-reads"
run_gate
no_forged_prompt_edit() {
  pending && jq -se 'all(.[]; .method != "PATCH")' "$TEST_DIR/calls" >/dev/null
}
report "a human cannot impersonate the bot prompt" no_forged_prompt_edit

for endpoint in '/pulls/7' '/statuses/' '/issues/7/comments?' '/issues/comments/80' '/pulls?'; do
  reset_case
  acknowledge
  run_gate "STUB_ERROR_ENDPOINT=$endpoint"
  report "API errors fail closed: $endpoint" failed_closed
done

reset_case
run_gate STUB_ERROR_ENDPOINT='/issues/7/comments' STUB_ERROR_METHOD=POST
report "a failed instruction comment leaves the status pending" failed_closed
report "a failed instruction comment does not prevent drafting" draft_requested

reset_case
acknowledge
run_gate STUB_ERROR_STATUS=success
success_write_failed() { [[ "$rc" == 2 ]] && grep -q 'could not publish success' "$TEST_DIR/stderr"; }
report "a failed success-status write is reported as an API error" success_write_failed

reset_case
acknowledge
printf '{}\n' > "$TEST_DIR/associated.json"
run_gate
report "a malformed associated-PR response cannot grant success" failed_closed

for invalid in '{}' '{"number":7,"head":{"sha":"bad"}}'; do
  reset_case
  printf '%s\n' "$invalid" > "$TEST_DIR/pr.json"
  run_gate
  report "invalid live PR state fails closed: $invalid" failed_closed
done

reset_case
printf '{"message":"not a comment list"}\n' > "$TEST_DIR/comments-1.json"
run_gate
report "a malformed comment response cannot pass" failed_closed

reset_case
edit_json "$TEST_DIR/pr.json" '.state = "closed"'
run_gate
closed_skipped() { [[ "$rc" == 0 ]] && jq -se 'all(.[]; .method == "GET")' "$TEST_DIR/calls" >/dev/null; }
report "closed PRs receive no writes" closed_skipped

reset_case
printf '{"action":"created","issue":{"number":7}}\n' > "$TEST_DIR/event.json"
run_gate
report "ordinary issue comments are ignored" skipped

for invalid in '{bad' '{}' '{"repository":{"full_name":"../repo"},"pull_request":{"number":7},"action":"opened"}' \
  '{"repository":{"full_name":"owner/repo"},"pull_request":{"number":0},"action":"opened"}' \
  '{"repository":{"full_name":"owner/repo"},"pull_request":{"number":7},"action":"unknown"}'; do
  reset_case
  printf '%s\n' "$invalid" > "$TEST_DIR/event.json"
  run_gate
  report "invalid events fail before GitHub: $invalid" invalid_event
done

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
