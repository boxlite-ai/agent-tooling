#!/usr/bin/env bash
# Source-only Git retry checkpoint; requires verdict-audit-state.sh and timed-user-prompt.sh.
# History owns preparation; lock order is history -> timed request, never the reverse.

git_audit_decision_current() { # request JSON; caller separately verifies the host session
  local request="$1" root scope epoch=0 epoch_file branch head
  root="$(jq -er '.spec.binding.root | strings' <<<"$request")" || return 1
  scope="$(jq -er '.spec.binding.session | strings | select(test("^[A-Za-z0-9_-]{1,128}$"))' <<<"$request")" || return 1
  epoch_file="$root/.agents/state/verdict-prompt-epoch.$scope"
  if [[ -e "$epoch_file" || -L "$epoch_file" ]]; then
    epoch="$(verdict_audit_read_single_record "$epoch_file")" || return 1
  fi
  head="$(git -C "$root" rev-parse HEAD)" || return 1
  branch="$(git -C "$root" branch --show-current)" || return 1
  jq -e --arg epoch "$epoch" --arg head "$head" --arg branch "${branch:-HEAD}" '
    .spec.binding | .epoch == $epoch and .head == $head and .branch == $branch
  ' <<<"$request" >/dev/null
}

git_audit_checkpoint_result() { # library, validated history, path; typed result under history lock
  local library="$1" state="$2" history="$3" root scope kind path spec request id instruction
  if ! jq -e -L "$library" 'include "audit-reflection-contract"; audit_git_decision_due' <<<"$state" >/dev/null; then
    printf '%s\n' '{"action":"continue","reason":""}'; return 0
  fi
  root="$(jq -r .context.repo_root <<<"$state")"
  scope="$(jq -r .context.session <<<"$state")"
  kind="$(jq -r .context.gate <<<"$state")"
  [[ ! -L "$root/.agents" && ! -L "$root/.agents/state" ]] || return 2
  mkdir -p "$root/.agents/state" || return 2
  path="$root/.agents/state/$kind-audit-decision-request-$scope.json"
  spec="$(jq -c --arg head "$(git -C "$root" rev-parse HEAD)" '
    {binding:{root:.context.repo_root,session:.context.session,epoch:.context.epoch,
      branch:.context.branch,head:$head,
      failure_id:([.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR")) | .id][-1])},
     prefix:(.context.gate+"-audit-decision:"),fallback:"reflect-again",minimum_words:1}' <<<"$state")" || return 2
  git_audit_decision_current "$(jq -nc --argjson spec "$spec" '{spec:$spec}')" || {
    printf 'audit-decision: context changed; retry from the current prompt\n' >&2; return 2;
  }
  # shellcheck source=timed-user-prompt.sh
  source "$library/timed-user-prompt.sh" || return 2
  # shellcheck source=user-question.sh
  source "$library/user-question.sh" || return 2
  request="$(timed_user_prompt request "$path" "$spec")" || return 2
  git_audit_decision_current "$request" || return 2
  id="$(jq -r .id <<<"$request")"
  case "$(jq -r .status <<<"$request")" in
    accepted)
      if [[ "$(jq -r '.response | endswith("Stop")' <<<"$request")" == true ]]; then
        jq -nc --arg history "$history" '{action:"stop",reason:
          ("audit-decision: the human chose Stop; verification remains incomplete. History: " + $history)}'
        return
      fi
      printf '%s\n' '{"action":"continue","reason":""}'; return 0 ;;
    expired)
      timed_user_prompt fallback "$path" "$id" >/dev/null || return 2
      printf '%s\n' '{"action":"continue","reason":""}'; return 0 ;;
    pending)
      instruction="$(timed_user_prompt_instruction "$library/../.." "$request")" || return 2
      instruction="$(user_question render "$library/../.." audit/git-audit-decision \
        "prefix=$kind-audit-decision:" "history=$history" "instruction=$instruction")" || return 2
      jq -nc --arg reason "$instruction" --arg path "$path" '{action:"wait",reason:$reason,request_path:$path}'
      return ;;
    *) printf 'audit-decision: invalid checkpoint status\n' >&2; return 2 ;;
  esac
}

git_audit_checkpoint() { # Legacy callers retain stderr and exit 2 for a blocked checkpoint.
  local result
  result="$(git_audit_checkpoint_result "$@")" || return 2
  [[ "$(jq -r .action <<<"$result")" != continue ]] || return 0
  jq -r .reason <<<"$result" >&2
  return 2
}

git_audit_decision_reply() { # actual UserPromptSubmit payload, repository root, plugin root
  local payload="$1" root="$2" plugin="$3" reply parsed kind id scope path snapshot request
  # shellcheck source=user-question.sh
  source "$plugin/.agents/lib/user-question.sh" || return 1
  parsed="$(user_question git-reply "$plugin" "$payload" 2>/dev/null)" || return 1
  reply="$(jq -er .text <<<"$parsed")" || return 1
  kind="$(jq -r .kind <<<"$parsed")"; id="$(jq -r .id <<<"$parsed")"
  scope="$(verdict_audit_scope_from_hook_payload "$payload" "$root")" || return 1
  path="$root/.agents/state/$kind-audit-decision-request-$scope.json"
  snapshot="$(verdict_audit_read_regular_state "$path" 16384 json 2>/dev/null)" || return 1
  request="${snapshot#*$'\n'}"
  jq -e --arg root "$root" --arg scope "$scope" --arg id "$id" \
    '.id==$id and .spec.binding.root==$root and .spec.binding.session==$scope' <<<"$request" >/dev/null || return 1
  git_audit_decision_current "$request" || return 1
  # shellcheck source=timed-user-prompt.sh
  source "$plugin/.agents/lib/timed-user-prompt.sh" || return 1
  timed_user_prompt prompt-reply "$path" "$id" "$reply" >/dev/null 2>&1 || return 1
  git_audit_decision_current "$request" || return 1
  printf 'audit-decision: recorded %s; retained the failed audit cycle\n' "$reply"
}
