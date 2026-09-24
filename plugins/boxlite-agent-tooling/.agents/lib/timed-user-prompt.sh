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
  local operation="$1" path="$2" argument="$3" response="${4:-}" record=null snapshot now nonce next
  now="$(date -u +%s)" || return 2
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 2
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot="$(verdict_audit_read_regular_state "$path" 16384 json)" || return 2
    record="${snapshot#*$'\n'}"
  fi
  nonce="$(perl -e 'open my $f, "<", "/dev/urandom" or exit 2;
    read($f, my $bytes, 16) == 16 or exit 2; print unpack("H*", $bytes)')" || return 2
  next="$(jq -ce --arg op "$operation" --arg arg "$argument" --arg reply "$response" \
    --arg id "$nonce" --argjson now "$now" '
    def line: type == "string" and utf8bytelength <= 4096
      and (explode | all(. >= 32 and . != 127));
    def spec:
      type == "object" and (keys == ["binding","fallback","minimum_words","prefix"])
      and (.binding | type == "object" and length > 0 and (tojson | utf8bytelength <= 8192))
      and (.fallback | IN("split","keep-draft"))
      and (.prefix | IN("reviewed:","pr-size-exception:"))
      and ((.prefix == "reviewed:") == (.fallback == "keep-draft"))
      and (.minimum_words | type == "number" and . >= 1 and . <= 100 and floor == .);
    def response_ok($s):
      line and startswith($s.prefix + " ")
      and ([.[($s.prefix|length):] | scan("\\S+")] | length) >= $s.minimum_words;
    def valid:
      type == "object" and .version == 1 and (.spec | spec)
      and (keys == ["created_at","deadline","fallback_delivered","id","question_tool_id","response","spec","status","version"])
      and (.id | type == "string" and test("^[0-9a-f]{32}$"))
      and (.created_at | type == "number" and . >= 0 and floor == .)
      and .deadline == .created_at + 180
      and (.status | IN("pending","accepted","expired","consumed"))
      and (.question_tool_id | type == "string" and test("^[A-Za-z0-9_-]{0,200}$"))
      and (.fallback_delivered | type == "boolean");
    def record_ok:
      valid
      and (if .status == "accepted" or .status == "consumed"
        then .spec as $s | .response | response_ok($s) else .response == "" end)
      and (if .fallback_delivered then .status == "expired" else true end);
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
        {version:1,id:$id,spec:$spec,created_at:$now,deadline:($now+180),
         status:"pending",response:"",fallback_delivered:false,question_tool_id:""}
      else . end
    elif . == null or .id != $arg then error("unknown or superseded confirmation")
    elif $op == "present" then
      if .status != "pending" or ($reply | test("^[A-Za-z0-9_-]{1,200}$") | not)
        or (.question_tool_id != "" and .question_tool_id != $reply)
      then error("question expired or was already presented")
      else .question_tool_id = $reply end
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
      if ($answer | response_ok($s) | not)
      then error("type the required prefix and a concrete response")
      else .status = "accepted" | .response = $answer end
    elif $op == "consume" then
      if .status != "accepted" then error("confirmation is not accepted")
      else .status = "consumed" end
    elif $op == "fallback" then
      if .status != "expired" then error("confirmation has not expired")
      else .fallback_delivered = true end
    elif $op == "status" or $op == "question" then .
    else error("unknown confirmation operation") end
  ' <<<"$record")" || return 2
  printf '%s\n' "$next" | verdict_audit_write_atomic "$path" || return 2
  if [[ "$operation" == question ]]; then _timed_user_prompt_question "$next"
  else printf '%s\n' "$next"; fi
}

_timed_user_prompt_question() {
  jq -ce '(.spec.fallback == "split") as $split |
    {questions:[{question:(.spec.prefix + (if $split then " <why one PR is necessary> [" else " <what changed> [" end) + .id + "]"),
      header:(if $split then "PR size" else "Review" end),multiSelect:false,
      options:[{label:(if $split then "Split work" else "Keep draft" end),description:"Do not approve."},
               {label:"Show diff",description:"Inspect changes."}]}]}' <<<"$1"
}

timed_user_prompt_native_available() {
  [[ "${BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS:-}" == 1 \
    && "${CLAUDE_AFK_TIMEOUT_MS:-}" =~ ^[1-9][0-9]{0,5}$ ]] \
    && (( CLAUDE_AFK_TIMEOUT_MS <= 180000 ))
}

timed_user_prompt_instruction() { # tooling-root request-json
  local deadline fallback instruction route host
  # shellcheck source=hook-host.sh
  source "$1/.agents/lib/hook-host.sh" || return 2
  host="$(hook_host_kind)"
  route='Ask once through non-blocking input (Codex: request_user_input_async); avoid blocking modals.'
  if [[ "$host" == claude ]]; then
    if [[ "$(jq -r '.question_tool_id // ""' <<<"$2")" != "" ]]; then
      route='The native question was already shown. Do not reopen it or extend its deadline. Follow any explicit user instruction; never infer approval.'
    elif timed_user_prompt_native_available; then
      route="Call AskUserQuestion once: $(_timed_user_prompt_question "$2"). The hook records typed replies."
    else
      route='Ask once in plain text and continue waiting without a modal. Native timed questions require a local session from scripts/claude-with-timed-prompts.sh; Remote Control or custom settings use this fallback.'
    fi
  fi
  deadline="$(jq -er .deadline <<<"$2")" || return 2
  fallback="$(jq -er .spec.fallback <<<"$2")" || return 2
  instruction="$(subagent_prompt timed-user-prompt "$1" "deadline=$deadline" "fallback=$fallback" "route=$route")" || return 2
  [[ "$instruction" == *[![:space:]]* ]] || return 2
  printf '%s\n' "$instruction"
}
