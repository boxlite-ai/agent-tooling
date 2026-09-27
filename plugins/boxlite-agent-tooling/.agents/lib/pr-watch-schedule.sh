#!/usr/bin/env bash
# Requires jq and the session executable's dependencies; inert when sourced.

pr_watch_schedule_tick() { # absolute-session-script targets-json [keepalive|events]
  local session="$1" targets="$2" rows target worktree branch pr output status rc
  local mode="${3:-keepalive}" batch arguments=()
  local active=0 stopped=0 failed=0
  case "$mode" in keepalive|events) ;; *) printf 'pr-watch-schedule: invalid mode\n' >&2; return 2 ;; esac
  if (( ${#targets} > 32768 )) || ! rows="$(jq -sce '
    def text: type == "string" and length > 0 and (test("[\u0000-\u001f]") | not);
    select(length == 1) | .[0]
    | select(type == "array" and length > 0 and length <= 32)
    | select(all(.[]; type == "object"
        and (.worktree | text and (startswith("/") or test("^[A-Za-z]:[/\\\\]")))
        and (.branch | text)
        and ((if has("pr") then .pr else "" end) | type == "string" and test("^(|[1-9][0-9]*)$"))))
    | .[]' <<< "$targets")"; then
    printf 'pr-watch-schedule: expected 1..32 targets with absolute worktree, branch, optional PR number\n' >&2
    return 2
  fi
  while IFS= read -r target; do
    worktree="$(jq -r .worktree <<< "$target")" || return 1
    branch="$(jq -r .branch <<< "$target")" || return 1
    pr="$(jq -r '.pr // ""' <<< "$target")" || return 1
    arguments=(--branch "$branch" --pr "$pr")
    [[ "$mode" != keepalive ]] || arguments=(--keepalive "${arguments[@]}")
    if output="$(cd "$worktree" && bash "$session" "${arguments[@]}")"; then
      status="$(jq -er '.status' <<< "$output")" || status=invalid
      case "$status" in
        stopped) stopped=$((stopped + 1)) ;;
        healthy|waiting|starting|degraded) active=$((active + 1)) ;;
        *) printf 'pr-watch-schedule: invalid status for %s\n' "$branch" >&2; failed=1; continue ;;
      esac
      if [[ "$mode" == events ]]; then
        if ! batch="$(jq -cse --argjson target "$target" '
          select(length == 1) | .[0]
          | select(.events | type == "array" and length <= 16
              and all(.[]; type == "object" and (.kind | type == "string")
                and (.event_id | type == "string" and test("^[0-9a-f]{64}$"))))
          | if (.events | length) > 0 then {target:$target,status,events} else [] end
          ' <<< "$output")"; then
          printf 'pr-watch-schedule: invalid event batch for %s\n' "$branch" >&2
          failed=1; continue
        fi
        [[ "$batch" == '[]' ]] || printf '%s\n' "$batch" || return 1
        if [[ "$status" == degraded ]]; then
          printf 'pr-watch-schedule: %s has degraded coverage; recovery remains scheduled\n' "$branch" >&2
          failed=1
        fi
      fi
    else
      rc=$?
      if (( rc == 75 )); then
        active=$((active + 1)) # Another reconciliation owns the branch lease.
        # A deferred read cannot prove an empty queue for final retirement.
        [[ "$mode" != events || "$failed" != 0 ]] || failed=75
      else
        printf 'pr-watch-schedule: %s reconciliation failed (exit %s)\n' "$branch" "$rc" >&2
        failed=1
      fi
    fi
  done <<< "$rows"
  (( failed == 0 )) || return "$failed"
  [[ "$mode" != events ]] || return 0
  jq -nc --argjson active "$active" --argjson stopped "$stopped" '{active:$active,stopped:$stopped}'
}
