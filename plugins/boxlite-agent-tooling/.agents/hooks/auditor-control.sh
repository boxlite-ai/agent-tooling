#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Host-neutral auditor escalation state plus Claude re-wake and portable fallback output.
set -uo pipefail

tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verdict_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
override_state_lib="$tooling_root/.agents/lib/auditor-override-state.sh"
control_state_lib="$tooling_root/.agents/lib/auditor-control-state.sh"
interactive_prompt_lib="$tooling_root/.agents/lib/hook-interactive-prompt.sh"
host_lib="$tooling_root/.agents/lib/hook-host.sh"
for required in jq perl git shasum; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'auditor-control.sh: required dependency not found: %s\n' "$required" >&2
    exit 2
  }
done
[[ -r "$verdict_state_lib" && -r "$override_state_lib" \
   && -r "$control_state_lib" && -r "$interactive_prompt_lib" \
   && -r "$host_lib" ]] || {
  printf 'auditor-control.sh: shared state libraries are unavailable.\n' >&2
  exit 2
}
# shellcheck source=../lib/verdict-audit-state.sh
source "$verdict_state_lib"
# shellcheck source=../lib/auditor-override-state.sh
source "$override_state_lib"
# shellcheck source=../lib/auditor-control-state.sh
source "$control_state_lib"
# shellcheck source=../lib/hook-interactive-prompt.sh
source "$interactive_prompt_lib"
# shellcheck source=../lib/hook-host.sh
source "$host_lib"

# Module context is populated once repository identity has been validated below.
auditor_control_state_dir=

auditor_control_known_auditors() {
  printf '%s\n' commit-push-auditor verdict-auditor
}

auditor_control_canonical_auditor() {  # host agent type/name
  case "$1" in
    commit-push-auditor|commit_push_auditor) printf 'commit-push-auditor' ;;
    verdict-auditor|verdict_auditor) printf 'verdict-auditor' ;;
    *) return 1 ;;
  esac
}

auditor_control_canonical_auditor_from_path() {  # Codex orchestration agent path
  local agent_name="${1##*/}"
  case "$agent_name" in
    commit-push-auditor|commit-push-auditor_*|commit_push_auditor|commit_push_auditor_*)
      printf 'commit-push-auditor'
      ;;
    verdict-auditor|verdict-auditor_*|verdict_auditor|verdict_auditor_*)
      printf 'verdict-auditor'
      ;;
    *) return 1 ;;
  esac
}

auditor_control_read_first_transcript_record() {  # transcript path
  perl -MFcntl=:DEFAULT -e '
    my ($path, $max) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $record = "";
    while (index($record, "\n") < 0 && length($record) <= $max) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 4096);
      exit 1 unless defined $count;
      last if $count == 0;
      $record .= $chunk;
    }
    my $newline = index($record, "\n");
    $record = substr($record, 0, $newline) if $newline >= 0;
    my @named_after = lstat($path);
    exit 1 unless @named_after
      && $opened[0] == $named_after[0] && $opened[1] == $named_after[1];
    alarm 0;
    exit 1 if $record eq "" || length($record) > $max || $record =~ /[\0\r]/;
    print $record;
  ' "$1" 65536
}

auditor_control_auditor_from_payload() {  # hook payload, event
  local payload="$1" event="$2" agent_type transcript_path session_meta agent_path
  agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // ""')"
  if auditor_control_canonical_auditor "$agent_type"; then
    return 0
  fi
  # Codex reports registered subagents as `default`, so only that host shape needs
  # transcript metadata fallback. Claude supplies the concrete agent type; attempting
  # to parse every other agent's Claude transcript as Codex session metadata turns
  # unrelated SubagentStop events into noisy fail-closed hook errors.
  [[ "$agent_type" == default ]] || return 1
  case "$event" in
    SubagentStart)
      transcript_path="$(printf '%s' "$payload" | jq -r \
        'if (.transcript_path|type)=="string" then .transcript_path else "" end')"
      ;;
    SubagentStop)
      transcript_path="$(printf '%s' "$payload" | jq -r '
        if (.agent_transcript_path|type)=="string" then .agent_transcript_path
        elif (.transcript_path|type)=="string" then .transcript_path
        else "" end')"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$transcript_path" ]] || return 1
  session_meta="$(auditor_control_read_first_transcript_record "$transcript_path" 2>/dev/null)" || return 2
  agent_path="$(printf '%s' "$session_meta" | jq -er \
    --arg session "$(printf '%s' "$payload" | jq -r '.session_id')" \
    --arg agent "$(printf '%s' "$payload" | jq -r '.agent_id // ""')" '
      if .type == "session_meta"
         and .payload.id == $agent
         and .payload.session_id == $session
         and .payload.thread_source == "subagent"
         and .payload.source.subagent.thread_spawn.parent_thread_id == $session
         and (.payload.source.subagent.thread_spawn.agent_path | type) == "string"
      then .payload.source.subagent.thread_spawn.agent_path
      else empty end
    ' 2>/dev/null)" || return 2
  auditor_control_canonical_auditor_from_path "$agent_path"
}

auditor_control_project_repo() {
  local start="${CLAUDE_PROJECT_DIR:-$PWD}" root
  root="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" || return 1
  (cd "$root" && pwd -P)
}

auditor_control_prompt_epoch_for() {  # repo scope
  local path value
  [[ "$2" != "-" ]] || { printf '-'; return; }
  path="$1/.agents/state/verdict-prompt-epoch.$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then printf '-'; return; fi
  value="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || return 1
  [[ "$value" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

auditor_control_safe_generation() {  # agent id
  if [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s' "$1"
  else
    printf 'git-%s' "$(printf '%s' "$1" | git -C "$repo" hash-object --stdin)"
  fi
}

auditor_control_write_json_atomic() {  # path; JSON on stdin
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  verdict_audit_write_atomic "$1"
}

auditor_control_append_event() {  # JSON line
  verdict_audit_append_log_line "$events_file" "$1" 2>/dev/null || true
}

auditor_control_active_record_is_bound() {  # JSON scope auditor exact-path
  printf '%s' "$1" | jq -e --arg scope "$2" --arg auditor "$3" '
    type == "object"
    and .session_scope == $scope
    and .auditor == $auditor
    and .state == "running"
    and ((.generation | type) == "string"
         and (.generation | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
    and ((.prompt_epoch | type) == "string"
         and (.prompt_epoch | test("^(-|[1-9][0-9]*-[1-9][0-9]*-[0-9]+)$")))
    and ((.started_at | type) == "number" and .started_at >= 1
         and .started_at <= 999999999999999999
         and .started_at == (.started_at | floor))
  ' >/dev/null 2>&1 \
    && [[ "$4" == "$auditor_control_state_dir/active.$2.$3.json" ]]
}

auditor_control_escalation_record_is_bound() {  # JSON scope auditor generation exact-path
  printf '%s' "$1" | jq -e --arg scope "$2" --arg auditor "$3" \
    --arg generation "$4" '
    type == "object"
    and .session_scope == $scope
    and .auditor == $auditor
    and .generation == $generation
    and (.state == "open" or .state == "closed")
    and ((.prompt_epoch | type) == "string"
         and (.prompt_epoch | test("^(-|[1-9][0-9]*-[1-9][0-9]*-[0-9]+)$")))
    and ((.opened_at | type) == "number" and .opened_at >= 1
         and .opened_at <= 999999999999999999
         and .opened_at == (.opened_at | floor))
  ' >/dev/null 2>&1 \
    && [[ "$(auditor_control_canonical_auditor "$3" 2>/dev/null)" == "$3" \
       && "$(auditor_control_safe_generation "$4")" == "$4" \
       && "$5" == "$auditor_control_state_dir/escalation.$2.$3.$4.json" ]]
}

auditor_control_pending_stop_record_is_bound() {  # JSON scope auditor generation now max-age exact-path
  printf '%s' "$1" | jq -e --arg scope "$2" --arg auditor "$3" \
    --arg generation "$4" --argjson now "$5" --argjson max_age "$6" '
    type == "object"
    and .session_scope == $scope
    and .auditor == $auditor
    and .generation == $generation
    and ((.created_at | type) == "number" and .created_at >= 1
         and .created_at <= $now and $now <= .created_at + $max_age
         and .created_at == (.created_at | floor))
  ' >/dev/null 2>&1 \
    && [[ "$7" == "$auditor_control_state_dir/pending-stop.$2.$3.$4.json" ]]
}

auditor_control_completion_record_is_bound() {  # JSON scope auditor generation exact-path
  printf '%s' "$1" | jq -e --arg scope "$2" --arg auditor "$3" \
    --arg generation "$4" '
    type == "object"
    and .session_scope == $scope
    and .auditor == $auditor
    and .generation == $generation
    and ((.created_at | type) == "number" and .created_at >= 1
         and .created_at <= 999999999999999999
         and .created_at == (.created_at | floor))
    and (((.remaining // 1) | type) == "number"
         and (.remaining // 1) >= 1 and (.remaining // 1) <= 1024
         and (.remaining // 1) == ((.remaining // 1) | floor))
  ' >/dev/null 2>&1 \
    && [[ "$(auditor_control_canonical_auditor "$3" 2>/dev/null)" == "$3" \
       && "$5" == "$auditor_control_state_dir/completion.$2.$3.$4.json" ]]
}

auditor_control_write_pending_stop_receipt() {  # scope auditor generation
  local receipt_scope="$1" auditor="$2" generation="$3"
  local pending_file="$auditor_control_state_dir/pending-stop.$receipt_scope.$auditor.$generation.json"
  if [[ -e "$pending_file" || -L "$pending_file" ]] \
     && ! verdict_audit_read_single_record "$pending_file" >/dev/null 2>&1; then
    auditor_control_state_retire_cache_entry "$pending_file" || return 1
  fi
  jq -nc --arg auditor "$auditor" --arg generation "$generation" \
    --arg scope "$receipt_scope" --argjson now "$(date +%s)" \
    '{auditor:$auditor,generation:$generation,session_scope:$scope,created_at:$now}' \
    | auditor_control_write_json_atomic "$pending_file"
}

auditor_control_add_completion_receipt() {  # scope auditor generation
  local receipt_scope="$1" auditor="$2" generation="$3"
  local completion_file="$auditor_control_state_dir/completion.$receipt_scope.$auditor.$generation.json"
  local completion_json created_at remaining now
  now="$(date +%s)"; remaining=1
  if [[ -e "$completion_file" || -L "$completion_file" ]]; then
    completion_json="$(verdict_audit_read_single_record "$completion_file" 2>/dev/null)" \
      || {
        auditor_control_state_retire_cache_entry "$completion_file" || return 1
        completion_json=""
      }
  fi
  if [[ -n "$completion_json" ]]; then
    created_at="$(printf '%s' "$completion_json" | jq -r '.created_at // ""')"
    if ! auditor_control_completion_record_is_bound "$completion_json" \
        "$receipt_scope" "$auditor" "$generation" "$completion_file"; then
      auditor_control_state_retire_cache_entry "$completion_file" || return 1
      completion_json=""
    fi
  fi
  if [[ -n "$completion_json" ]]; then
    remaining="$(printf '%s' "$completion_json" | jq -r '.remaining // 1')"
    if (( created_at <= now && now <= created_at + 300 )); then
      (( remaining < 1024 )) || return 1
      remaining="$((remaining + 1))"
    else
      remaining=1
    fi
  fi
  jq -nc --arg auditor "$auditor" --arg generation "$generation" \
    --arg scope "$receipt_scope" --argjson now "$now" --argjson remaining "$remaining" \
    '{auditor:$auditor,generation:$generation,session_scope:$scope,
      created_at:$now,remaining:$remaining}' | auditor_control_write_json_atomic "$completion_file"
}

auditor_control_preserve_active_completion_receipts() {
  local active_file active_json auditor generation record_scope state
  for active_file in "$auditor_control_state_dir"/active."$scope".*.json; do
    [[ -e "$active_file" || -L "$active_file" ]] || continue
    active_json="$(verdict_audit_read_single_record "$active_file" 2>/dev/null)" || {
      auditor_control_state_retire_cache_entry "$active_file" || return 1
      continue
    }
    auditor="$(printf '%s' "$active_json" | jq -r '.auditor // ""')"
    generation="$(printf '%s' "$active_json" | jq -r '.generation // ""')"
    record_scope="$(printf '%s' "$active_json" | jq -r '.session_scope // ""')"
    state="$(printf '%s' "$active_json" | jq -r '.state // ""')"
    if [[ "$record_scope" != "$scope" || "$state" != running \
          || "$(auditor_control_canonical_auditor "$auditor" 2>/dev/null)" != "$auditor" \
          || -z "$generation" || "$(auditor_control_safe_generation "$generation")" != "$generation" \
          || "$active_file" != "$auditor_control_state_dir/active.$scope.$auditor.json" ]]; then
      auditor_control_state_retire_cache_entry "$active_file" || return 1
      continue
    fi
    auditor_control_write_pending_stop_receipt "$scope" "$auditor" "$generation" || return 1
    auditor_control_state_retire_cache_entry "$active_file" || return 1
  done
}

auditor_control_close_scope_state() {  # terminal, retires active records and closes open escalations
  local terminal="$1" path json generation auditor escalation_state
  auditor_control_preserve_active_completion_receipts || return 1
  for path in "$auditor_control_state_dir"/escalation."$scope".*.json; do
    [[ -e "$path" || -L "$path" ]] || continue
    json="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || {
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    }
    auditor="$(printf '%s' "$json" | jq -r '.auditor // ""')"
    generation="$(printf '%s' "$json" | jq -r '.generation // ""')"
    if ! auditor_control_escalation_record_is_bound \
        "$json" "$scope" "$auditor" "$generation" "$path"; then
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    fi
    escalation_state="$(printf '%s' "$json" | jq -r '.state // ""')"
    [[ "$escalation_state" == open ]] || continue
    printf '%s' "$json" | jq -c --arg terminal "$terminal" --argjson now "$(date +%s)" \
      '.state="closed" | .terminal=$terminal | .closed_at=$now' \
      | auditor_control_write_json_atomic "$path" || continue
    auditor_control_append_event "$(jq -nc --arg event closed --arg auditor "$auditor" \
      --arg generation "$generation" --arg terminal "$terminal" \
      '{event:$event,auditor:$auditor,generation:$generation,terminal:$terminal}')"
  done
  auditor_control_prune_expired_completion_receipts
  auditor_control_prune_expired_pending_stop_receipts
}

auditor_control_prune_expired_completion_receipts() {
  local path json created_at now
  now="$(date +%s)"
  for path in "$auditor_control_state_dir"/completion."$scope".*.json; do
    [[ -e "$path" || -L "$path" ]] || continue
    json="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || {
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    }
    created_at="$(printf '%s' "$json" | jq -r '.created_at // ""')"
    if [[ ! "$created_at" =~ ^[1-9][0-9]*$ || ${#created_at} -gt 18 ]] \
       || (( created_at > now || now > created_at + 300 )); then
      auditor_control_state_retire_cache_entry "$path" || return 1
    fi
  done
}

auditor_control_prune_expired_pending_stop_receipts() {
  local path json created_at now max_age
  now="$(date +%s)"
  # Public lease constants come from verdict-audit-state.sh sourced above.
  # shellcheck disable=SC2154
  max_age="$((verdict_audit_lock_max_seconds + verdict_audit_deadline_slack_seconds))"
  for path in "$auditor_control_state_dir"/pending-stop."$scope".*.json; do
    [[ -e "$path" || -L "$path" ]] || continue
    json="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || {
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    }
    created_at="$(printf '%s' "$json" | jq -r '.created_at // ""')"
    if [[ ! "$created_at" =~ ^[1-9][0-9]*$ || ${#created_at} -gt 18 ]] \
       || (( created_at > now || now > created_at + max_age )); then
      auditor_control_state_retire_cache_entry "$path" || return 1
    fi
  done
}

auditor_control_open_escalation_exists() {  # expected epoch
  local expected_epoch="$1" path json auditor generation
  for path in "$auditor_control_state_dir"/escalation."$scope".*.json; do
    [[ -e "$path" || -L "$path" ]] || continue
    json="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || {
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    }
    auditor="$(printf '%s' "$json" | jq -r '.auditor // ""')"
    generation="$(printf '%s' "$json" | jq -r '.generation // ""')"
    if ! auditor_control_escalation_record_is_bound \
        "$json" "$scope" "$auditor" "$generation" "$path"; then
      auditor_control_state_retire_cache_entry "$path" || return 1
      continue
    fi
    [[ "$(printf '%s' "$json" | jq -r '.state // ""')" == open \
       && "$(printf '%s' "$json" | jq -r '.prompt_epoch // ""')" == "$expected_epoch" ]] \
      && return 0
  done
  return 1
}

auditor_control_write_override_grant() {  # scope epoch reason-hash
  local grant_file now expires nonce_hash repo_hash
  grant_file="$(auditor_override_grant_path "$repo" "$1")"
  now="$(date +%s)"; expires="$((now + 3600))"
  nonce_hash="$(perl -e 'open(my $f,"<","/dev/urandom") or exit 1; read($f,my $b,32)==32 or exit 1; print unpack("H*",$b)' \
    | shasum -a 256 | awk '{print $1}')" || return 1
  repo_hash="$(auditor_override_repo_identity "$repo")" || return 1
  jq -nc --arg repo_hash "$repo_hash" --arg scope "$1" --arg epoch "$2" \
    --arg nonce_hash "$nonce_hash" --arg reason_hash "$3" \
    --argjson created "$now" --argjson expires "$expires" \
    '{repo_hash:$repo_hash,session_scope:$scope,prompt_epoch:$epoch,created_at:$created,
      expires_at:$expires,nonce_hash:$nonce_hash,reason_hash:$reason_hash}' \
    | auditor_control_write_json_atomic "$grant_file"
}

auditor_control_random_nonce() {
  perl -e '
    open(my $random, "<", "/dev/urandom") or exit 1;
    read($random, my $bytes, 32) == 32 or exit 1;
    print unpack("H*", $bytes);
  '
}

if [[ "${1:-}" == --known-auditors ]]; then
  auditor_control_known_auditors
  exit 0
fi

repo="$(auditor_control_project_repo)" || {
  printf 'auditor-control.sh: project directory is not a Git repository.\n' >&2
  exit 1
}
auditor_control_state_initialize "$repo" "$0" || exit 1

case "${1:-}" in
  external-start)
    auditor="$2"; generation="$3"; scope="$4"; epoch="$5"
    auditor_control_canonical_auditor "$auditor" >/dev/null 2>&1 || exit 1
    auditor_control_state_dispatch start "$scope" "$auditor" "$generation" "$epoch" \
      || exit $?
    threshold="${AUDITOR_PROMPT_AFTER_SECONDS:-30}"
    [[ "$threshold" =~ ^[0-9]+$ && ${#threshold} -le 4 ]] || threshold=30
    nohup /usr/bin/env bash "$0" --external-wait \
      "$auditor" "$generation" "$scope" "$epoch" "$threshold" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    exit 0
    ;;
  --external-wait)
    auditor="$2"; generation="$3"; scope="$4"; epoch="$5"; threshold="$6"
    perl -e 'select(undef,undef,undef,$ARGV[0])' "$threshold"
    auditor_control_state_dispatch escalate "$scope" "$auditor" "$generation" "$epoch" \
      >/dev/null 2>&1 || true
    exit 0
    ;;
  external-stop)
    auditor="$2"; generation="$3"; scope="$4"; terminal="$5"
    auditor_control_state_dispatch stop "$scope" "$auditor" "$generation" "$terminal" \
      || exit $?
    exit 0
    ;;
  --locked-start)
    scope="$2"; auditor="$3"; generation="$4"; epoch="$5"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    active_file="$auditor_control_state_dir/active.$scope.$auditor.json"
    escalation_file="$auditor_control_state_dir/escalation.$scope.$auditor.$generation.json"
    if [[ -e "$escalation_file" || -L "$escalation_file" ]]; then
      escalation_json="$(verdict_audit_read_single_record "$escalation_file" 2>/dev/null)" \
        || escalation_json=""
      if auditor_control_escalation_record_is_bound \
          "$escalation_json" "$scope" "$auditor" "$generation" "$escalation_file"; then
        exit 0
      fi
      auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
    fi
    if [[ -e "$active_file" || -L "$active_file" ]]; then
      active_json="$(verdict_audit_read_single_record "$active_file" 2>/dev/null)" \
        || active_json=""
      if auditor_control_active_record_is_bound \
          "$active_json" "$scope" "$auditor" "$active_file"; then
        active_generation="$(printf '%s' "$active_json" | jq -r '.generation')"
        active_epoch="$(printf '%s' "$active_json" | jq -r '.prompt_epoch')"
        if [[ "$active_generation" == "$generation" && "$active_epoch" == "$epoch" ]]; then
          exit 0
        fi
        # One active slot per auditor is an orchestration index, not ownership of the
        # displaced task. Preserve its one later completion delivery before replacement.
        auditor_control_write_pending_stop_receipt "$scope" "$auditor" "$active_generation" || exit 1
      fi
      auditor_control_state_retire_cache_entry "$active_file" || exit 1
    fi
    jq -nc --arg auditor "$auditor" --arg generation "$generation" \
      --arg scope "$scope" --arg epoch "$epoch" --argjson now "$(date +%s)" \
      '{auditor:$auditor,generation:$generation,session_scope:$scope,prompt_epoch:$epoch,started_at:$now,state:"running"}' \
      | auditor_control_write_json_atomic "$active_file" || exit 1
    exit 0
    ;;
  --locked-escalate)
    scope="$2"; auditor="$3"; generation="$4"; epoch="$5"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    active_file="$auditor_control_state_dir/active.$scope.$auditor.json"
    escalation_file="$auditor_control_state_dir/escalation.$scope.$auditor.$generation.json"
    active_json="$(verdict_audit_read_single_record "$active_file" 2>/dev/null)" \
      || active_json=""
    if ! auditor_control_active_record_is_bound \
        "$active_json" "$scope" "$auditor" "$active_file"; then
      auditor_control_state_retire_cache_entry "$active_file" || exit 1
      exit 3
    fi
    [[ "$(printf '%s' "$active_json" | jq -r '.generation')" == "$generation" \
       && "$(printf '%s' "$active_json" | jq -r '.prompt_epoch')" == "$epoch" ]] || exit 3
    if [[ -e "$escalation_file" || -L "$escalation_file" ]]; then
      escalation_json="$(verdict_audit_read_single_record "$escalation_file" 2>/dev/null)" \
        || escalation_json=""
      if auditor_control_escalation_record_is_bound \
          "$escalation_json" "$scope" "$auditor" "$generation" "$escalation_file"; then
        exit 4
      fi
      auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
    fi
    wake_nonce="$(auditor_control_random_nonce)" || exit 1
    wake_nonce_hash="$(printf '%s' "$wake_nonce" | shasum -a 256 | awk '{print $1}')"
    jq -nc --arg auditor "$auditor" --arg generation "$generation" \
      --arg scope "$scope" --arg epoch "$epoch" --arg wake_nonce_hash "$wake_nonce_hash" \
      --argjson now "$(date +%s)" \
      '{auditor:$auditor,generation:$generation,session_scope:$scope,prompt_epoch:$epoch,
        state:"open",opened_at:$now,no_response:"keep-running",
        wake_nonce_hash:$wake_nonce_hash,
        override_directive:"force-pass-auditors: <reason>"}' \
      | auditor_control_write_json_atomic "$escalation_file" || exit 1
    auditor_control_append_event "$(jq -nc --arg event escalated --arg auditor "$auditor" \
      --arg generation "$generation" '{event:$event,auditor:$auditor,generation:$generation}')"
    jq -nc --arg wake_nonce "$wake_nonce" '{wake_nonce:$wake_nonce}'
    exit 0
    ;;
  --locked-consume-wake)
    scope="$2"; wake_nonce_hash="$3"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    now="$(date +%s)"
    for escalation_file in "$auditor_control_state_dir"/escalation."$scope".*.json; do
      [[ -e "$escalation_file" || -L "$escalation_file" ]] || continue
      escalation_json="$(verdict_audit_read_single_record "$escalation_file" 2>/dev/null)" \
        || {
          auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
          continue
        }
      auditor="$(printf '%s' "$escalation_json" | jq -r '.auditor // ""')"
      generation="$(printf '%s' "$escalation_json" | jq -r '.generation // ""')"
      if ! auditor_control_escalation_record_is_bound \
          "$escalation_json" "$scope" "$auditor" "$generation" "$escalation_file"; then
        auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
        continue
      fi
      escalation_state="$(printf '%s' "$escalation_json" | jq -r '.state // ""')"
      opened_at="$(printf '%s' "$escalation_json" | jq -r '.opened_at // ""')"
      [[ ( "$escalation_state" == open || "$escalation_state" == closed ) \
         && "$(printf '%s' "$escalation_json" | jq -r '.session_scope // ""')" == "$scope" \
         && "$(printf '%s' "$escalation_json" | jq -r '.wake_nonce_hash // ""')" == "$wake_nonce_hash" ]] \
        || continue
      [[ "$opened_at" =~ ^[1-9][0-9]*$ && ${#opened_at} -le 18 ]] || continue
      (( opened_at <= now && now <= opened_at + 300 )) || continue
      printf '%s' "$escalation_json" | jq -c --argjson now "$(date +%s)" \
        'del(.wake_nonce_hash) | .wake_consumed_at=$now' \
        | auditor_control_write_json_atomic "$escalation_file" || exit 1
      auditor_control_append_event "$(jq -nc --arg event wake-consumed --arg auditor "$auditor" \
        --arg generation "$generation" \
        '{event:$event,auditor:$auditor,generation:$generation}')"
      exit 0
    done
    exit 3
    ;;
  --locked-consume-completion)
    scope="$2"; generation="$3"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    for completion_file in "$auditor_control_state_dir"/completion."$scope".*."$generation".json; do
      [[ -e "$completion_file" || -L "$completion_file" ]] || continue
      completion_json="$(verdict_audit_read_single_record "$completion_file" 2>/dev/null)" \
        || {
          auditor_control_state_retire_cache_entry "$completion_file" || exit 1
          continue
        }
      created_at="$(printf '%s' "$completion_json" | jq -r '.created_at // ""')"
      remaining="$(printf '%s' "$completion_json" | jq -er \
        '(.remaining // 1) | select(type == "number" and . >= 1 and . <= 1024 and . == floor)' \
        2>/dev/null)" || continue
      auditor="$(printf '%s' "$completion_json" | jq -r '.auditor // ""')"
      now="$(date +%s)"
      if ! auditor_control_completion_record_is_bound "$completion_json" \
          "$scope" "$auditor" "$generation" "$completion_file"; then
        auditor_control_state_retire_cache_entry "$completion_file" || exit 1
        continue
      fi
      (( created_at <= now && now <= created_at + 300 )) || continue
      if (( remaining == 1 )); then
        auditor_control_state_retire_cache_entry "$completion_file" || exit 1
      else
        printf '%s' "$completion_json" | jq -c --argjson remaining "$((remaining - 1))" \
          '.remaining=$remaining' | auditor_control_write_json_atomic "$completion_file" || exit 1
      fi
      auditor_control_append_event "$(jq -nc --arg event completion-consumed --arg auditor "$auditor" \
        --arg generation "$generation" \
        '{event:$event,auditor:$auditor,generation:$generation}')"
      exit 0
    done
    exit 3
    ;;
  --locked-stop)
    scope="$2"; auditor="$3"; generation="$4"; terminal="$5"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    active_file="$auditor_control_state_dir/active.$scope.$auditor.json"
    escalation_file="$auditor_control_state_dir/escalation.$scope.$auditor.$generation.json"
    pending_file="$auditor_control_state_dir/pending-stop.$scope.$auditor.$generation.json"
    is_known_generation=false
    active_json=""; escalation_json=""; pending_json=""
    if [[ -e "$active_file" || -L "$active_file" ]]; then
      active_json="$(verdict_audit_read_single_record "$active_file" 2>/dev/null)" \
        || active_json=""
      if ! auditor_control_active_record_is_bound \
          "$active_json" "$scope" "$auditor" "$active_file"; then
        auditor_control_state_retire_cache_entry "$active_file" || exit 1
        active_json=""
      fi
    fi
    if [[ -e "$escalation_file" || -L "$escalation_file" ]]; then
      escalation_json="$(verdict_audit_read_single_record "$escalation_file" 2>/dev/null)" \
        || escalation_json=""
      if ! auditor_control_escalation_record_is_bound \
          "$escalation_json" "$scope" "$auditor" "$generation" "$escalation_file"; then
        auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
        escalation_json=""
      fi
    fi
    if [[ -n "$active_json" \
          && "$(printf '%s' "$active_json" | jq -r '.generation')" == "$generation" ]]; then
      is_known_generation=true
      auditor_control_state_retire_cache_entry "$active_file" || exit 1
    elif [[ -n "$escalation_json" ]]; then
      # An interactive override closes active state before the harness delivers the
      # auditor's later SubagentStop event. The bound escalation still authenticates
      # that terminal generation for its next host completion-delivery credit.
      is_known_generation=true
    elif pending_json="$(verdict_audit_read_single_record "$pending_file" 2>/dev/null)"; then
      now="$(date +%s)"
      # shellcheck disable=SC2154
      max_age="$((verdict_audit_lock_max_seconds + verdict_audit_deadline_slack_seconds))"
      if auditor_control_pending_stop_record_is_bound \
          "$pending_json" "$scope" "$auditor" "$generation" "$now" "$max_age" \
          "$pending_file"; then
      # A newer human prompt retires live authorization before this hook arrives.
      # Its pending receipt preserves only enough identity to authenticate the later
      # host completion envelope; it cannot itself suppress a prompt.
        is_known_generation=true
      else
        auditor_control_state_retire_cache_entry "$pending_file" || exit 1
      fi
    fi
    [[ "$is_known_generation" == true ]] || exit 0
    auditor_control_state_retire_cache_entry "$pending_file" || exit 1
    escalation_state="$(printf '%s' "$escalation_json" | jq -r '.state // ""')"
    if [[ -n "$escalation_json" && "$escalation_state" == open ]]; then
      printf '%s' "$escalation_json" | jq -c --arg terminal "$terminal" \
        --argjson now "$(date +%s)" \
        '.state="closed" | .terminal=$terminal | .closed_at=$now' \
        | auditor_control_write_json_atomic "$escalation_file" || exit 1
      auditor_control_append_event "$(jq -nc --arg event closed --arg auditor "$auditor" \
        --arg generation "$generation" --arg terminal "$terminal" \
        '{event:$event,auditor:$auditor,generation:$generation,terminal:$terminal}')"
    fi
    auditor_control_add_completion_receipt "$scope" "$auditor" "$generation" || exit 1
    exit 0
    ;;
  --locked-handle-prompt)
    scope="$2"; old_epoch="$3"; new_epoch="$4"; directive="$5"; reason_hash="$6"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    grant_file="$(auditor_override_grant_path "$repo" "$scope")"
    rm -f "$grant_file"
    if [[ "$directive" != override ]]; then
      auditor_control_close_scope_state new-prompt || exit 1
      exit 0
    fi
    if ! auditor_control_open_escalation_exists "$old_epoch"; then
      jq -nc '{continue:true,systemMessage:"[auditor-control] override ignored: the audit generation already completed or no 30-second escalation is open"}'
      exit 0
    fi
    auditor_control_write_override_grant "$scope" "$new_epoch" "$reason_hash" || exit 1
    auditor_control_close_scope_state overridden-by-user || { rm -f "$grant_file"; exit 1; }
    rm -f "$repo/.agents/state/last-audit.json" "$repo/.agents/state/last-audit-handoff.json" \
      "$repo/.claude/.last-audit.json" "$repo/.claude/.last-audit-handoff.json"
    auditor_control_append_event "$(jq -nc --arg event overridden --arg epoch "$new_epoch" \
      '{event:$event,prompt_epoch:$epoch,outcome:"OVERRIDDEN BY USER"}')"
    jq -nc '{continue:true,hookSpecificOutput:{hookEventName:"UserPromptSubmit",
      additionalContext:"OVERRIDDEN BY USER: all auditor gates are bypassed for this prompt only. Preserve installation, guidance, PR-review, chained-hook, and remote protections. Never describe an auditor as PASS."}}'
    exit 0
    ;;
  --locked-select)
    scope="$2"; auditor="$3"; generation="$4"; epoch="$5"; choice="$6"; reason_hash="$7"
    events_file="$auditor_control_state_dir/events.$scope.jsonl"
    active_file="$auditor_control_state_dir/active.$scope.$auditor.json"
    escalation_file="$auditor_control_state_dir/escalation.$scope.$auditor.$generation.json"
    active_json="$(verdict_audit_read_single_record "$active_file" 2>/dev/null)" \
      || active_json=""
    escalation_json="$(verdict_audit_read_single_record "$escalation_file" 2>/dev/null)" \
      || escalation_json=""
    if ! auditor_control_active_record_is_bound \
        "$active_json" "$scope" "$auditor" "$active_file"; then
      auditor_control_state_retire_cache_entry "$active_file" || exit 1
      active_json=""
    fi
    if ! auditor_control_escalation_record_is_bound \
        "$escalation_json" "$scope" "$auditor" "$generation" "$escalation_file"; then
      auditor_control_state_retire_cache_entry "$escalation_file" || exit 1
      escalation_json=""
    fi
    if [[ -z "$active_json" || -z "$escalation_json" \
          || "$(printf '%s' "$active_json" | jq -r '.generation')" != "$generation" \
          || "$(printf '%s' "$active_json" | jq -r '.prompt_epoch')" != "$epoch" \
          || "$(printf '%s' "$escalation_json" | jq -r '.state')" != open \
          || "$(printf '%s' "$escalation_json" | jq -r '.prompt_epoch')" != "$epoch" ]]; then
      jq -nc '{accepted:false,outcome:"ignored-terminal-race"}'
      exit 0
    fi
    case "$choice" in
      keep_waiting)
        printf '%s' "$escalation_json" | jq -c --argjson now "$(date +%s)" \
          '.state="closed" | .terminal="keep-waiting" | .closed_at=$now' \
          | auditor_control_write_json_atomic "$escalation_file" || exit 1
        auditor_control_append_event "$(jq -nc --arg event selected --arg auditor "$auditor" \
          --arg generation "$generation" --arg outcome keep-waiting \
          '{event:$event,auditor:$auditor,generation:$generation,outcome:$outcome}')"
        jq -nc '{accepted:true,outcome:"keep-waiting"}'
        ;;
      override_all)
        [[ "$reason_hash" =~ ^[0-9a-f]{64}$ ]] || exit 1
        auditor_control_write_override_grant "$scope" "$epoch" "$reason_hash" || exit 1
        auditor_control_close_scope_state overridden-by-user \
          || { rm -f "$(auditor_override_grant_path "$repo" "$scope")"; exit 1; }
        rm -f "$repo/.agents/state/last-audit.json" "$repo/.agents/state/last-audit-handoff.json" \
          "$repo/.claude/.last-audit.json" "$repo/.claude/.last-audit-handoff.json"
        auditor_control_append_event "$(jq -nc --arg event overridden --arg epoch "$epoch" \
          --arg auditor "$auditor" --arg generation "$generation" \
          '{event:$event,prompt_epoch:$epoch,auditor:$auditor,generation:$generation,
            outcome:"OVERRIDDEN BY USER"}')"
        jq -nc '{accepted:true,outcome:"OVERRIDDEN BY USER"}'
        ;;
    esac
    exit 0
    ;;
esac

if [[ "${1:-}" == consume-wake ]]; then
  scope="${2:-}"; wake_nonce_hash="${3:-}"
  [[ "$scope" =~ ^git-[0-9a-f]{40,64}$ && "$wake_nonce_hash" =~ ^[0-9a-f]{64}$ ]] \
    || exit 1
  auditor_control_state_dispatch consume-wake "$scope" "$wake_nonce_hash"
  exit $?
fi

if [[ "${1:-}" == consume-completion ]]; then
  scope="${2:-}"; generation="${3:-}"
  [[ "$scope" =~ ^git-[0-9a-f]{40,64}$ \
     && "$generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 1
  auditor_control_state_dispatch consume-completion "$scope" "$generation"
  exit $?
fi

raw_payload="$(cat)"
payload="$(printf '%s' "$raw_payload" | jq -ecs 'if length == 1 and (.[0]|type)=="object" then .[0] else empty end' 2>/dev/null)"
[[ -n "$payload" ]] || { printf 'auditor-control.sh: expected one JSON hook object.\n' >&2; exit 1; }
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')"
session_state="$(printf '%s' "$payload" | jq -r 'if (.session_id|type)=="string" and (.session_id|length)>0 then "valid" else "invalid" end')"
[[ "$session_state" == valid ]] || exit 0
session_id="$(printf '%s' "$payload" | jq -r '.session_id')"
scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 1

if [[ "${1:-}" == select ]]; then
  choice="$(printf '%s' "$payload" | jq -r '.choice // ""')"
  [[ "$choice" == keep_waiting || "$choice" == override_all ]] \
    || { printf 'auditor-control.sh: invalid interactive prompt choice.\n' >&2; exit 1; }
  auditor="$(printf '%s' "$payload" | jq -r '.auditor // ""')"
  auditor_control_canonical_auditor "$auditor" >/dev/null 2>&1 \
    || { printf 'auditor-control.sh: invalid interactive prompt auditor.\n' >&2; exit 1; }
  generation="$(printf '%s' "$payload" | jq -r '.generation // ""')"
  [[ -n "$generation" && "$(auditor_control_safe_generation "$generation")" == "$generation" ]] \
    || { printf 'auditor-control.sh: invalid interactive prompt generation.\n' >&2; exit 1; }
  epoch="$(auditor_control_prompt_epoch_for "$repo" "$scope" 2>/dev/null)" \
    || { printf 'auditor-control.sh: no current prompt epoch for interactive selection.\n' >&2; exit 1; }
  reason_hash=-
  if [[ "$choice" == override_all ]]; then
    reason="$(printf '%s' "$payload" | jq -r '.reason // ""')"
    [[ "$reason" =~ [^[:space:]] ]] \
      || { printf 'auditor-control.sh: interactive override requires a reason.\n' >&2; exit 1; }
    reason_hash="$(printf '%s' "$reason" | shasum -a 256 | awk '{print $1}')"
  fi
  auditor_control_state_dispatch select "$scope" \
    "$auditor" "$generation" "$epoch" "$choice" "$reason_hash"
  exit $?
fi

if [[ "$event" == UserPromptSubmit && "${1:-}" == handle-prompt ]]; then
  old_epoch="${2:-}"; new_epoch="${3:-}"
  first_line="$(printf '%s' "$payload" | jq -r '
    (.prompt // "") | gsub("\r";"") | split("\n") | map(select(test("[^[:space:]]"))) | .[0] // ""
  ')"
  directive=normal; reason_hash=-
  if [[ "$first_line" =~ ^force-pass-auditors:[[:space:]]+([^[:space:]].*)$ ]]; then
    directive=override
    reason_hash="$(printf '%s' "${BASH_REMATCH[1]}" | shasum -a 256 | awk '{print $1}')"
  fi
  auditor_control_state_dispatch handle-prompt "$scope" \
    "$old_epoch" "$new_epoch" "$directive" "$reason_hash"
  exit $?
fi

agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // ""')"
[[ -n "$agent_id" ]] || exit 0
auditor="$(auditor_control_auditor_from_payload "$payload" "$event")"; auditor_status=$?
if (( auditor_status != 0 )); then
  if (( auditor_status == 1 )); then
    [[ "$event" == SubagentStop ]] && printf '{}\n'
    exit 0
  fi
  printf 'auditor-control.sh: could not safely identify the subagent transcript.\n' >&2
  exit 2
fi
generation="$(auditor_control_safe_generation "$agent_id")"
epoch="$(auditor_control_prompt_epoch_for "$repo" "$scope" 2>/dev/null)" || exit 1

case "$event" in
  SubagentStart)
    auditor_control_state_dispatch start "$scope" "$auditor" "$generation" "$epoch" \
      || exit $?
    threshold="${AUDITOR_PROMPT_AFTER_SECONDS:-30}"
    [[ "$threshold" =~ ^[0-9]+$ && ${#threshold} -le 4 ]] || threshold=30
    perl -e 'select(undef,undef,undef,$ARGV[0])' "$threshold"
    if escalation_result="$(auditor_control_state_dispatch escalate \
        "$scope" "$auditor" "$generation" "$epoch")"; then
      wake_nonce="$(printf '%s' "$escalation_result" | jq -er \
        '.wake_nonce | select(type == "string" and test("^[0-9a-f]{64}$"))')" || exit 2
      if [[ "$(hook_host_kind)" == claude ]]; then
        control_script="$tooling_root/.agents/hooks/auditor-control.sh"
        keep_payload="$(jq -nc --arg session "$session_id" --arg auditor "$auditor" \
          --arg generation "$generation" \
          '{hook_event_name:"AskUserQuestion",session_id:$session,choice:"keep_waiting",
            auditor:$auditor,generation:$generation}')"
        override_payload="$(jq -nc --arg session "$session_id" --arg auditor "$auditor" \
          --arg generation "$generation" \
          '{hook_event_name:"AskUserQuestion",session_id:$session,choice:"override_all",
            reason:"auditor is taking too long",auditor:$auditor,generation:$generation}')"
        keep_payload_b64="$(printf '%s' "$keep_payload" \
          | perl -MMIME::Base64 -0777 -ne 'print encode_base64($_,"")')"
        override_payload_b64="$(printf '%s' "$override_payload" \
          | perl -MMIME::Base64 -0777 -ne 'print encode_base64($_,"")')"
        printf -v project_q '%q' "$repo"
        printf -v control_q '%q' "$control_script"
        keep_command="/usr/bin/printf '%s' '$keep_payload_b64' | /usr/bin/perl -MMIME::Base64 -0777 -ne 'print decode_base64(\$_)' | CLAUDE_PROJECT_DIR=$project_q /usr/bin/env bash $control_q select"
        override_command="/usr/bin/printf '%s' '$override_payload_b64' | /usr/bin/perl -MMIME::Base64 -0777 -ne 'print decode_base64(\$_)' | CLAUDE_PROJECT_DIR=$project_q /usr/bin/env bash $control_q select"
        prompt_spec="$(jq -nc --arg auditor "$auditor" \
          --arg keep_command "$keep_command" --arg override_command "$override_command" '
          {question:($auditor + " is still running. What should I do?"),header:"Auditor",
           options:[
             {label:"Keep waiting (Recommended)",
              description:"Leave every auditor running and dismiss this one-shot escalation.",
              command:$keep_command},
             {label:"Force pass — auditor is taking too long",
              commandLabel:"Force pass",
              description:"Override commit-push-auditor and verdict-auditor for this prompt only; record OVERRIDDEN BY USER, never PASS.",
              command:$override_command}],multiSelect:false}')" || exit 2
        printf '[auditor-control] %s is still running after 30 seconds. [auditor-wake:%s]\n' \
          "$auditor" "$wake_nonce" >&2
        hook_interactive_prompt_render_claude "$prompt_spec" >&2 || exit 2
        printf 'If Other is selected, re-open the same card; do not infer a choice. A terminal audit may leave this card stale; still run the selected command, which safely rejects terminal or superseded generations.\n' >&2
        exit 2
      fi
      message="[auditor-control] $auditor is still running after 30 seconds. Publish one short, non-blocking assistant status: \"Auditor is still running. Reply with force-pass-auditors: <reason> to override both auditor gates for this prompt, or do nothing to keep waiting.\" Keep the auditor running. If its completion is already visible, suppress this stale status."
      jq -nc --arg message "$message" '{continue:true,systemMessage:$message}'
    fi
    ;;
  SubagentStop)
    message="$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""')"
    case "$message" in
      PASS*) terminal=PASS ;;
      FAIL*) terminal=FAIL ;;
      IN_PROGRESS*) terminal=IN_PROGRESS ;;
      *) terminal=unavailable ;;
    esac
    auditor_control_state_dispatch stop "$scope" "$auditor" "$generation" "$terminal" \
      || exit $?
    printf '{}\n'
    ;;
esac
