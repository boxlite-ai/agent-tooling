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

_timed_user_prompt_transition() { # same arguments as the facade; lock already held
  local operation="$1" path="$2" argument="$3" response="${4:-}" record=null snapshot now nonce next archive library
  library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
  now="$(date -u +%s)" || return 2
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 2
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || return 2
    record="${snapshot#*$'\n'}"
  fi
  nonce="$(perl -e 'open my $f, "<", "/dev/urandom" or exit 2;
    read($f, my $bytes, 16) == 16 or exit 2; print unpack("H*", $bytes)')" || return 2
  next="$(jq -ce -L "$library" --arg op "$operation" --arg arg "$argument" --arg reply "$response" \
    --arg id "$nonce" --argjson now "$now" '
    include "user-question-policy";
    def line: type == "string" and utf8bytelength <= 4096
      and (explode | all(. >= 32 and . != 127));
    def spec:
      type == "object" and (keys == ["binding","fallback","minimum_words","prefix"])
      and (.binding | type == "object" and length > 0 and (tojson | utf8bytelength <= 8192))
      and (.prefix | type == "string")
      and (user_question_policy(.prefix) as $policy | $policy != null and .fallback == $policy.fallback)
      and (.minimum_words | type == "number" and . >= 1 and . <= 100 and floor == .);
    def git_decision: user_question_policy(.prefix).fallback == "reflect-again";
    def response_ok($s):
      line and (. as $answer | user_question_policy($s.prefix) as $policy |
        if $s.prefix == "pr-size-exception:" and . == $policy.choices[0] then true
        elif $s.prefix == "design-decision:" then
          ($policy.choices | index($answer) != null) or test(user_question_design_pattern)
        elif ($s | git_decision) then (($policy.choices + user_question_labels($policy)) | index($answer) != null)
          or test(user_question_git_pattern($s.prefix; "[0-9a-f]{32}"))
        else startswith($s.prefix + " ")
          and ([.[($s.prefix|length):] | scan("\\S+")] | length) >= $s.minimum_words end);
    def valid:
      type == "object" and .version == 1 and (.spec | spec)
      and (keys == ["created_at","deadline","fallback_delivered","id","question_tool_id","response","spec","status","version"])
      and (.id | type == "string" and test("^[0-9a-f]{32}$"))
      and (.created_at | type == "number" and . >= 0 and floor == .)
      # Keep legacy deadlines valid without extending existing attempts.
      and (.deadline == .created_at + 180 or .deadline == .created_at + 300)
      and (.status | IN("pending","accepted","expired","consumed","declined"))
      and (.question_tool_id | type == "string" and test("^[A-Za-z0-9_-]{0,200}$"))
      and (.fallback_delivered | type == "boolean");
    def record_ok:
      valid
      and (if .status == "accepted" or .status == "consumed"
        then .spec as $s | .response | response_ok($s)
        elif .status == "declined" then .spec.prefix == "pr-size-exception:"
          and .response == user_question_policy(.spec.prefix).choices[1]
        else .response == "" end)
      and (. as $record | if (.spec | git_decision) and (.response | startswith($record.spec.prefix))
        then .response | test(user_question_git_pattern($record.spec.prefix; $record.id))
        else true end)
      and (if .fallback_delivered then (.status | IN("expired","declined")) else true end);
    # Older version-one records predate native questions; preserve their deadline.
    if type == "object" and .version == 1 and (has("question_tool_id") | not)
      then .question_tool_id = "" else . end |
    if . != null and (record_ok | not) then error("invalid confirmation state") else . end |
    if . != null and $now < .created_at then error("clock moved backwards") else . end |
    if . != null and .status == "pending" and $now >= .deadline
      then .status = "expired" else . end |
    if $op == "request" then
      ($arg | fromjson) as $spec |
      if ($spec | spec | not) then error("invalid confirmation specification")
      elif . == null or .spec != $spec or .status == "consumed" then
        {version:1,id:$id,spec:$spec,created_at:$now,deadline:($now+300),
         status:"pending",response:"",fallback_delivered:false,question_tool_id:""}
      else . end
    elif . == null or .id != $arg then error("unknown or superseded confirmation")
    elif $op == "renew" then
      if (.status | IN("expired","declined") | not) or .spec.prefix != "pr-size-exception:"
        or ($reply | line and test("\\S") | not)
      then error("renewal requires an expired or declined PR-size request and the explicit human instruction")
      else .id = $id | .created_at = $now | .deadline = ($now+300)
        | .status = "pending" | .response = "" | .fallback_delivered = false
        | .question_tool_id = "" end
    elif $op == "present" then
      if .status != "pending" or ($reply | test("^[A-Za-z0-9_-]{1,200}$") | not)
        or (.question_tool_id != "" and .question_tool_id != $reply)
      then error("question expired or was already presented")
      else .question_tool_id = $reply end
    elif $op == "respond" and (.spec.prefix == "design-decision:" or (.spec | git_decision)) then
      error("audit decisions come only from the human: the managed question or a typed decision line")
    elif $op == "prompt-reply" and (.spec | git_decision) then
      .spec as $spec |
      if .status != "pending" or ($reply | line | not)
        or ($reply | test(user_question_git_pattern($spec.prefix; $arg)) | not)
      then error("Git audit choice is stale or does not match this request")
      else .status = "accepted" | .response = $reply end
    elif $op == "prompt-reply" then
      # The human supplied a directive; the deadline only ends the agent wait.
      if .spec.prefix != "design-decision:" or ($reply | line and test(user_question_design_pattern) | not)
      then error("only an explicit design-decision line from the human prompt counts")
      elif (.status | IN("pending","expired") | not) then error("confirmation no longer accepts replies")
      else .status = "accepted" | .response = $reply | .fallback_delivered = false end
    elif $op == "respond" or $op == "native-reply" then
      if .status != "pending" then error("confirmation no longer accepts replies")
      else . end |
      (if $op == "native-reply" then
        ($reply | fromjson) as $native |
        if .question_tool_id == "" or $native.tool_use_id != .question_tool_id
          or ($native | keys) != ["answer","tool_use_id"]
        then error("response does not match the presented question") else $native.answer end
       elif .question_tool_id != "" then error("native replies must come through the question hook")
       else $reply end) as $answer |
      .spec as $s |
      if $s.prefix == "pr-size-exception:" and $answer == user_question_policy($s.prefix).choices[1]
      then .status = "declined" | .response = $answer
      elif ($answer | response_ok($s) | not)
      then error("response does not match this confirmation")
      else .status = "accepted" | .response = $answer end
    elif $op == "consume" then
      if (.spec | git_decision) then error("Git retry choices remain bound to their failed round")
      elif .status != "accepted" then error("confirmation is not accepted")
      else .status = "consumed" end
    elif $op == "fallback" then
      if (.status | IN("expired","declined") | not) then error("confirmation has not expired or been declined")
      else .fallback_delivered = true end
    elif $op == "status" or $op == "question" then .
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
  if [[ "$operation" == question ]]; then _timed_user_prompt_question "$next"
  else printf '%s\n' "$next"; fi
}

_timed_user_prompt_question() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 2
  # shellcheck source=user-question.sh
  source "$root/.agents/lib/user-question.sh" || return 2
  user_question card "$root" "$1"
}

timed_user_prompt_native_available() {
  [[ "${BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS:-}" == 1 \
    && "${CLAUDE_AFK_TIMEOUT_MS:-}" =~ ^[1-9][0-9]{0,5}$ ]] \
    && (( CLAUDE_AFK_TIMEOUT_MS <= 300000 ))
}

timed_user_prompt_instruction() { # tooling-root request-json
  # shellcheck source=user-question.sh
  source "$1/.agents/lib/user-question.sh" || return 2
  user_question instruction "$1" "$2"
}
