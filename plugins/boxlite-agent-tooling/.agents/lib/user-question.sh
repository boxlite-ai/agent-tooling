#!/usr/bin/env bash
# Shared question rendering and reply envelopes. Callers own request authority.

user_question() (  # operation, plugin root, operation arguments
  local question_operation="$1" question_root="$2" request prefix id template card question fields
  local label_1 label_2 label_3
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
      jq -nr -L "$question_root/.agents/lib" '
        include "user-question-policy";
        "design-decision: <" + user_question_design_choices + "> <reason>"
      '
      ;;
    design-choice)
      jq -ce -L "$question_root/.agents/lib" '
        include "user-question-policy";
        {choice:(.response | if startswith("design-decision: ") then
          capture(user_question_design_pattern).choice else . end), binding:.spec.binding}
      ' <<<"$1"
      ;;
    card)
      request="$1"
      fields="$(jq -er -L "$question_root/.agents/lib" '
        include "user-question-policy";
        def json_string: tojson | .[1:-1];
        user_question_policy(.spec.prefix) as $policy | select($policy != null) |
        $policy.template, (.spec.prefix | json_string), (.id | json_string),
        (user_question_labels($policy) | .[0], .[1], (.[2] // "") | json_string)
      ' <<<"$request")" || return 2
      {
        IFS= read -r template && IFS= read -r prefix && IFS= read -r id &&
          IFS= read -r label_1 && IFS= read -r label_2 && IFS= read -r label_3
      } <<<"$fields"$'\n' || return 2
      card="$(user_question render "$question_root" "$template" "prefix=$prefix" "id=$id" \
        "label_1=$label_1" "label_2=$label_2" "label_3=$label_3")" || return 2
      jq -ce . <<<"$card"
      ;;
    instruction)
      request="$1"
      if [[ "$(jq -r '.question_tool_id // ""' <<<"$request")" != "" ]]; then
        question="$(user_question render "$question_root" questions/timed-route-shown)" || return 2
      else
        card="$(user_question card "$question_root" "$request")" || return 2
        question="$(jq -er --argjson request "$request" '
          .questions[0] | .question, (.options[] |
            .label as $label |
            (if $request.spec.prefix == "design-decision:" then
               "design-decision: " + $label + " <reason>"
             elif $request.spec.fallback == "reflect-again" then
               $request.spec.prefix + " " + $request.id + " " + ($label | sub(" \\(Recommended\\)$"; ""))
             else $label end) as $answer |
            "- `" + $answer + "` — " + .description)
        ' <<<"$card")" || return 2
        question="$(user_question ask "$question_root" "$question" "")" || return 2
      fi
      local deadline fallback
      deadline="$(jq -er .deadline <<<"$request")" || return 2
      fallback="$(jq -er .spec.fallback <<<"$request")" || return 2
      user_question render "$question_root" questions/timed-user-prompt \
        "question=$question" "deadline=$deadline" "fallback=$fallback"
      ;;
    reply)
      jq -ce '
        .prompt | strings | . as $raw |
        gsub("\\A\\s+|\\s+\\z"; "") |
        "<send_user_message_question_reply>" as $open |
        "</send_user_message_question_reply>" as $close |
        if startswith($open) then
          select(endswith($close)) | ltrimstr($open) | rtrimstr($close) |
          fromjson | select(type == "array" and length == 1) | .[0] |
          select(type == "object" and (.answer | type == "string")) |
          {text:.answer, item:.}
        else
          {text:., first_line:($raw | gsub("\r"; "") | split("\n") |
            map(select(test("[^[:space:]]"))) | .[0] // "" | gsub("\\A\\s+|\\s+\\z"; ""))}
        end
      ' <<<"$1"
      ;;
    git-reply)
      user_question reply "$question_root" "$1" |
        jq -cer -L "$question_root/.agents/lib" 'include "user-question-policy"; .text | user_question_git_reply'
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
