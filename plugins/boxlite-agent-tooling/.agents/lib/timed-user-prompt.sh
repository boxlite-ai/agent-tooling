#!/usr/bin/env bash
# Source-only facade. Requires jq, perl, date, and verdict-audit-state.sh.
# JSON on stdout; errors on stderr. No waiting or host UI inside the state lock.
# shellcheck source-path=SCRIPTDIR

timed_user_prompt() { # operation state-path spec-or-request-id [verbatim-response]
  local directory library
  directory="$(dirname "$2")"
  [[ -d "$directory" && ! -L "$directory" ]] || return 2
  library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
  # Serialize the read/transition/write, including competing expiry and response.
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($library, $path, @args) = @ARGV;
    my $child = 0;
    $SIG{ALRM} = sub { if ($child) { kill "KILL", -$child; kill "KILL", $child; waitpid($child, 0) } exit 2 };
    alarm 5;
    my $lock = "$path.mutex";
    exit 2 if lstat($lock) && -l _;
    sysopen(my $fh, $lock, O_CREAT|O_RDWR|O_NONBLOCK|O_NOFOLLOW, 0600) or exit 2;
    my @opened = stat($fh); my @named = lstat($lock);
    exit 2 unless -f $fh && $opened[3] == 1 && @named
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX) or exit 2;
    @named = lstat($lock);
    exit 2 unless @named && $opened[0] == $named[0] && $opened[1] == $named[1];
    $child = fork(); exit 2 unless defined $child;
    if (!$child) {
      setpgrp(0, 0) or exit 2;
      exec "/bin/bash", "-c", q{
        source "$1/verdict-audit-state.sh" && source "$1/timed-user-prompt.sh" || exit 2
        shift
        _timed_user_prompt_transition "$@"
      }, "timed-user-prompt", $library, @args;
      exit 2;
    }
    waitpid($child, 0) == $child or exit 2;
    my $status = $?; alarm 0;
    exit($status & 127 ? 2 : $status >> 8);
  ' "$library" "$2" "$@"
}

timed_user_prompt_read() { # path -> current-format JSON, without changing state
  local snapshot
  snapshot="$(verdict_audit_read_regular_state "$1" 16384 json)" || {
    printf 'timed-user-prompt: cannot read request at %s\n' "$1" >&2
    return 2
  }
  jq -ce 'select(type == "object" and .version == 2)' <<<"${snapshot#*$'\n'}" || {
    printf 'timed-user-prompt: unsupported request at %s; resolve it before continuing\n' "$1" >&2
    return 2
  }
}

_timed_user_prompt_transition() { # same arguments as the facade; lock already held
  local operation="$1" path="$2" argument="$3" response="${4:-}" record=null now nonce next archive library
  library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
  now="$(date -u +%s)" || return 2
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 2
  if [[ -e "$path" || -L "$path" ]]; then
    record="$(timed_user_prompt_read "$path")" || return 2
  fi
  nonce="$(perl -e 'open my $f, "<", "/dev/urandom" or exit 2;
    read($f, my $bytes, 16) == 16 or exit 2; print unpack("H*", $bytes)')" || return 2
  next="$(jq -ce -L "$library" --arg op "$operation" --arg arg "$argument" --arg reply "$response" \
    --arg id "$nonce" --argjson now "$now" '
    include "user-question-policy";
    def line: type == "string" and utf8bytelength <= 4096
      and (explode | all(. >= 32 and . != 127));
    def spec:
      type == "object" and (keys == ["binding","fallback","prefix"])
      and (.binding | type == "object" and length > 0 and (tojson | utf8bytelength <= 8192))
      and (.prefix | type == "string")
      and (user_question_policy(.prefix) as $policy | $policy != null and .fallback == $policy.fallback);
    def git_decision: .fallback == "reflect-again";
    def review: .spec.prefix == "reviewed:";
    def integer: type == "number" and . >= 0 and floor == .;
    def checked_reply($request):
      select(line) | select($request.spec.prefix != "reviewed:" or utf8bytelength <= 1024) |
      user_question_directive |
      select(.id == $request.id and .prefix == $request.spec.prefix) |
      select(.prefix as $prefix | .answer | user_question_answer_valid($prefix));
    def split_choice:
      .prefix == "pr-size-exception:" and .answer == user_question_policy(.prefix).choices[1];
    def valid:
      type == "object" and .version == 2 and (.spec | spec)
      and (keys == ["accepted_at","created_at","deadline","fallback_delivered","id","response","spec","status","version"])
      and (.id | type == "string" and test("^[0-9a-f]{32}$"))
      and (.created_at | integer) and .deadline == .created_at + 300
      and (.status | IN("pending","accepted","expired","consumed","declined"))
      and (.fallback_delivered | type == "boolean");
    def record_ok:
      valid and (. as $request |
        if .status | IN("accepted","consumed") then
          (.accepted_at | integer) and .accepted_at >= .created_at
          and (.spec.prefix == "design-decision:" or .accepted_at < .deadline)
          and ((.response | checked_reply($request) | split_choice | not) // false)
        elif .status == "declined" then
          .accepted_at == null and ((.response | checked_reply($request) | split_choice) // false)
        else .accepted_at == null and .response == "" end)
      and (if .fallback_delivered then (.status | IN("expired","declined")) else true end);
    if . != null and (record_ok | not) then error("invalid confirmation state") else . end |
    if . != null and ($now < .created_at or (.accepted_at != null and $now < .accepted_at))
      then error("clock moved backwards") else . end |
    if . != null and ((.status == "pending" and $now >= .deadline)
        or (review and .status == "accepted" and $now - .accepted_at > 600))
      then .status = "expired" | .accepted_at = null | .response = "" else . end |
    if $op == "request" then
      ($arg | fromjson) as $spec |
      if ($spec | spec | not) then error("invalid confirmation specification")
      elif . == null or .spec != $spec or .status == "consumed" then
        {version:2,id:$id,spec:$spec,created_at:$now,deadline:($now+300),
         accepted_at:null,status:"pending",response:"",fallback_delivered:false}
      else . end
    elif . == null or .id != $arg then error("unknown or superseded confirmation")
    elif $op == "renew" then
      if (.status | IN("expired","declined") | not) or .spec.prefix != "pr-size-exception:"
        or ($reply | line and test("\\S") | not)
      then error("renewal requires an expired or declined PR-size request and the explicit human instruction")
      else .id = $id | .created_at = $now | .deadline = ($now+300)
        | .status = "pending" | .response = "" | .fallback_delivered = false end
    elif $op == "prompt-reply" then
      . as $request |
      if .status != "pending" and (.spec.prefix != "design-decision:" or .status != "expired")
      then error("confirmation is no longer pending")
      else ($reply | checked_reply($request) // null) as $answer |
        if $answer == null then error("response does not match this confirmation")
        elif ($answer | split_choice) then .status = "declined" | .response = $reply
        else .status = "accepted" | .response = $reply | .accepted_at = $now | .fallback_delivered = false end
      end
    elif $op == "consume" then
      if (.spec | git_decision) then error("Git retry choices remain bound to their failed round")
      elif .status != "accepted" then error("confirmation is not accepted or has expired")
      else .status = "consumed" end
    elif $op == "fallback" then
      if (.status | IN("expired","declined") | not) then error("confirmation has not expired or been declined")
      else .fallback_delivered = true end
    elif $op == "status" then .
    else error("unknown confirmation operation") end
  ' <<<"$record")" || return 2
  if [[ "$operation" == renew ]]; then
    # Preserve the old attempt before publishing its successor, under the same lock.
    archive="$path.expired-$argument.json"
    jq -nc --argjson request "$record" --arg user_request "$response" \
      --arg successor_id "$nonce" --argjson renewed_at "$now" \
      '{request:($request | if .status == "pending" then .status="expired" else . end),user_request:$user_request,
        successor_id:$successor_id,renewed_at:$renewed_at}' \
      | verdict_audit_write_exclusive_regular "$archive" || {
        printf 'timed-user-prompt: cannot archive prior request: %s; renewal not published; inspect any existing archive before retrying\n' "$archive" >&2
        return 2
      }
  fi
  printf '%s\n' "$next" | verdict_audit_write_atomic "$path" || return 2
  printf '%s\n' "$next"
}
