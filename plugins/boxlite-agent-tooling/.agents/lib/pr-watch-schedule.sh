#!/usr/bin/env bash
# Requires jq and the session executable's dependencies; inert when sourced.

pr_watch_schedule_tick() { # absolute-session-script targets-json -> active/stopped counts
  local session="$1" targets="$2" rows target worktree branch pr output status rc
  local active=0 stopped=0 failed=0
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
    if output="$(cd "$worktree" && bash "$session" --keepalive --branch "$branch" --pr "$pr")"; then
      status="$(jq -er '.status' <<< "$output")" || status=invalid
      case "$status" in
        stopped) stopped=$((stopped + 1)) ;;
        healthy|waiting|starting|degraded) active=$((active + 1)) ;;
        *) printf 'pr-watch-schedule: invalid status for %s\n' "$branch" >&2; failed=1 ;;
      esac
    else
      rc=$?
      if (( rc == 75 )); then
        active=$((active + 1)) # Another reconciliation owns the branch lease.
      else
        printf 'pr-watch-schedule: %s reconciliation failed (exit %s)\n' "$branch" "$rc" >&2
        failed=1
      fi
    fi
  done <<< "$rows"
  (( failed == 0 )) || return 1
  jq -nc --argjson active "$active" --argjson stopped "$stopped" '{active:$active,stopped:$stopped}'
}
