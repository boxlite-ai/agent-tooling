#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# StopFailure hook, Claude Code only, wired with asyncRewake: resume a turn an API error
# cut off, instead of leaving the session idle until someone types "continue".
# Tests: bash .agents/hooks/resume-after-api-failure.test.sh
#
# Why a hook can do this at all
# -----------------------------
# The host ignores a StopFailure hook's result, but an asyncRewake hook takes another
# path: it runs in the background, and when it exits 2 the host queues its stderr as a
# new turn (verified end to end on Claude Code 2.1.278). The host backgrounds asyncRewake
# hooks only in interactive and streaming-input sessions. Under `claude -p` this hook
# runs synchronously and exit 2 is dropped, which is why
# scripts/resume-on-network-error.sh still exists.
#
# Contract
#   stdin: one StopFailure payload. stdout: nothing.
#   exit 2, one line on stderr   resume: the host wakes the model with that line
#   exit 0                       leave the turn ended, as the host would
#   exit 1, stderr               a broken installation; never resumes
#
#   consume-wake <scope> <nonce-sha256>   spend a pending wake (cancel-verdict-audit.sh)
#   exit 0 spent; exit 1 no such unexpired wake
#
# Policy
#   - Main thread only. A subagent's failure reaches its parent as a tool error.
#   - Transient kinds only: server_error (a dropped or stalled stream, a mid-stream 5xx)
#     and overloaded. A rate limit lasts hours; every other kind fails the same way again.
#   - At most 3 resumes per session in any 10 minutes, each recorded before exit 2, so
#     an outage cannot loop. No delay: every resumed request goes through the host's own
#     retry and backoff.
#   - Each wake carries a one-time nonce. cancel-verdict-audit.sh spends it, so the
#     resumed turn is not taken for a new prompt that revokes the running audit.
#
# State: .agents/state/api-resume.<session scope>, written by this script alone:
#   {"resumes":[<epoch s>, ...],"wakes":[{"hash":"<sha256 of nonce>","expires":<epoch s>}]}
# The host runs one turn at a time per session and queues the wake only after this
# process exits, so a resume and the spending of its wake never overlap. The one
# unserialised case is a single session open in two processes: a lost update there can
# overshoot the budget by one resume, or drop the other process's wake hash so that its
# resumed turn counts as a new prompt and revokes the running audit. Unreadable, unsafe
# or unwritable state never resumes.
set -uo pipefail

readonly api_resume_max_resumes=3
readonly api_resume_window_seconds=600
readonly api_resume_wake_ttl_seconds=120
readonly api_resume_state_max_bytes=4096
api_resume_retryable_kinds=(server_error overloaded)

for required_command in jq perl shasum awk git; do
  command -v "$required_command" >/dev/null 2>&1 || {
    printf 'resume-after-api-failure.sh: required dependency not found: %s\n' \
      "$required_command" >&2
    exit 1
  }
done
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
wake_lib="$tooling_root/.agents/lib/hook-wake.sh"
for lib in "$state_lib" "$wake_lib"; do
  [[ -r "$lib" ]] || {
    printf 'resume-after-api-failure.sh: missing %s\n' "$lib" >&2
    exit 1
  }
done
# shellcheck source=../lib/verdict-audit-state.sh
source "$state_lib"
# shellcheck source=../lib/hook-wake.sh
source "$wake_lib"

# Exact per-element comparison, never a substring test against a space-joined list.
api_resume_kind_is_retryable() {  # kind
  local kind
  for kind in "${api_resume_retryable_kinds[@]}"; do
    [[ "$1" == "$kind" ]] && return 0
  done
  return 1
}

# Echo the state document, or an empty one when none exists. Status 1 when the path is
# not a plain regular file or the document is malformed: such state must not resume.
api_resume_read_state() {  # state-path
  local snapshot
  if [[ ! -e "$1" && ! -L "$1" ]]; then
    printf '{"resumes":[],"wakes":[]}'
    return 0
  fi
  snapshot="$(verdict_audit_read_regular_state "$1" "$api_resume_state_max_bytes" json)" \
    || return 1
  printf '%s' "${snapshot#*$'\n'}" | jq -ce '
    def epoch: type == "number" and . == floor and . > 0 and . < 1e12;
    select(type == "object"
      and (.resumes | type == "array" and all(.[]; epoch))
      and (.wakes | type == "array" and all(.[]; type == "object"
             and (.hash | type == "string" and test("^[0-9a-f]{64}$"))
             and (.expires | epoch))))
    | {resumes, wakes}
  ' 2>/dev/null
}

api_resume_on_failure() {  # payload -> status 2 to resume, 0 to leave the turn ended
  local payload="$1" kind scope state_path state now kept count nonce nonce_hash
  kind="$(printf '%s' "$payload" | jq -r '
    if type == "object" and .hook_event_name == "StopFailure"
       and (.agent_id // "") == "" and (.error | type) == "string"
    then .error else "" end
  ' 2>/dev/null)" || return 0
  api_resume_kind_is_retryable "$kind" || return 0
  scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo_root" 2>/dev/null)" \
    || return 0
  state_path="$(verdict_audit_state_path "$state_dir/api-resume" "$scope")"
  state="$(api_resume_read_state "$state_path")" || return 0
  now="$(date +%s)"
  kept="$(printf '%s' "$state" | jq -c --argjson now "$now" \
    --argjson window "$api_resume_window_seconds" '
    {resumes: [.resumes[] | select(. > $now - $window and . <= $now)],
     wakes: [.wakes[] | select(.expires > $now)]}
  ')" || return 0
  count="$(printf '%s' "$kept" | jq '.resumes | length')" || return 0
  (( count < api_resume_max_resumes )) || return 0
  nonce="$(hook_wake_new_nonce)" || return 0
  nonce_hash="$(hook_wake_nonce_hash "$nonce")" || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  # Record the resume before announcing it: an unrecorded resume is an unbounded one.
  printf '%s' "$kept" | jq -c --argjson now "$now" \
    --argjson ttl "$api_resume_wake_ttl_seconds" --arg hash "$nonce_hash" '
    .resumes += [$now] | .wakes += [{hash: $hash, expires: ($now + $ttl)}]
  ' | verdict_audit_write_atomic "$state_path" 2>/dev/null || return 0
  printf '[api-resume] Your response above was cut off by an API error (%s). Resume directly from where it stops — no apology, no recap. A tool call you were writing was discarded and did not run. Auto-resume %d of %d. [api-resume-wake:%s]\n' \
    "$kind" "$(( count + 1 ))" "$api_resume_max_resumes" "$nonce" >&2
  return 2
}

api_resume_consume_wake() {  # scope nonce-sha256 -> status 0 when spent
  local scope="$1" nonce_hash="$2" state_path state now
  [[ "$scope" =~ ^git-[0-9a-f]{40,64}$ && "$nonce_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  state_path="$(verdict_audit_state_path "$state_dir/api-resume" "$scope")"
  [[ -e "$state_path" || -L "$state_path" ]] || return 1
  state="$(api_resume_read_state "$state_path")" || return 1
  now="$(date +%s)"
  printf '%s' "$state" | jq -e --arg hash "$nonce_hash" --argjson now "$now" \
    --argjson ttl "$api_resume_wake_ttl_seconds" '
    any(.wakes[]; .hash == $hash and .expires >= $now and .expires <= $now + $ttl)
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$state" | jq -c --arg hash "$nonce_hash" --argjson now "$now" '
    .wakes |= [.[] | select(.hash != $hash and .expires >= $now)]
  ' | verdict_audit_write_atomic "$state_path" 2>/dev/null || return 1
}

# One state root for the writer here and the spender in cancel-verdict-audit.sh, which
# resolves the project the same way. Outside a repository there is no session scope.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  [[ "${1:-}" == consume-wake ]] && exit 1
  exit 0
fi
state_dir="$(cd "$repo_root" && pwd -P)/.agents/state"

if [[ "${1:-}" == consume-wake ]]; then
  api_resume_consume_wake "${2:-}" "${3:-}"
  exit $?
fi
api_resume_on_failure "$(cat)"
exit $?
