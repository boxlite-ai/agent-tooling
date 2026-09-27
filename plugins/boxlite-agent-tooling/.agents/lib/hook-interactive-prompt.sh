#!/usr/bin/env bash
# Pure renderer for host-native interactive-question instructions.

hook_interactive_prompt_render_claude() {  # prompt-spec JSON
  local spec="$1" question header multi_select option_count index option root payload commands
  spec="$(printf '%s' "$spec" | jq -ec '
    def single_line:
      type == "string" and length > 0
      and (explode | all(. >= 32 and . != 127));
    select(type == "object")
    | select(.question | single_line)
    | select(.header | single_line)
    | select((.multiSelect // false | type) == "boolean")
    | select((.options | type) == "array" and (.options | length) >= 2
             and (.options | length) <= 3)
    | select(all(.options[];
        (.label | single_line)
        and (.description | single_line)
        and (.command | single_line)
        and ((.commandLabel // .label) | single_line)))
  ' 2>/dev/null)" || {
    printf 'hook-interactive-prompt.sh: invalid prompt specification.\n' >&2
    return 2
  }
  question="$(printf '%s' "$spec" | jq -r '.question')"
  header="$(printf '%s' "$spec" | jq -r '.header')"
  multi_select="$(printf '%s' "$spec" | jq -r '.multiSelect // false')"
  option_count="$(printf '%s' "$spec" | jq -r '.options | length')"

  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 2
  # shellcheck source=subagent.sh
  source "$root/.agents/lib/subagent.sh" || return 2
  payload="$(
    printf '  question: %s\n' "$(printf '%s' "$question" | jq -Rs .)"
    printf '  header: %s\n' "$(printf '%s' "$header" | jq -Rs .)"
    printf '  options:\n'
    for ((index = 0; index < option_count; index++)); do
      option="$(printf '%s' "$spec" | jq -c --argjson index "$index" '.options[$index]')"
      printf '    - label: %s\n' "$(printf '%s' "$option" | jq -c '.label')"
      printf '      description: %s\n' "$(printf '%s' "$option" | jq -c '.description')"
    done
    printf '  multiSelect: %s\n' "$multi_select"
  )" || return 2
  commands="$(
    for ((index = 0; index < option_count; index++)); do
      option="$(printf '%s' "$spec" | jq -c --argjson index "$index" '.options[$index]')"
      printf '  %s: %s\n' \
        "$(printf '%s' "$option" | jq -c '
          (.commandLabel // .label) | sub(" \\(Recommended\\)$"; "")')" \
        "$(printf '%s' "$option" | jq -r '.command')"
    done
  )" || return 2
  subagent_prompt interactive-question "$root" "payload=$payload" "commands=$commands"
}
