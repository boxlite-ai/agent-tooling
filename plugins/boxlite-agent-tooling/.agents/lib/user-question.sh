#!/usr/bin/env bash
# Shared question rendering and reply envelopes. Callers own request authority.

user_question() (  # operation, plugin root, operation arguments
  local question_operation="$1" question_root="$2" request prefix id template question fields
  local label_1 label_2 label_3 deadline fallback
  local args
  shift 2
  case "$question_operation" in
    render)
      [[ "${1:-}" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || return 2
      # shellcheck source=subagent.sh
      source "$question_root/.agents/lib/subagent.sh" || return 2
      subagent_prompt "$1" "$question_root" "${@:2}"
      ;;
    ask)
      [[ "${1:-}" == *[![:space:]]* ]] || return 2
      user_question render "$question_root" questions/ask-once "question=$1" "fallback=$2"
      ;;
    redesign-approval)
      question="$(user_question render "$question_root" questions/redesign-approval)" || return 2
      user_question ask "$question_root" "$question" ""
      ;;
    design-format)
      jq -nr -L "$question_root/.agents/lib" --arg id "${1:-<request-id>}" '
        include "user-question-policy";
        "design-decision: " + $id + " <" + user_question_design_choices + "> <reason>"
      '
      ;;
    design-choice)
      jq -ce -L "$question_root/.agents/lib" '
        include "user-question-policy";
        {choice:(.response | user_question_directive | .answer |
          capture("^(?<choice>" + user_question_design_choices + ")").choice), binding:.spec.binding}
      ' <<<"$1"
      ;;
    instruction)
      request="$1"
      fields="$(jq -er -L "$question_root/.agents/lib" '
        include "user-question-policy";
        user_question_policy(.spec.prefix) as $policy | select($policy != null) |
        .id, .spec.prefix, $policy.template, $policy.choices[]
      ' <<<"$request")" || return 2
      {
        IFS= read -r id && IFS= read -r prefix && IFS= read -r template &&
          IFS= read -r label_1 && IFS= read -r label_2 || return 2
        IFS= read -r label_3 || :
      } <<<"$fields"
      args=("prefix=$prefix" "id=$id" "label_1=$label_1" "label_2=$label_2")
      if [[ -n "$label_3" ]]; then args+=("label_3=$label_3"); fi
      question="$(user_question render "$question_root" "$template" "${args[@]}")" || return 2
      question="$(user_question ask "$question_root" "$question" "")" || return 2
      deadline="$(jq -er .deadline <<<"$request")" || return 2
      fallback="$(jq -er .spec.fallback <<<"$request")" || return 2
      user_question render "$question_root" questions/timed-user-prompt \
        "question=$question" "deadline=$deadline" "fallback=$fallback"
      ;;
    reply)
      jq -ce -L "$question_root/.agents/lib" '
        include "user-question-policy";
        def trim: gsub("\\A\\s+|\\s+\\z"; "");
        .prompt | strings | trim as $text |
        ($text | split("\n")[0] | trim) as $line |
        ($line | user_question_directive) as $reply |
        select(user_question_policy($reply.prefix) != null) |
        select(($reply.prefix | IN("reviewed:", "design-decision:")) or $line == $text) |
        $reply + {text:$line}
      ' <<<"$1"
      ;;
    api-directive)
      jq -er '.directive | strings | select(length > 0)' "$question_root/.agents/lib/api-question.json"
      ;;
    api-match)
      local directive
      directive="$(user_question api-directive "$question_root")" || return 2
      # Preserve the trailing LF normalization of the original Bash prompt reader.
      jq -er --arg directive "$directive" '
        select(.hook_event_name == "UserPromptSubmit" and
          (.session_id | type == "string" and length > 0) and
          ((.prompt | strings | sub("\n+\\z"; "")) == $directive)) | $directive
      ' <<<"$1"
      ;;
    *) printf 'user_question: unknown operation %s\n' "$question_operation" >&2; return 2 ;;
  esac
)
