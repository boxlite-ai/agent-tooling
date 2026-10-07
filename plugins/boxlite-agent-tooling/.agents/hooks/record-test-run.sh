#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# PostToolUse / PostToolUseFailure hook: record each test run the agent executes,
# so commit-push-auditor can see it.
# Tests: bash .agents/hooks/audit/record-test-run.test.sh
#
# The workflow asks the author to run each new test against reverted production code,
# then against the fix. The auditor is denied the parent's history and has no time for
# VM or SDK suites, so without a record it can only guess. This hook writes what the
# host reports about the run: the exact command, how it ended, HEAD, and the tree of
# the working files. The auditor matches that tree to the staged one, or diffs a red
# run's tree against it. The agent never writes these receipts.
#
# Only a single `make test...` invocation counts. Behind `;`, `&&`, a pipe or a
# background job, the status the host reports is no longer the test's. Claude reports
# success as PostToolUse and failure as PostToolUseFailure; Codex reports both as
# PostToolUse with an exit code. Every failure path exits 0: a missing receipt only
# leaves a run unobserved.
set -uo pipefail

state_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/verdict-audit-state.sh"
for required_command in jq perl git; do
  command -v "$required_command" >/dev/null 2>&1 || exit 0
done
[[ -r "$state_lib" ]] || exit 0
# shellcheck source=../lib/verdict-audit-state.sh
source "$state_lib" || exit 0

receipt_limit=100

payload="$(cat)"
event="$(jq -r 'if type == "object" then .hook_event_name // "" else "" end' \
  <<<"$payload" 2>/dev/null)" || exit 0
case "$event" in PostToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac
command="$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)" || exit 0
[[ "$(jq -r '.tool_input.run_in_background // false' <<<"$payload" 2>/dev/null)" == false ]] \
  || exit 0

# One `make` of test targets, optionally behind `env -u NAME` and NAME=value
# assignments, with only plain output redirections after it.
perl -e '
  my $c = $ARGV[0];
  exit 1 if length($c) > 4096;
  my @words;
  my ($w, $in_word, $q) = ("", 0, "");
  for my $ch (split //, $c) {
    if ($q) { if ($ch eq $q) { $q = "" } else { exit 1 if $q eq "\"" && $ch =~ /[\$`\\]/; $w .= $ch } next }
    if ($ch eq "\x27" || $ch eq "\"") { $q = $ch; $in_word = 1; next }
    if ($ch =~ /\s/) { push @words, $w if $in_word; ($w, $in_word) = ("", 0); next }
    exit 1 if $ch =~ /[;|<()\$`\\\n]/;
    $w .= $ch; $in_word = 1;
  }
  exit 1 if $q;
  push @words, $w if $in_word;
  my $i = 0;
  if (@words && $words[0] eq "env") {
    $i++;
    while ($i < @words && $words[$i] eq "-u") { $i += 2 }
  }
  $i++ while $i < @words && $words[$i] =~ /\A[A-Za-z_][A-Za-z0-9_]*=/;
  exit 1 unless $i < @words && $words[$i] eq "make";
  $i++;
  my $targets = 0;
  while ($i < @words) {
    my $t = $words[$i++];
    if ($t =~ /\Atest(?::[A-Za-z0-9_.:-]+)?\z/) { $targets++; next }
    next if $t =~ /\A[A-Za-z_][A-Za-z0-9_]*=/;
    next if $t eq "2>&1";
    if ($t =~ /\A(?:2)?>>?\z/) { exit 1 unless $i < @words; $i++; next }
    next if $t =~ /\A(?:2)?>>?[^&>]/;
    exit 1;
  }
  exit($targets ? 0 : 1);
' -- "$command" || exit 0

# A command the host moved to the background has not finished; its status is not the
# test's.
if jq -e '(.tool_response | type) == "object"
          and (.tool_response | keys | any(test("background"; "i")))' \
     <<<"$payload" >/dev/null 2>&1; then
  exit 0
fi
response_text="$(jq -r 'if (.tool_response | type) == "string" then .tool_response
  else (.tool_response.stdout // .tool_response.output // "") end' \
  <<<"$payload" 2>/dev/null || true)"
[[ "$response_text" != *"moved to the background"* ]] || exit 0

exit_code="null"
if [[ "$event" == PostToolUseFailure ]]; then
  if [[ "$(jq -r '.is_interrupt // false' <<<"$payload" 2>/dev/null)" == true ]]; then
    status=interrupted
  else
    status=fail
  fi
  exit_code="$(jq -r '(.error // "") | tostring | capture("Exit code (?<n>[0-9]{1,3})").n // "null"' \
    <<<"$payload" 2>/dev/null || printf 'null')"
  [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || exit_code="null"
else
  exit_code="$(jq -r 'if (.tool_response | type) == "object"
    and (.tool_response.exit_code | type) == "number"
    then .tool_response.exit_code else "null" end' <<<"$payload" 2>/dev/null || printf 'null')"
  [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || exit_code="null"
  if [[ "$exit_code" == null || "$exit_code" == 0 ]]; then status=pass; else status=fail; fi
fi

cwd="$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null || true)"
[[ -n "$cwd" && -d "$cwd" ]] || cwd="$PWD"
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || exit 0

# The tree of the working files, through a scratch index so the real one is untouched.
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-run.XXXXXX")" || exit 0
scratch_index="$scratch_dir/index"
trap 'rm -f "$scratch_index"; rmdir "$scratch_dir" 2>/dev/null' EXIT
GIT_INDEX_FILE="$scratch_index" git -C "$repo_root" read-tree HEAD 2>/dev/null || exit 0
GIT_INDEX_FILE="$scratch_index" git -C "$repo_root" add -A 2>/dev/null || exit 0
tree="$(GIT_INDEX_FILE="$scratch_index" git -C "$repo_root" write-tree 2>/dev/null)" || exit 0

# Beside the commit gate's dossier, which lives under the project directory.
project_dir="${CLAUDE_PROJECT_DIR:-$repo_root}"
receipt_dir="$project_dir/.agents/state/test-runs"
[[ ! -L "$project_dir/.agents" && ! -L "$project_dir/.agents/state" && ! -L "$receipt_dir" ]] \
  || exit 0
mkdir -p "$receipt_dir" 2>/dev/null || exit 0
now="$(date +%s)"
receipt="$receipt_dir/$now-$$-${RANDOM:-0}.json"
jq -nc --argjson now "$now" --arg event "$event" --arg status "$status" \
  --argjson exit_code "$exit_code" --arg command "$command" --arg head "$head" \
  --arg tree "$tree" \
  '{schema:1, recorded_at:$now, event:$event, status:$status, exit_code:$exit_code,
    command:$command, head:$head, tree:$tree}' \
  | verdict_audit_write_atomic "$receipt" 2>/dev/null || exit 0

# Keep the newest receipts only; names start with their epoch.
receipt_count=0
while IFS= read -r name; do
  receipt_count=$((receipt_count + 1))
  (( receipt_count > receipt_limit )) || continue
  [[ "$name" =~ ^[0-9]+-[0-9]+-[0-9]+\.json$ ]] && rm -f "$receipt_dir/$name"
done < <(ls -1 "$receipt_dir" 2>/dev/null | sort -t- -k1,1nr -k2,2nr)
exit 0
