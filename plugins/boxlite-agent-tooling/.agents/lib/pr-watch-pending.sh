#!/usr/bin/env bash
# Durable delivery independent of generation journals. Requires the watch-state
# and verdict-state libraries. The branch-lock owner is the only publisher.
_pr_watch_pending_names() {
  perl -e '
    opendir(my $dir, $ARGV[0]) or exit 1;
    my (@names, $count);
    while (defined(my $name = readdir($dir))) {
      exit 1 if ++$count > 1024;
      push @names, $name if $name =~ /\Aevent-[0-9a-f]{64}\.json\z/;
      exit 1 if @names > 128;
    }
    print join("\n", sort @names);
  ' "$1"
}

pr_watch_pending() { # publish|read|ack directory [event-json|event-id]
  local operation="$1" directory="$2" value="${3:-}"
  local identity names name path snapshot body id prior records='[]'
  mkdir -p "$directory" || return 1
  identity="$(pr_watch_state_directory_identity "$directory")" || return 1
  names="$(_pr_watch_pending_names "$directory")" || return 1
  case "$operation" in
    publish)
      # Generation and timestamp describe an observation, not delivery identity.
      body="$(jq -ceS 'del(.ts,.watch_id,.event_id)' <<< "$value")" || return 1
      id="$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')" || return 1
      value="$(jq -c --arg id "$id" '. + {event_id:$id}' <<< "$value")" || return 1
      [[ "$(LC_ALL=C printf '%s' "$value" | wc -c)" -lt 16384 ]] || {
        printf 'pr-watch: pending event exceeds 16384 bytes\n' >&2; return 1;
      }
      path="$directory/event-$id.json"
      if [[ -e "$path" || -L "$path" ]]; then
        snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || return 1
        prior="$(jq -ceS 'del(.ts,.watch_id,.event_id)' <<< "${snapshot#*$'\n'}")" || return 1
        [[ "$prior" == "$body" ]] || return 1
      else
        if [[ "$(printf '%s\n' "$names" | awk 'NF {n++} END {print n+0}')" -ge 128 ]]; then
          printf 'pr-watch: pending delivery capacity reached; polling stopped until drained\n' >&2
          return 1
        fi
        printf '%s\n' "$value" | verdict_audit_write_atomic "$path" || return 1
      fi
      [[ "$(pr_watch_state_directory_identity "$directory")" == "$identity" ]] || return 1
      printf '%s\n' "$value"
      ;;
    read)
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        path="$directory/$name"
        snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || return 1
        body="${snapshot#*$'\n'}"
        id="${name#event-}"; id="${id%.json}"
        jq -e --arg id "$id" 'type == "object" and .event_id == $id
          and (.kind | type == "string")' <<< "$body" >/dev/null || return 1
        prior="$(jq -cS 'del(.ts,.watch_id,.event_id)' <<< "$body" \
          | tr -d '\n' | shasum -a 256 | awk '{print $1}')"
        [[ "$prior" == "$id" ]] || return 1
        records="$(jq -c --argjson event "$body" '. + [$event]' <<< "$records")" || return 1
      done <<< "$names"
      [[ "$(pr_watch_state_directory_identity "$directory")" == "$identity" ]] || return 1
      printf '%s\n' "$records"
      ;;
    ack)
      [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
      path="$directory/event-$value.json"
      [[ -e "$path" || -L "$path" ]] || return 0
      prior="$(verdict_audit_path_identity "$path")" || return 1
      snapshot="$(verdict_audit_read_regular_state "$path" 16384 json "$prior")" || return 1
      jq -e --arg id "$value" '.event_id == $id' <<< "${snapshot#*$'\n'}" >/dev/null || return 1
      [[ "$(pr_watch_state_directory_identity "$directory")" == "$identity" ]] || return 1
      verdict_audit_unlink_if_identity "$path" "$prior"
      ;;
    *) return 2 ;;
  esac
}
