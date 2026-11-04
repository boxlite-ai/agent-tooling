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

git_audit_checkpoint() { # library directory, validated history JSON, history path; history lock held
  local library="$1" state="$2" history="$3" root scope kind path spec request id instruction
  jq -e -L "$library" 'include "audit-reflection-contract"; audit_git_decision_due' <<<"$state" >/dev/null || return 0
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
  # shellcheck source=subagent.sh
  source "$library/subagent.sh" || return 2
  request="$(timed_user_prompt request "$path" "$spec")" || return 2
  git_audit_decision_current "$request" || return 2
  id="$(jq -r .id <<<"$request")"
  case "$(jq -r .status <<<"$request")" in
    accepted)
      if [[ "$(jq -r '.response | endswith("Stop")' <<<"$request")" == true ]]; then
        printf 'audit-decision: the human chose Stop; verification remains incomplete. History: %s\n' "$history" >&2
        return 2
      fi
      return 0 ;;
    expired)
      timed_user_prompt fallback "$path" "$id" >/dev/null || return 2
      return 0 ;;
    pending)
      instruction="$(timed_user_prompt_instruction "$library/../.." "$request")" || return 2
      subagent_prompt audit/git-audit-decision "$library/../.." \
        "prefix=$kind-audit-decision:" "id=$id" "history=$history" "instruction=$instruction" >&2 || return 2
      return 2 ;;
    *) printf 'audit-decision: invalid checkpoint status\n' >&2; return 2 ;;
  esac
}

git_audit_decision_reply() { # actual UserPromptSubmit payload, repository root, plugin root
  local payload="$1" root="$2" plugin="$3" reply parsed kind id scope path snapshot request
  # A Codex question answer may arrive in a structured user-message wrapper.
  # Accept exactly one answer; mixed messages keep ordinary prompt cancellation.
  reply="$(jq -er '
    .prompt | strings | gsub("^\\s+|\\s+$";"") |
    if startswith("<send_user_message_question_reply>") and endswith("</send_user_message_question_reply>")
    then ltrimstr("<send_user_message_question_reply>") | rtrimstr("</send_user_message_question_reply>")
      | fromjson | select(type=="array" and length==1) | .[0].answer | strings
    else . end |
    select(test("^(commit|push)-audit-decision: [0-9a-f]{32} (Reflect again|Stop)$"))
  ' <<<"$payload" 2>/dev/null)" || return 1
  parsed="$(jq -nc --arg reply "$reply" '$reply | capture("^(?<kind>commit|push)-audit-decision: (?<id>[0-9a-f]{32}) ")')" || return 1
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
