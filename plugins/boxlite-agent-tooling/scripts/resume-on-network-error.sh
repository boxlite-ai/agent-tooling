#!/usr/bin/env bash
# Supervisor for unattended `claude -p` runs: restarts the session when a turn died
# on the API rather than on finished work. Prints the final result JSON on stdout.
# Tests: bash plugins/boxlite-agent-tooling/scripts/resume-on-network-error.test.sh
# Requires: claude, jq, curl (curl is used only to probe API reachability).
#
# Why this is a wrapper and not a hook
# ------------------------------------
# A turn that dies on an API error IS observable in-session — the host fires
# StopFailure instead of Stop, carrying the error kind. But that event is documented
# and implemented as fire-and-forget ("hook output and exit codes are ignored", and
# the dispatcher discards the result), so no hook can resume the turn. Restarting the
# run is only possible from outside the process, which is what this script does.
#
# How it knows WHICH failure it is
# --------------------------------
# The result JSON is not enough: terminal_reason is a closed enum whose API-failure
# member is the bare string `api_error`, with the kind nowhere in it (the error
# variant's `errors` array is free text). The kind is exposed only to the StopFailure
# hook, so .agents/hooks/record-api-failure.sh writes it to
# .agents/state/last-api-failure.json and this script reads it back. Without that
# record the kind is unknown, and an unknown kind gets a much smaller restart budget:
# retrying a revoked token to the full budget is the burn loop this exists to prevent.
set -uo pipefail

max_restarts=10
max_wait_seconds=1800
# An unknown kind may be a network blip worth retrying or a permanent fault worth
# stopping. Bound the guess rather than disabling the feature or spending the budget.
unknown_kind_max_restarts=2
api_failure_record_max_age_seconds=300
probe_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
# A resumed session needs a next turn — no CLI path re-issues the pending request
# without one — so one word is the floor. Deliberately carries no "re-verify file state"
# warning: a turn cut off mid-edit can leave the model's belief about the tree stale, and
# nothing here corrects that. Put the warning in the run's own prompt or in CLAUDE.md if
# the task edits files.
resume_prompt='Continue.'

# Host enum (StopFailure `error`). Retryable faults are the ones another attempt can
# plausibly clear; everything else repeats identically no matter how often it is tried.
# A member the host adds later belongs to neither set and lands on the unknown budget,
# which is the safe default rather than a gap: it retries briefly instead of assuming.
retryable_kinds=(overloaded server_error rate_limit)
fatal_kinds=(authentication_failed oauth_org_not_allowed account_on_hold billing_error
             invalid_request model_not_found max_output_tokens)

# Exact per-element comparison, never a substring test against a space-joined list: a
# multi-word value is a substring of such a list while being no member of it, so a glob
# test would classify `authentication_failed billing_error` as a known kind.
kind_is_member() {  # $1 = candidate, $2.. = members
  local candidate="$1" member
  shift
  for member in "$@"; do
    [[ "$candidate" == "$member" ]] && return 0
  done
  return 1
}

usage() {
  printf 'usage: resume-on-network-error.sh [--max-restarts N] [--max-wait SECONDS]\n'
  printf '                                  [--probe-url URL] [--] <prompt> [claude args...]\n'
}

# ── Dependencies, checked at the executable boundary ─────────────────────────
for required in claude jq curl; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'resume-on-network-error: %s is required\n' "$required" >&2
    exit 2
  }
done

# ── Arguments ────────────────────────────────────────────────────────────────
# Each value-taking option asserts its value is present before consuming it: a bare
# `shift 2` on a one-element argv fails without shifting, which spins this loop.
require_value() {  # $1 = option name, $2 = remaining argc
  (( $2 >= 2 )) || {
    printf 'resume-on-network-error: %s requires a value\n' "$1" >&2
    exit 2
  }
}

while (( $# > 0 )); do
  case "$1" in
    --max-restarts) require_value "$1" $#; max_restarts="$2"; shift 2 ;;
    --max-wait)     require_value "$1" $#; max_wait_seconds="$2"; shift 2 ;;
    --probe-url)    require_value "$1" $#; probe_url="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             printf 'resume-on-network-error: unknown option %s\n' "$1" >&2
                    usage >&2; exit 2 ;;
    *)              break ;;
  esac
done

prompt="${1:-}"
[[ -n "$prompt" ]] || { usage >&2; exit 2; }
shift
# Bash 3.2 (the macOS system shell) treats "${arr[@]}" on an empty array as unset under
# `set -u`, so every expansion of this array is written with the ${a[@]+"${a[@]}"} guard.
claude_args=("$@")

[[ "$max_restarts" =~ ^[0-9]+$ ]] || {
  printf 'resume-on-network-error: --max-restarts must be a non-negative integer\n' >&2
  exit 2
}
[[ "$max_wait_seconds" =~ ^[0-9]+$ ]] || {
  printf 'resume-on-network-error: --max-wait must be a non-negative integer\n' >&2
  exit 2
}
[[ "$probe_url" == https://* || "$probe_url" == http://* ]] || {
  printf 'resume-on-network-error: --probe-url must be an http(s) URL\n' >&2
  exit 2
}

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
api_failure_record="$project_dir/.agents/state/last-api-failure.json"

log() {
  printf '%s resume-on-network-error: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

# ── Reachability ─────────────────────────────────────────────────────────────
# Any HTTP response proves the path is up; 401/404 are as good as 200 here, and no
# credentials are sent.
api_is_reachable() {
  curl -sS -o /dev/null -m 5 --head "$probe_url" >/dev/null 2>&1
}

# Sleep first, then probe: an "overloaded" failure leaves the network perfectly
# reachable, so probing before waiting would hammer a server already saying stop.
wait_for_api() {  # $1 = first delay in seconds
  local delay="$1" waited=0
  while (( waited < max_wait_seconds )); do
    log "waiting ${delay}s before probing ${probe_url}"
    sleep "$delay"
    (( waited += delay ))
    if api_is_reachable; then
      log "API reachable after ${waited}s"
      return 0
    fi
    (( delay = delay < 60 ? delay * 2 : 60 ))
  done
  return 1
}

# ── Error kind, from the StopFailure hook's record ───────────────────────────
# Echoes a kind from the host enum, or nothing when no record describes THIS run's
# failure. Two gates, and both are load-bearing:
#
#   * session — the record lives at one project-wide path, so a concurrent or recent
#     other run in the same project writes to it too. Without this check a foreign
#     `overloaded` makes this run spend its whole restart budget, and a foreign
#     `authentication_failed` kills a run that never had an auth problem.
#   * age — the same session id can be resumed much later, so a matching id alone does
#     not make a record current.
#
# Failing either gate yields nothing, which routes to the deliberately small unknown
# budget: guessing briefly beats acting on another run's fault.
recorded_error_kind() {  # $1 = session id this run is resuming
  local expected_session="$1" recorded_at recorded_session now kind
  [[ -n "$expected_session" ]] || return 0
  [[ -r "$api_failure_record" ]] || return 0
  recorded_session="$(jq -r '.session_id // "" | tostring' "$api_failure_record" 2>/dev/null || true)"
  [[ "$recorded_session" == "$expected_session" ]] || return 0
  recorded_at="$(jq -r '.recorded_at // 0 | tostring' "$api_failure_record" 2>/dev/null || echo 0)"
  [[ "$recorded_at" =~ ^[0-9]+$ ]] || return 0
  now="$(date -u +%s)"
  (( now - recorded_at <= api_failure_record_max_age_seconds )) || return 0
  kind="$(jq -r '.error // "" | tostring' "$api_failure_record" 2>/dev/null || true)"
  printf '%s' "$kind"
}

# ── Outcome classification ───────────────────────────────────────────────────
# Echoes done | retry | fatal for everything the result JSON can decide on its own.
# `api_error` is deliberately NOT decided here: the kind lives outside this document,
# so the caller resolves it against the recorded StopFailure kind.
classify_result() {  # $1 = file holding one result JSON object
  jq -r '
    def reason: (.terminal_reason // "" | tostring);
    if   (.subtype == "success" and (.is_error != true)) then "done"
    elif (reason == "api_error")                         then "api_error"
    else "fatal"
    end
  ' "$1" 2>/dev/null || printf 'fatal'
}

# Resolve an api_error into retry or fatal using the kind the StopFailure hook saw.
classify_api_error() {  # echoes retry|fatal|retry-unknown; $1 = recorded kind, may be empty
  if kind_is_member "$1" "${fatal_kinds[@]}"; then
    printf 'fatal'
  elif kind_is_member "$1" "${retryable_kinds[@]}"; then
    printf 'retry'
  else
    printf 'retry-unknown'
  fi
}

# ── Main loop ────────────────────────────────────────────────────────────────
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/resume-on-network-error.XXXXXX")" || {
  printf 'resume-on-network-error: could not create a working directory\n' >&2
  exit 2
}
trap 'rm -rf "$work_dir"' EXIT
result_file="$work_dir/result.json"

session_id=""
restarts=0
delay=5

while :; do
  # --output-format json comes AFTER the caller's arguments so it wins: a caller who
  # passes their own --output-format would otherwise silently defeat classification.
  if [[ -n "$session_id" ]]; then
    log "resuming session ${session_id} (restart ${restarts}/${max_restarts})"
    claude -p "$resume_prompt" --resume "$session_id" \
      ${claude_args[@]+"${claude_args[@]}"} --output-format json >"$result_file"
  else
    log "starting a new session (restart ${restarts}/${max_restarts})"
    claude -p "$prompt" \
      ${claude_args[@]+"${claude_args[@]}"} --output-format json >"$result_file"
  fi
  claude_status=$?

  # A session id, once learned, is what makes the next attempt a resume rather than a
  # fresh run of the original prompt. `--continue` is deliberately not used: it picks
  # the newest conversation in the directory, which need not be this one.
  new_session="$(jq -r '.session_id // empty' "$result_file" 2>/dev/null || true)"
  [[ -n "$new_session" ]] && session_id="$new_session"

  if jq -e . "$result_file" >/dev/null 2>&1; then
    outcome="$(classify_result "$result_file")"
    detail="$(jq -r '[(.subtype // "-"), (.terminal_reason // "-")] | join(" ")' "$result_file" 2>/dev/null || echo '?')"
    if [[ "$outcome" == "api_error" ]]; then
      # session_id was just refreshed from this result, so the record is matched
      # against the session that actually failed rather than whatever ran last.
      error_kind="$(recorded_error_kind "$session_id")"
      outcome="$(classify_api_error "$error_kind")"
      detail="${detail} kind=${error_kind:-unrecorded}"
    fi
  else
    # No parseable result: the CLI died before it could report. Let reachability
    # decide — down means retry, up means something else broke and looping is futile.
    detail="no result JSON (exit ${claude_status})"
    if api_is_reachable; then outcome=fatal; else outcome=retry; fi
  fi
  log "outcome=${outcome} (${detail})"

  case "$outcome" in
    done)
      log "run completed"
      cat "$result_file"
      exit 0
      ;;
    fatal)
      log "not retryable — stopping"
      exit 1
      ;;
    retry-unknown)
      if (( restarts >= unknown_kind_max_restarts )); then
        log "error kind unrecorded after ${restarts} restarts — stopping rather than guessing"
        log "wire .agents/hooks/record-api-failure.sh (StopFailure) to classify precisely"
        exit 5
      fi
      ;;
  esac

  (( restarts++ ))
  if (( restarts > max_restarts )); then
    log "giving up after ${max_restarts} restarts"
    exit 3
  fi
  if ! wait_for_api "$delay"; then
    log "API still unreachable after ${max_wait_seconds}s — stopping"
    exit 4
  fi
  (( delay = delay < 60 ? delay * 2 : 60 ))
done
