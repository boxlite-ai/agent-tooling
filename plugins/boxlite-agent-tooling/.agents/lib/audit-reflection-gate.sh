#!/usr/bin/env bash
# Gate adapter. Callers own existing dossier/epoch checks and host-facing output.
# Requires verdict-audit-state.sh, audit-reflection.sh, jq, perl, and git.

audit_reflection_gate() { # context-json operation [attempt-id] [bounded JSON payload]
  local context="$1" operation="$2" id="${3:-}" payload="${4:-}"
  local root key directory path request state history_path snapshot binding current_id
  local LC_ALL=C
  [[ -n "$payload" ]] || payload='{}'
  (( ${#context} <= 8192 && ${#payload} <= 1048576 )) || return 2
  root="$(jq -er '.repo_root | strings' <<<"$context")" || return 2
  [[ "$root" == "$(cd "$root" && pwd -P)" && ! -L "$root/.agents" && ! -L "$root/.agents/state" ]] || return 2
  mkdir -p "$root/.agents/state" || return 2
  key="$(printf '%s' "$context" | jq -cS . | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" || return 2
  directory="$root/.agents/state"
  path="$directory/audit-history-$key.json"
  request="$(jq -nc --argjson context "$context" '{context:$context}')" || return 2
  state="$(printf '%s' "$request" | audit_reflection status "$path")" || return 2
  if [[ "$operation" == inspect ]]; then
    jq -nc --arg path "$path" --argjson state "$state" \
      '{state_path:$path,state:$state,pending:($state.attempts | any(.outcome == null)),
        reflection_due:(([$state.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR"))] | length) >= 2
          and $state.reflection.body.history_hash != $state.history_hash)}'
    return $?
  fi
  if [[ "$operation" == prepare ]]; then
    # Native callers reuse an outstanding request; its input still has to match.
    if [[ -z "$id" ]]; then
      id="$(jq -r '.attempts[-1] | if .outcome == null then .id // "" else "" end' <<<"$state")"
      [[ -n "$id" ]] || id="$(perl -e 'open my $f,"<","/dev/urandom" or exit 2;
        read($f,my $b,16)==16 or exit 2; print unpack("H*",$b)')" || return 2
    fi
    request="$(printf '%s' "$payload" | jq -ce --argjson context "$context" --arg id "$id" \
      '{context:$context,attempt:{id:$id,binding:.binding,snapshot:.snapshot}}')" || return 2
    state="$(printf '%s' "$request" | audit_reflection prepare "$path")" || {
      printf 'audit-reflection: inspect %s; submit reflection through scripts/audit-reflection.sh before retrying\n' "$path" >&2
      return 2
    }
    key="$(printf '%s' "$key:$id" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" || return 2
    history_path="$directory/audit-input-$key.json"
    snapshot="$(jq -cS '.closed=[]' <<<"$state")" || return 2
    if [[ -e "$history_path" || -L "$history_path" ]]; then
      request="$(jq -nc --argjson context "$context" '{context:$context}')" || return 2
      binding="$(printf '%s' "$request" | audit_reflection status "$history_path")" || return 2
      printf '%s\n%s\n' "$state" "$binding" | jq -es '
        .[0].attempts[-1] as $current | .[1] as $input |
        $input.history_hash == $current.history_hash and
        $input.attempts[-1].input == $current.input and
        $input.attempts[-1].reflection_hash == $current.reflection_hash' >/dev/null || return 2
    else
      printf '%s\n' "$snapshot" | verdict_audit_write_exclusive_regular "$history_path" || return 2
    fi
    jq -nc --arg path "$path" --arg input "$history_path" --arg id "$id" \
      '{state_path:$path,history_path:$input,attempt_id:$id}'
    return $?
  fi
  current_id="$(jq -r '.attempts[-1].id // ""' <<<"$state")" || return 2
  [[ -n "$id" && "$id" == "$current_id" ]] || return 2
  if [[ "$operation" == record ]]; then
    if [[ "$(jq -r .gate <<<"$context")" != verdict ]]; then
      payload="$(jq -c '.advisories=(.advisories // []) |
        if .reflection_review == null then del(.reflection_review) else . end' <<<"$payload")" || return 2
    fi
    # Only the original operation may consume the independently supplied judgment.
    binding="$(jq -c '.attempts[-1].input.binding' <<<"$state")" || return 2
    printf '%s' "$payload" | jq -e --argjson binding "$binding" --arg id "$id" '
      . as $dossier | .history_review.attempt_id == $id and
      (.verdict != "FAIL" or (.history_review.findings | length) > 0
        or any(.history_review.dispositions[]; .status == "open" or .status == "not_assessed")) and
      ($binding | to_entries | all(.[]; .value == $dossier[.key]))' >/dev/null || return 2
    request="$(printf '%s' "$payload" | jq -ce --argjson context "$context" --arg id "$id" \
      '{context:$context,id:$id,outcome:({verdict:.verdict,evidence:del(.history_review,.reflection_review),
        history_review:.history_review} + (if has("reflection_review") then {reflection_review} else {} end))}')" || return 2
  elif [[ "$operation" == error || "$operation" == cancel ]]; then
    request="$(jq -nc --argjson context "$context" --arg id "$id" --arg operation "$operation" \
      --arg evidence "$payload" '{context:$context,id:$id,outcome:{
        verdict:(if $operation == "cancel" then "CANCELED" else "ERROR" end),evidence:$evidence}}')" || return 2
  else return 2; fi
  printf '%s' "$request" | audit_reflection record "$path"
}
