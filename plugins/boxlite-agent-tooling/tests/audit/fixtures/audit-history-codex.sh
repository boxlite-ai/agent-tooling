#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" != --version ]] || { printf 'test codex\n'; exit 0; }
output=""
while (( $# )); do
  case "$1" in --output-last-message|-o) output="$2"; shift 2 ;; *) shift ;; esac
done
prompt="$(cat)"
printf 'run\n' >> "$CLAUDE_PROJECT_DIR/.agents/state/model-runs"
input="$(sed -n '/^{"target_command"/p' <<<"$prompt")"
head="$(sed -n 's/^Expected HEAD: //p' <<<"$prompt")"
diff="$(sed -n 's/^Expected diff hash: //p' <<<"$prompt")"
command="$(sed -n 's/^Expected command hash: //p' <<<"$prompt")"
subject="$(sed -n 's/^Expected commit subject hash: //p' <<<"$prompt")"
jq -nc --argjson input "$input" --arg head "$head" --arg diff "$diff" \
  --arg command "$command" --arg subject "$subject" --arg verdict "${TEST_HISTORY_VERDICT:-FAIL}" \
  '{branch:$input.expected_branch,head:$head,command_kind:$input.operation_kind,diff_hash:$diff,
    command_hash:$command,commit_subject_hash:$subject,verdict:$verdict,advisories:[],
    findings:(if $verdict == "PASS" then [] else ["test: missing evidence"] end)}' > "$output"
history="$(sed -n 's/^History input JSON: //p' <<<"$prompt")"
if [[ -n "$history" ]]; then bash "$TEST_HISTORY_RESULT_HELPER" "$history" "$output"; fi
