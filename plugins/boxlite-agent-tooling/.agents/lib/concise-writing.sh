#!/usr/bin/env bash
# Compatibility entry point for summary checks; host reminder loading stays here.
# Bash 3.2 can exit inside a failed nested source before its caller handles status.
[[ -f "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts/check.sh" &&
   -r "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts/check.sh" ]] || {
  printf 'boxlite-writing: checker unavailable\n' >&2; return 2;
}
# shellcheck source=../skills/boxlite-writing/scripts/check.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/boxlite-writing/scripts" && pwd -P)/check.sh" || return 2

concise_writing_reminder() {
  local root reminder
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 2
  # shellcheck source=subagent.sh
  source "$root/.agents/lib/subagent.sh" || return 2
  reminder="$(subagent_prompt reminders/concise-writing-reminder "$root")" || return 2
  printf '%s' "$reminder"
}
