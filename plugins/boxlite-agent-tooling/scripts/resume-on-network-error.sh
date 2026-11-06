#!/usr/bin/env bash
# Supervise unattended claude -p runs, resuming eligible API failures within budgets.
# Stdout carries only the completed result JSON; diagnostics go to stderr.
# Failure kinds come from the StopFailure record, not the result's bare api_error.
set -uo pipefail

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

require_value() { # option, remaining argc
  (( $2 >= 2 )) || {
    printf 'resume-on-network-error: %s requires a value\n' "$1" >&2
    exit 2
  }
}

log() {
  printf '%s resume-on-network-error: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

api_is_reachable() { # probe URL; any HTTP response establishes reachability
  curl -sS -o /dev/null -m 5 --head "$1" >/dev/null 2>&1
}

# Sleep before probing even when the API is reachable but overloaded. Return the
# updated run-wide wait on both paths; only stderr carries progress diagnostics.
wait_for_api() { # delay, total waited, wait limit, probe URL, backoff ceiling
  local delay="$1" total_waited="$2" max_wait_seconds="$3"
  local probe_url="$4" max_backoff_seconds="$5" sleep_for
  while (( total_waited < max_wait_seconds )); do
    sleep_for="$delay"
    if (( sleep_for > max_wait_seconds - total_waited )); then
      sleep_for=$(( max_wait_seconds - total_waited ))
    fi
    log "waiting ${sleep_for}s before probing ${probe_url}"
    sleep "$sleep_for"
    (( total_waited += sleep_for ))
    if api_is_reachable "$probe_url"; then
      log "API reachable after ${total_waited}s of total waiting"
      printf '%s' "$total_waited"
      return 0
    fi
    (( delay = delay * 2 > max_backoff_seconds ? max_backoff_seconds : delay * 2 ))
  done
  printf '%s' "$total_waited"
  return 1
}

# The project-wide record can belong to another run or an older turn of this
# session. Either mismatch returns no kind and retains the small unknown budget.
recorded_error_kind() { # record path, expected session, maximum age
  local api_failure_record="$1" expected_session="$2" max_age_seconds="$3"
  local recorded_at recorded_session now kind
  [[ -n "$expected_session" && -r "$api_failure_record" ]] || return 0
  recorded_session="$(jq -r '.session_id // "" | tostring' "$api_failure_record" 2>/dev/null || true)"
  [[ "$recorded_session" == "$expected_session" ]] || return 0
  recorded_at="$(jq -r '.recorded_at // 0 | tostring' "$api_failure_record" 2>/dev/null || echo 0)"
  [[ "$recorded_at" =~ ^[0-9]+$ ]] || return 0
  now="$(date -u +%s)"
  (( now - recorded_at <= max_age_seconds )) || return 0
  kind="$(jq -r '.error // "" | tostring' "$api_failure_record" 2>/dev/null || true)"
  printf '%s' "$kind"
}

classify_result() {  # $1 = file holding one result JSON object
  jq -r '
    def reason: (.terminal_reason // "" | tostring);
    if   (.subtype == "success" and (.is_error != true)) then "done"
    elif (reason == "api_error")                         then "api_error"
    else "fatal"
    end
  ' "$1" 2>/dev/null || printf 'fatal'
}

# Case patterns match complete enum members; unknown and multi-member strings
# deliberately use the smaller guess budget.
classify_api_error() {
  case "$1" in
    authentication_failed|oauth_org_not_allowed|account_on_hold|billing_error|\
    invalid_request|model_not_found|max_output_tokens)
      printf 'fatal' ;;
    overloaded|server_error|rate_limit)
      printf 'retry' ;;
    *) printf 'retry-unknown' ;;
  esac
}

main() {
  # Waiting spans all restarts. The restart cap is a separate runaway backstop.
  local max_restarts=50 max_wait_seconds=21600 max_backoff_seconds=1800
  local unknown_kind_max_restarts=2 api_failure_record_max_age_seconds=300
  local probe_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  local tooling_root resume_prompt prompt project_dir api_failure_record result_file
  local session_id="" restarts=0 delay=5 total_waited=0
  local required claude_status new_session outcome detail error_kind
  local -a invocation

  for required in claude jq curl; do
    command -v "$required" >/dev/null 2>&1 || {
      printf 'resume-on-network-error: %s is required\n' "$required" >&2
      exit 2
    }
  done
  tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
  # shellcheck source=../.agents/lib/subagent.sh
  source "$tooling_root/.agents/lib/subagent.sh" || exit 2
  resume_prompt="$(subagent_prompt resume/resume-after-network-error "$tooling_root")" || exit 2

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
  # Remaining positional parameters preserve empty argv safely on Bash 3.2.
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

  # Sole deliberate global: Bash 3.2 EXIT traps cannot read a main-local path.
  # Only main assigns it; register cleanup after successful private allocation.
  resume_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/resume-on-network-error.XXXXXX")" || {
    printf 'resume-on-network-error: could not create a working directory\n' >&2
    exit 2
  }
  trap 'rm -rf "$resume_work_dir"' EXIT
  result_file="$resume_work_dir/result.json"

  while :; do
    if [[ -n "$session_id" ]]; then
      log "resuming session ${session_id} (restart ${restarts}/${max_restarts})"
      invocation=(-p "$resume_prompt" --resume "$session_id")
    else
      log "starting a new session (restart ${restarts}/${max_restarts})"
      invocation=(-p "$prompt")
    fi
    # Force JSON after caller arguments; never use --continue to choose a session.
    claude "${invocation[@]}" "$@" --output-format json >"$result_file"
    claude_status=$?
    new_session="$(jq -r '.session_id // empty' "$result_file" 2>/dev/null || true)"
    [[ -n "$new_session" ]] && session_id="$new_session"

    if jq -e . "$result_file" >/dev/null 2>&1; then
      outcome="$(classify_result "$result_file")"
      detail="$(jq -r '[(.subtype // "-"), (.terminal_reason // "-")] | join(" ")' "$result_file" 2>/dev/null || echo '?')"
      if [[ "$outcome" == "api_error" ]]; then
        error_kind="$(recorded_error_kind "$api_failure_record" "$session_id" "$api_failure_record_max_age_seconds")"
        outcome="$(classify_api_error "$error_kind")"
        detail="${detail} kind=${error_kind:-unrecorded}"
      fi
    else
      detail="no result JSON (exit ${claude_status})"
      if api_is_reachable "$probe_url"; then outcome=fatal; else outcome=retry; fi
    fi
    log "outcome=${outcome} (${detail})"

    case "$outcome" in
      done)
        log "run completed"
        cat "$result_file"
        exit 0 ;;
      fatal)
        log "not retryable — stopping"
        exit 1 ;;
      retry-unknown)
        if (( restarts >= unknown_kind_max_restarts )); then
          log "error kind unrecorded after ${restarts} restarts — stopping rather than guessing"
          log "wire .agents/hooks/record-api-failure.sh (StopFailure) to classify precisely"
          exit 5
        fi ;;
    esac
    (( restarts++ ))
    if (( restarts > max_restarts )); then
      log "giving up after ${max_restarts} restarts"
      exit 3
    fi
    if ! total_waited="$(wait_for_api "$delay" "$total_waited" "$max_wait_seconds" "$probe_url" "$max_backoff_seconds")"; then
      log "gave up after ${total_waited}s of waiting (limit ${max_wait_seconds}s) — stopping"
      exit 4
    fi
    (( delay = delay * 2 > max_backoff_seconds ? max_backoff_seconds : delay * 2 ))
  done
}

main "$@"
