#!/usr/bin/env bash
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cli="$plugin/scripts/validate-audit-dossier.sh"
# shellcheck source=../../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh"
# shellcheck source=../../.agents/lib/audit-reflection.sh
source "$plugin/.agents/lib/audit-reflection.sh"
# shellcheck source=../../.agents/lib/audit-reflection-gate.sh
source "$plugin/.agents/lib/audit-reflection-gate.sh"
# shellcheck source=../audit/fixtures/audit-reflection-fixture.sh
source "$plugin/tests/audit/fixtures/audit-reflection-fixture.sh"
scratch="$(mktemp -d)"
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
repo="$scratch/read only repository"
mkdir -p "$repo"
checks=0
expect() { # status, diagnostic substring, command...
  local wanted="$1" message="$2" status=0; shift 2
  "$@" >"$scratch/out" 2>"$scratch/err" || status=$?
  if [[ "$status" != "$wanted" ]] || { [[ -n "$message" ]] && ! grep -Fq "$message" "$scratch/err"; }; then
    printf 'FAIL: expected %s (%s), got %s: %s\n' "$wanted" "$message" "$status" "$(cat "$scratch/err")" >&2
    exit 1
  fi
  if [[ "$wanted" == 0 ]]; then
    jq -e '.valid == true and (.scope == "history" or .scope == "shape")' "$scratch/out" >/dev/null
    [[ ! -s "$scratch/err" ]]
  else
    [[ ! -s "$scratch/out" ]]
  fi
  checks=$((checks + 1))
}
prepare() { # kind, epoch
  kind="$1"
  context="$(jq -nc --arg root "$repo" --arg kind "$kind" --arg epoch "$2" \
    '{repo_root:$root,session:"s",epoch:$epoch,branch:"main",gate:$kind}')"
  binding="$(jq -nc --arg kind "$kind" '
    {branch:"main",head:("a"*40)} + if $kind == "verdict" then
      {tree_hash:("b"*40),generation:"g"} else
      {command_kind:$kind,diff_hash:("c"*64),command_hash:("d"*64),commit_subject_hash:""} end')"
  request="$(audit_reflection_gate "$context" prepare first "$(jq -nc --argjson binding "$binding" \
    '{binding:$binding,snapshot:{transcript:[],tree:"captured tree"},deadline:4102444800}')")"
  history="$(jq -r .history_path <<<"$request")"
  state="$(jq -r .state_path <<<"$request")"
  candidate="$repo/candidate.json"
  jq '.attempts[-1].input.binding + {verdict:"PASS",findings:[],advisories:[],
      history_review:{attempt_id:.attempts[-1].id,history_hash,dispositions:[],findings:[],
        coverage:{reviewed:(.attempts[-1].input.snapshot|keys),unread:[]}}} |
      if has("tree_hash") then .proof=[] else . end' "$history" >"$candidate"
}
change() { jq "$1" "$candidate" >"$scratch/changed.json"; }
# Hashes and directory entries include every persisted state file and mutex.
snapshot() { (cd "$repo" && find . -print | sort && find . -type f -exec shasum -a 256 {} \; | sort); }

for kind in verdict commit push; do
  prepare "$kind" "$kind"
  before="$(snapshot)"
  expect 0 '' bash "$cli" "$kind" "$history" "$candidate"
  expect 0 '' bash "$cli" "$kind" "$history" - <"$candidate"
  if command -v sandbox-exec >/dev/null 2>&1; then
    expect 0 '' sandbox-exec -p '(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null"))' \
      /bin/bash "$cli" "$kind" "$history" - <"$candidate"
  fi
  [[ "$(snapshot)" == "$before" ]]
  for mutation in '.advisories=["low: note"]' '.reflection_review=null'; do
    change "$mutation"
    expect 0 '' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  done
  # Verdict dossiers may omit advisories; Git dossiers always carry them.
  change 'del(.advisories)'
  expect "$([[ "$kind" == verdict ]] && echo 0 || echo 1)" '' \
    bash "$cli" "$kind" "$history" "$scratch/changed.json"
  for mutation in '.findings=["high: unresolved"]' '.verdict="FAIL"' '.unexpected=true'; do
    change "$mutation"
    expect 1 '' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  done
  change '.history_review.coverage.reviewed=["transcript"]'
  expect 1 'coverage missing=["tree"]' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.coverage.unread=["tree"]'
  expect 1 'duplicated=["tree"]' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.coverage.reviewed += ["invented"]'
  expect 1 'unexpected=["invented"]' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.coverage={reviewed:["transcript"],unread:["tree"]}'
  expect 1 'PASS has unresolved history or unread evidence' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.head=("f"*40)'
  expect 1 'binding mismatch' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.attempt_id="stale"'
  expect 1 'history_review.attempt_id' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.history_hash=("0"*64)'
  expect 1 'stale history review' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  change '.history_review.dispositions=[{id:"F1",status:"resolved",evidence:"unknown"}]'
  expect 1 'history_review.dispositions' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  expect 1 'history assessments require' bash "$cli" "$kind" - "$candidate"
  change 'del(.history_review,.reflection_review)'
  expect 0 '' bash "$cli" "$kind" - "$scratch/changed.json"
  if command -v sandbox-exec >/dev/null 2>&1; then
    expect 0 '' sandbox-exec -p '(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null"))' \
      /bin/bash "$cli" "$kind" - - <"$scratch/changed.json"
  fi
  if [[ "$kind" != verdict ]]; then
    change '.command_kind=(if .command_kind=="push" then "commit" else "push" end)'
    expect 1 'command_kind' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  else
    change '.verdict="IN_PROGRESS" | .findings=["waiting for input"] |
      .history_review.coverage={reviewed:["transcript"],unread:["tree"]}'
    expect 0 '' bash "$cli" "$kind" "$history" "$scratch/changed.json"
  fi
  [[ "$(snapshot)" == "$before" ]]
  # Candidate validation does not authorize a mutated dossier at the parent gate.
  change '.head=("f"*40)'
  if audit_reflection_gate "$context" record first "$(cat "$scratch/changed.json")" >"$scratch/out" 2>"$scratch/err"; then
    printf 'FAIL: parent accepted changed binding after valid preflight\n' >&2; exit 1
  fi
  [[ "$(snapshot)" == "$before" ]]
  audit_reflection_gate "$context" record first "$(cat "$candidate")" >/dev/null
  jq -e '.attempts[-1].outcome.verdict == "PASS"' "$state" >/dev/null
  expect 1 'pending attempt' bash "$cli" "$kind" "$state" "$candidate"
done

# Registry IDs and statuses come from the production record transition.
prepare verdict findings
change '.verdict="FAIL" | .findings=["high: missing proof"] |
  .history_review.findings=[{id:"NEW",invariant:"evidence complete",behavior:"delivery",
    criterion:"proof recorded",evidence:"required check absent",origin:"existing",
    origin_evidence:"first audit",review_gap:"",review_change:"",reopening:null,conflict:null,criterion_change:null}]'
expect 0 '' bash "$cli" verdict "$history" "$scratch/changed.json"
audit_reflection_gate "$context" record first "$(cat "$scratch/changed.json")" >/dev/null
input="$(jq -c '.attempts[-1].input|{binding,snapshot,deadline}' "$history")"
request="$(audit_reflection_gate "$context" prepare retry "$input")"
history="$(jq -r .history_path <<<"$request")"
jq --slurpfile h "$history" '.history_review.attempt_id="retry" | .history_review.history_hash=$h[0].history_hash |
  .history_review.dispositions=[$h[0].registry[] | {id,status:"resolved",evidence:"check now completed"}]' \
  "$candidate" >"$scratch/resolved.json"
expect 0 '' bash "$cli" verdict "$history" "$scratch/resolved.json"
jq '.history_review.dispositions[0].status="open"' "$scratch/resolved.json" >"$scratch/open.json"
expect 1 'unresolved history' bash "$cli" verdict "$history" "$scratch/open.json"
jq '.verdict="FAIL" | .findings=["high: still missing"]' "$scratch/open.json" >"$scratch/fail.json"
expect 0 '' bash "$cli" verdict "$history" "$scratch/fail.json"

prepare verdict boundaries
before="$(snapshot)"
chmod 444 "$candidate" "$history"
chmod 555 "$repo/.agents/state" "$repo/.agents" "$repo"
expect 0 '' bash "$cli" verdict "$history" "$candidate"
[[ "$(snapshot)" == "$before" ]]
chmod 755 "$repo" "$repo/.agents" "$repo/.agents/state"
chmod 644 "$candidate" "$history"
for bad in missing directory symlink fifo; do
  path="$scratch/$bad"
  case "$bad" in
    directory) mkdir "$path" ;;
    symlink) ln -s "$candidate" "$path" ;;
    fifo) mkfifo "$path" ;;
  esac
  expect 2 'readable regular file' bash "$cli" verdict "$history" "$path"
  expect 2 'readable regular file' bash "$cli" verdict "$path" "$candidate"
done
printf '{}\0' >"$scratch/nul"
expect 2 'without NUL' bash "$cli" verdict - "$scratch/nul"
expect 2 'contains NUL' bash "$cli" verdict - - <"$scratch/nul"
printf '{} {}' >"$scratch/multiple"
expect 1 'shape' bash "$cli" verdict - - <"$scratch/multiple"
perl -e 'print " " x 1048577' >"$scratch/large"
expect 2 'at most 1 MiB' bash "$cli" verdict - "$scratch/large"
expect 2 'oversized' bash "$cli" verdict - - <"$scratch/large"
perl -e 'print " " x 10485761' >"$scratch/large-history"
expect 2 'at most 10 MiB' bash "$cli" verdict "$scratch/large-history" "$candidate"
jq '.history_hash=("0"*64)' "$history" >"$scratch/corrupt-history"
expect 1 'checksum' bash "$cli" verdict "$scratch/corrupt-history" "$candidate"
expect 2 'usage:' bash "$cli" wrong -

# Two real ERROR transitions require an independent reflection assessment on retry.
retry_input="$(jq -c '.attempts[-1].input|{binding,snapshot,deadline}' "$history")"
audit_reflection_gate "$context" error first '"transport"' >/dev/null
audit_reflection_gate "$context" prepare second "$retry_input" >/dev/null
audit_reflection_gate "$context" error second '"transport"' >/dev/null
audit_test_reflection "$state" | bash "$plugin/scripts/audit-reflection.sh" submit "$state" >/dev/null
request="$(audit_reflection_gate "$context" prepare retry "$retry_input")"
history="$(jq -r .history_path <<<"$request")"
jq --slurpfile h "$history" '.history_review.attempt_id="retry" | .history_review.history_hash=$h[0].history_hash' \
  "$candidate" >"$scratch/retry.json"
expect 1 'reflection assessment' bash "$cli" verdict "$history" "$scratch/retry.json"
jq --argjson assessment "$(audit_test_assessment "$history")" '.reflection_review=$assessment' \
  "$scratch/retry.json" >"$scratch/assessed.json"
expect 0 '' bash "$cli" verdict "$history" "$scratch/assessed.json"
if command -v sandbox-exec >/dev/null 2>&1; then
  expect 0 '' sandbox-exec -p '(version 1) (allow default) (deny file-write*) (allow file-write* (literal "/dev/null"))' \
    /bin/bash "$cli" verdict "$history" - <"$scratch/assessed.json"
fi
jq '.reflection_review.assessment="insufficient"' "$scratch/assessed.json" >"$scratch/insufficient.json"
expect 1 'sufficient reflection' bash "$cli" verdict "$history" "$scratch/insufficient.json"
printf 'PASS: %s dossier, history, parent, and read-only boundary checks\n' "$checks"
