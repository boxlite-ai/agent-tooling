#!/usr/bin/env bash
# Names the subagent a hook fires in. Claude Code reports plugin agents in agent_type;
# Codex reports spawned agents as `default` and names them only in the first record of
# the subagent's own transcript. Requires jq and perl. Source only.

subagent_identity_first_record() {  # transcript path -> its first JSONL record, bounded
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

# Prints the Codex orchestration path of a spawned subagent, only when the transcript's
# spawn metadata binds this payload's agent and session; otherwise fails (status 2).
subagent_identity_codex_path() {  # hook payload, transcript path
  local session_meta
  session_meta="$(subagent_identity_first_record "$2" 2>/dev/null)" || return 2
  printf '%s' "$session_meta" | jq -er \
    --arg session "$(printf '%s' "$1" | jq -r '.session_id')" \
    --arg agent "$(printf '%s' "$1" | jq -r '.agent_id // ""')" '
      if .type == "session_meta"
         and .payload.id == $agent
         and .payload.session_id == $session
         and .payload.thread_source == "subagent"
         and .payload.source.subagent.thread_spawn.parent_thread_id == $session
         and (.payload.source.subagent.thread_spawn.agent_path | type) == "string"
      then .payload.source.subagent.thread_spawn.agent_path
      else empty end
    ' 2>/dev/null || return 2
}

# Prints the auditor a host-reported name means: a Claude Code agent_type (claude) or the
# last segment of a Codex agent path (codex, which may add a `_<suffix>`). Status 1 when
# the name is no auditor of this plugin; other plugins' agents of the same name are not.
# The design advisor counts too, so its deadline and probe hooks reach it (design #335).
subagent_identity_auditor_name() {  # claude|codex, name
  local auditor snake
  for auditor in design-auditor design-advisor commit-push-auditor verdict-auditor; do
    snake="${auditor//-/_}"
    case "$1:$2" in
      "claude:$auditor" | "claude:$snake" | "claude:boxlite-agent-tooling:$auditor" \
      | "codex:$auditor" | "codex:$auditor"_* | "codex:$snake" | "codex:$snake"_*)
        printf '%s' "$auditor"
        return 0 ;;
    esac
  done
  return 1
}

# Prints the auditor a hook fires in: design-auditor, design-advisor, commit-push-auditor or
# verdict-auditor. Status 1: not an auditor; 2: a Codex transcript that cannot be bound.
subagent_identity_auditor() {  # hook payload
  local agent transcript path
  agent="$(printf '%s' "$1" | jq -r '.agent_type // "" | strings' 2>/dev/null)" || return 1
  if [[ "$agent" != default ]]; then
    subagent_identity_auditor_name claude "$agent"
    return
  fi
  transcript="$(printf '%s' "$1" | jq -r '
    if (.agent_transcript_path | type) == "string" then .agent_transcript_path
    elif (.transcript_path | type) == "string" then .transcript_path else "" end')"
  [[ -n "$transcript" ]] || return 1
  path="$(subagent_identity_codex_path "$1" "$transcript")" || return 2
  subagent_identity_auditor_name codex "${path##*/}"
}
