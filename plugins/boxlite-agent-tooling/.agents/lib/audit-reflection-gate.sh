#!/usr/bin/env bash
# Gate adapter. Callers own existing dossier/epoch checks and host-facing output.
# Requires verdict-audit-state.sh, audit-reflection.sh, jq, perl, and git.

audit_reflection_gate() { # context-json operation [attempt-id] [bounded JSON payload]
  local context="$1" operation="$2" id="${3:-}" payload="${4:-}"
  local root key scope_key input_key directory path request state history_path snapshot binding current_id
  local session epoch actual_epoch
  local LC_ALL=C
  [[ -n "$payload" ]] || payload='{}'
  (( ${#context} <= 8192 && ${#payload} <= 1048576 )) || return 2
  root="$(jq -er '.repo_root | strings' <<<"$context")" || return 2
  [[ "$root" == "$(cd "$root" && pwd -P)" && ! -L "$root/.agents" && ! -L "$root/.agents/state" ]] || return 2
  mkdir -p "$root/.agents/state" || return 2
  key="$(printf '%s' "$context" | jq -cS . | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" || return 2
  directory="$root/.agents/state"
  session="$(jq -r .session <<<"$context")"
  epoch="$(jq -r .epoch <<<"$context")"
  if [[ "$operation" == prepare || "$operation" == record ]] \
     && [[ "$session" =~ ^git-[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    actual_epoch=0
    if [[ -e "$directory/verdict-prompt-epoch.$session" || -L "$directory/verdict-prompt-epoch.$session" ]]; then
      actual_epoch="$(verdict_audit_read_single_record "$directory/verdict-prompt-epoch.$session")" || return 2
    fi
    [[ "$epoch" == "$actual_epoch" ]] || { printf 'audit-reflection: prompt epoch changed\n' >&2; return 2; }
  fi
  scope_key="$(printf '%s\n%s' "$root" "$session" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"
  path="$directory/audit-history-$scope_key-$key.json"
  request="$(jq -nc --argjson context "$context" '{context:$context}')" || return 2
  state="$(printf '%s' "$request" | audit_reflection status "$path")" || return 2
  if [[ "$operation" == inspect ]]; then
    jq -c --arg path "$path" \
      '. as $state | {state_path:$path,state:$state,pending:($state.attempts | any(.outcome == null)),
        unresolved:(($state.attempts[-1].outcome.verdict | IN("PASS","IN_PROGRESS") | not) and
          (any($state.attempts[]; .outcome.verdict | IN("FAIL","ERROR")) or
            any($state.registry[]; .status | IN("open","not_assessed")))),
        reflection_due:(([$state.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR"))] | length) >= 2
          and $state.reflection.body.history_hash != $state.history_hash)}' <<<"$state"
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
    [[ "$(jq -r '.attempts[-1].id' <<<"$state")" == "$id" ]] || return 2
    input_key="$(printf '%s' "$key:$id" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" || return 2
    history_path="$directory/audit-input-$scope_key-$key-$input_key.json"
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
    _audit_reflection_prune "$directory" "$scope_key" "$key" "$epoch" "$history_path" || return 2
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

_audit_reflection_remove() {
  local identity
  [[ -e "$1" || -L "$1" ]] || return 0
  identity="$(verdict_audit_path_identity "$1")" || return 2
  verdict_audit_unlink_if_identity "$1" "$identity"
}

_audit_reflection_prune() { # directory, session key, context key, epoch, active input
  local directory="$1" scope="$2" key="$3" epoch="$4" active="$5"
  local file snapshot identity retired="" record old_key
  # Only the current immutable input is needed: it embeds all prior cycle evidence.
  for file in "$directory/audit-input-$scope-$key-"*.json; do
    [[ "$file" != "$active" && -e "$file" ]] || continue
    _audit_reflection_remove "$file" || return 2
    _audit_reflection_remove "$file.mutex" || return 2
  done
  for file in "$directory/audit-history-$scope-"*.json; do
    [[ -e "$file" ]] || continue
    identity="$(verdict_audit_path_identity "$file")" || return 2
    snapshot="$(verdict_audit_read_regular_state "$file" 1048576 json)" || return 2
    if [[ "$(jq -r .context.epoch <<<"${snapshot#*$'\n'}")" == "$epoch" ]]; then continue; fi
    record="$(jq -nc --arg path "$file" --arg identity "$identity" \
      --argjson time "${snapshot%%$'\n'*}" '{path:$path,identity:$identity,time:$time}')" || return 2
    retired+="$record"$'\n'
  done
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    file="$(jq -r .path <<<"$record")"; identity="$(jq -r .identity <<<"$record")"
    # A prompt change revoked this context; an overlapping diagnostic writer may
    # retain its replaced inode until the next sweep, never affect live authority.
    verdict_audit_selected_identity_matches "$file" "$identity" || continue
    old_key="${file##*audit-history-$scope-}"; old_key="${old_key%.json}"
    for snapshot in "$directory/audit-input-$scope-$old_key-"*.json; do
      [[ -e "$snapshot" ]] || continue
      _audit_reflection_remove "$snapshot" || return 2
      _audit_reflection_remove "$snapshot.mutex" || return 2
    done
    verdict_audit_unlink_if_identity "$file" "$identity" || continue
    _audit_reflection_remove "$file.mutex" || return 2
  done < <(printf '%s' "$retired" | jq -sc 'sort_by(.time,.path) | reverse | .[4:][]')
}
