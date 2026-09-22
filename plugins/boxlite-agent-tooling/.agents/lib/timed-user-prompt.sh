#!/usr/bin/env bash
# Source-only facade. Requires jq, perl, date, and verdict-audit-state.sh.
# JSON on stdout; errors on stderr. No waiting or host UI inside the state lock.

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
      and (keys == ["created_at","deadline","fallback_delivered","id","response","spec","status","version"])
      and (.id | type == "string" and test("^[0-9a-f]{32}$"))
      and (.created_at | type == "number" and . >= 0 and floor == .)
      and .deadline == .created_at + 180
      and (.status | IN("pending","accepted","expired","consumed"))
      and (.fallback_delivered | type == "boolean");
    def record_ok:
      valid
      and (if .status == "accepted" or .status == "consumed"
        then .spec as $s | .response | response_ok($s) else .response == "" end)
      and (if .fallback_delivered then .status == "expired" else true end);
    if . != null and (record_ok | not) then error("invalid confirmation state") else . end |
    if . != null and $now < .created_at then error("clock moved backwards") else . end |
    if . != null and .status == "pending" and $now >= .deadline
      then .status = "expired" else . end |
    if $op == "request" then
      ($arg | fromjson) as $spec |
      if ($spec | spec | not) then error("invalid confirmation specification")
      elif . == null or .spec != $spec or .status == "consumed" then
        {version:1,id:$id,spec:$spec,created_at:$now,deadline:($now+180),
         status:"pending",response:"",fallback_delivered:false}
      else . end
    elif . == null or .id != $arg then error("unknown or superseded confirmation")
    elif $op == "respond" then
      if .status != "pending" then error("confirmation no longer accepts replies")
      else . end |
      .spec as $s |
      if ($reply | response_ok($s) | not)
      then error("type the required prefix and a concrete response")
      else .status = "accepted" | .response = $reply end
    elif $op == "consume" then
      if .status != "accepted" then error("confirmation is not accepted")
      else .status = "consumed" end
    elif $op == "fallback" then
      if .status != "expired" then error("confirmation has not expired")
      else .fallback_delivered = true end
    elif $op == "status" then .
    else error("unknown confirmation operation") end
  ' <<<"$record")" || return 2
  printf '%s\n' "$next" | verdict_audit_write_atomic "$path" || return 2
  printf '%s\n' "$next"
}

timed_user_prompt_instruction() { # tooling-root request-json
  local deadline fallback instruction
  deadline="$(jq -er .deadline <<<"$2")" || return 2
  fallback="$(jq -er .spec.fallback <<<"$2")" || return 2
  instruction="$(subagent_prompt timed-user-prompt "$1" "deadline=$deadline" "fallback=$fallback")" || return 2
  [[ "$instruction" == *[![:space:]]* ]] || return 2
  printf '%s\n' "$instruction"
}
