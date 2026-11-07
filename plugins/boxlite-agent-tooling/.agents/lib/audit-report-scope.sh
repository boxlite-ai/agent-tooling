#!/usr/bin/env bash
# Read-only report scope for the design gate. Requires verdict-audit-state.sh.
# The task producer/start handler publishes ownership before any report tool runs.

_audit_report_task_live() { # canonical root, scope, auditor, task JSON
  local repo="$1" scope="$2" auditor="$3" task="$4" context history epoch retained
  context="$(jq -c .context <<< "$task")" || return 1
  history="$(audit_reflection_gate "$context" inspect)" || return 1
  jq -e --argjson task "$task" '
    .state.context == $task.context and
    (.state.attempts[-1] | .id == $task.attempt_id and .outcome == null
      and .input.deadline == $task.deadline)' <<< "$history" >/dev/null || return 1
  if [[ "$auditor" == commit-push-auditor ]]; then
    epoch="$(verdict_audit_read_single_record "$repo/.agents/state/verdict-prompt-epoch.$scope")" || return 1
    jq -e --arg epoch "$epoch" '.context.epoch == $epoch' <<< "$task" >/dev/null
  else
    retained="$(audit_request_context_read "$repo" "$scope")" || return 1
    jq -e --argjson retained "$retained" '
      .generation == ($retained.request | split(" ")[0]) and
      .context.epoch == (if $retained.origin_epoch == "-" then "0" else $retained.origin_epoch end)
    ' <<< "$task" >/dev/null
  fi
}

audit_report_write_allowed() { # hook payload, absolute cwd, extracted targets
  local payload="$1" cwd="$2" targets="$3" library name auditor repo scope agent
  local state control link task expected generation
  [[ "$cwd" == /* && -n "$targets" ]] || return 1
  case "$(jq -r '.hook_event_name + ":" + .tool_name' <<< "$payload")" in
    PreToolUse:Write) ;;
    PreToolUse:apply_patch)
      # Only one add/update: a report plus any other target, deletion, or move stays gated.
      jq -e '.tool_input.command | strings | split("\n") |
        map(select(test("^\\s*\\*\\*\\* (Add File|Update File|Delete File|Move to):"))) |
        length == 1 and (.[0] | test("^\\s*\\*\\*\\* (Add|Update) File:"))' \
        <<< "$payload" >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  # shellcheck source=subagent-identity.sh
  source "$library/subagent-identity.sh" || return 1
  auditor="$(subagent_identity_auditor "$payload")" || return 1
  case "$auditor" in commit-push-auditor|verdict-auditor) ;; *) return 1 ;; esac
  for name in auditor-override-state audit-reflection audit-reflection-gate audit-request; do
    # shellcheck source=/dev/null
    source "$library/$name.sh" || return 1
  done
  repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" \
    && repo="$(cd "$repo" && pwd -P)" || return 1
  state="$repo/.agents/state"; control="$(auditor_override_control_dir "$repo")"
  [[ ! -L "$repo/.agents" && ! -L "$state" && ! -L "$control" ]] || return 1
  scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo")" || return 1
  agent="$(jq -er '.agent_id | strings | select(test("\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z"))' \
    <<< "$payload")" || return 1
  link="$control/audit-task.$scope.$auditor.json"
  task="$(verdict_audit_read_single_record "$link")" || return 1
  jq -e --arg repo "$repo" --arg scope "$scope" --arg agent "$agent" --arg auditor "$auditor" '
    .host_agent_id == $agent and .context.repo_root == $repo and .context.session == $scope and
    (.attempt_id | type == "string" and length > 0) and (.deadline | type == "number") and
    (.context.gate | if $auditor == "verdict-auditor" then . == "verdict" else IN("commit","push") end)
  ' <<< "$task" >/dev/null || return 1
  expected="$state/last-audit.json"
  if [[ "$auditor" == verdict-auditor ]]; then
    generation="$(jq -er '.generation | strings | select(test("\\A[1-9][0-9]*-[0-9]+-[0-9]+\\z"))' \
      <<< "$task")" || return 1
    expected="$state/last-verdict.json.$scope.audit-$generation"
  fi
  [[ "$targets" == "$expected" && "$(jq -r .dossier_path <<< "$task")" == "$expected" ]] || return 1
  _audit_report_task_live "$repo" "$scope" "$auditor" "$task" || return 1
  # A host write follows links. Keep aliases and non-plain existing targets on the
  # design path; a missing report is valid only below the canonical state directory.
  perl -MCwd=abs_path -e '
    my ($directory, $path) = @ARGV;
    my $real = abs_path($directory);
    exit 1 unless defined $real && $real eq $directory;
    my @named = lstat($path);
    exit($!{ENOENT} ? 0 : 1) unless @named;
    exit((-f _ && !-l _ && $named[3] == 1) ? 0 : 1);
  ' -- "$state" "$expected" || return 1
  # Revocation can close history or change prompt/request authority without changing
  # the task link. Recheck both after path inspection; this grants no verdict.
  [[ "$(verdict_audit_read_single_record "$link")" == "$task" ]] || return 1
  _audit_report_task_live "$repo" "$scope" "$auditor" "$task"
}
