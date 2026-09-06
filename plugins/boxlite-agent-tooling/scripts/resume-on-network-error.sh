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

# High enough that the wait budget below is what actually ends a waiting run: an
# overloaded API stays reachable, so each restart costs one sleep and ~20 of them fit
# inside six hours. A restart cap of 10 would end the run in 1.21h no matter what the
# wait budget said — this stays a backstop against a fault that fails instantly and
# forever, not the thing that decides how long an outage is survivable.
max_restarts=50
# One budget for the WHOLE run, not per restart: six hours outlasts a usage window that
# resets on its own schedule, with margin for one that starts partway through. The faults
# worth waiting out are measured in hours rather than seconds. Intervals grow toward
# max_backoff_seconds so a long outage costs a handful of probes instead of hundreds —
# the point of waiting is to be there when the window reopens, not to ask repeatedly
# while it is shut.
max_wait_seconds=21600
max_backoff_seconds=1800
total_waited=0
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

# Print usage message to stdout.
usage() {
  printf 'usage: resume-on-network-error.sh [--max-restarts N] [--max-wait SECONDS]\n'
  printf '                                  [--probe-url URL] [--] <prompt> [claude args...]\n'
  printf '\n'
  printf -- '--max-wait is the total this run may spend waiting, across every restart\n'
  printf '(default 21600 = 6h, long enough to outlast a usage window). Intervals double\n'
  printf 'from 5s to a 30m ceiling and keep growing across restarts, so a multi-hour\n'
  printf 'outage costs a handful of probes rather than hundreds.\n'
  printf '\n'
  printf 'Exit: 0 completed · 1 permanent fault · 2 usage · 3 restart budget spent\n'
  printf '      4 wait budget spent · 5 failure kind never recorded\n'
  printf '\n'
  printf 'Exit 4 says the run waited as long as it was allowed, not that the network is\n'
  printf 'down: a usage window that never reopened inside the budget ends here too.\n'
  printf '\n'
  printf 'The failure kind comes from the record .agents/hooks/record-api-failure.sh\n'
  # shellcheck disable=SC2016 # The reader needs the variable's name, not its value.
  printf 'writes under $CLAUDE_PROJECT_DIR (default: the current directory). With that\n'
  printf 'hook unwired, or that variable unset so writer and reader disagree on the\n'
  printf 'project root, every failure degrades to the small unknown budget and exits 5.\n'
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
# Ensure an option has a value argument, exit 2 if not.  # $1 = option name, $2 = remaining argc
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

# Log a timestamped message to stderr.  # $1 = message
log() {
  printf '%s resume-on-network-error: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

# ── Reachability ─────────────────────────────────────────────────────────────
# Any HTTP response proves the path is up; 401/404 are as good as 200 here, and no
# credentials are sent.
# Probe the API endpoint with a HEAD request, return 0 if reachable.  # Reads probe_url; exit 0 = reachable, 1 = unreachable
api_is_reachable() {
  curl -sS -o /dev/null -m 5 --head "$probe_url" >/dev/null 2>&1
}

# Sleep first, then probe: an "overloaded" failure leaves the network perfectly
# reachable, so probing before waiting would hammer a server already saying stop.
#
# `total_waited` is script-level on purpose. A per-call budget would let ten restarts
# wait ten times over — the deadline has to mean "this run has waited long enough",
# not "this attempt has". `delay` is likewise carried across restarts by the caller, so
# intervals keep growing over the whole outage instead of restarting at 5s each time.
# --max-wait is a deadline, so no single sleep may run past it: the last one is clipped
# to whatever budget remains. Without that, `--max-wait 1` still sleeps the opening 5s.
wait_for_api() {  # $1 = first delay in seconds
  local delay="$1" sleep_for
  while (( total_waited < max_wait_seconds )); do
    sleep_for="$delay"
    if (( sleep_for > max_wait_seconds - total_waited )); then
      sleep_for=$(( max_wait_seconds - total_waited ))
    fi
    log "waiting ${sleep_for}s before probing ${probe_url}"
    sleep "$sleep_for"
    (( total_waited += sleep_for ))
    if api_is_reachable; then
      log "API reachable after ${total_waited}s of total waiting"
      return 0
    fi
    # Clamp the DOUBLED value: testing `delay < ceiling` before doubling lets the last
    # step overshoot (1280 < 1800, so it becomes 2560 — past the advertised ceiling).
    (( delay = delay * 2 > max_backoff_seconds ? max_backoff_seconds : delay * 2 ))
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
# Read the error kind from the StopFailure hook's record if it matches session and is fresh.  # $1 = session id this run is resuming; reads api_failure_record, api_failure_record_max_age_seconds; echoes kind or empty
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
# Parse result JSON and classify outcome as done, api_error, or fatal.  # $1 = file holding one result JSON object; echoes one of: done, api_error, fatal
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
# Classify an API error kind as fatal, retry, or retry-unknown.  # $1 = recorded kind (may be empty); reads fatal_kinds, retryable_kinds; echoes one of: fatal, retry, retry-unknown
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
    log "gave up after ${total_waited}s of waiting (limit ${max_wait_seconds}s) — stopping"
    exit 4
  fi
  (( delay = delay * 2 > max_backoff_seconds ? max_backoff_seconds : delay * 2 ))
done
