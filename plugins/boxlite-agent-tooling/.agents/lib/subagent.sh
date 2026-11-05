#!/usr/bin/env bash
# Shared: tell the coding agent that is running to spawn an independent subagent with
# its OWN built-in, instead of shelling out to a vendor CLI.
#
# Source it, don't run it:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/subagent.sh"
#
# Why this emits TEXT rather than invoking anything
# -------------------------------------------------
# A hook is a bash process. It cannot call Task(...) or collaboration.spawn_agent(...)
# — only the agent can. So the hook's whole job here is to NAME the routes and let the
# agent take the one it actually has. Both hosts ship a built-in for this:
#
#   Claude Code   Task(subagent_type=<plugin>:<agent>, ...)  scoped plugin name
#   Codex         collaboration.spawn_agent(task_name, message)   no spec parameter
#
# Shelling out to `claude -p` or `codex exec` from inside a live agent spawns a whole
# second process to do what the built-in does in-session, and it needs a second auth
# and a second sandbox decision. That path still exists for genuinely agent-less
# callers (git hooks, CI) — pass it as --headless — but it is the exception now, not
# the Codex route.
#
# Which routes get printed
# ------------------------
# One route when hook_host_kind names the host, every route when it answers `unknown`.
# An agent handed a route it cannot take reads it anyway, and the Codex block in
# particular carries a spec path and a task name that mean nothing under Claude Code.
#
# Unknown stays fail-open — a git hook, CI, or a host this library has not been taught
# about gets the whole menu. A wrong single route is worse than a menu, so ambiguity
# degrades to the menu rather than to a guess.
#
# Which signals may decide that, and which are traps, is hook-host.sh's subject; this
# library must reach it only through hook_host_kind (subagent.test.sh enforces that).
#
# Spec delivery differs by host, so it is referenced rather than inlined
# ---------------------------------------------------------------------
# Claude Code registers plugin agents as <plugin>:<frontmatter-name>. Codex takes no
# spec parameter, so `message` cites the canonical spec and carries the task. Codex
# starts with `fork_turns="none"`: audit inputs must be explicit, and unrelated parent
# history must not consume context or influence an independent review.
#
# A missing spec file is a packaging bug, not a runtime branch: this still emits the
# instruction, and subagent.test.sh asserts every referenced spec exists.

# hook_host_kind is the only sanctioned way to name the caller's host. Loading it here
# rather than in each caller keeps that single accessor next to the one decision it
# feeds; a fixture that stages subagent.sh must stage hook-host.sh beside it.
#
# Sourced UNCONDITIONALLY, never behind a `declare -F` check. Bash carries exported
# functions through the environment (BASH_FUNC_*), so a definition of this name can
# arrive from any ancestor process — and skipping the load when one exists would hand
# route selection to precisely the inherited state this accessor exists to ignore.
# The library defines functions and nothing else, so reloading it costs nothing.
#
# Loading stays INERT: no variable left in the caller's scope, no output, and no return
# or exit while sourcing. A library that can abort its own load takes the decision away
# from callers that source several and report their own failures.
#
# The absence is caught where it can be reported instead — `source` on a missing file
# only warns, and every caller runs under `set -uo pipefail` rather than `-e`, so
# without a check the gate would continue with no accessor, take the unknown-host
# branch, and print the full menu: a packaging bug rendered as a plausible instruction.
#
# The names are cleared FIRST, so a load that fails leaves nothing behind. Bash carries
# exported functions in the environment, so without this an absent hook-host.sh would
# leave whatever an ancestor exported in place and the guard below would accept it —
# routing on exactly the inherited state this accessor exists to refuse, which is worse
# than the missing file it was meant to catch.
unset -f hook_host_kind hook_host_is_env_root hook_host_is_env_value 2>/dev/null || true
# shellcheck source=./hook-host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-host.sh" 2>/dev/null || true

# Strip a spec's YAML frontmatter. The frontmatter is registration metadata — name,
# description, the tool allowlist, the model the Task path launches with. None of it
# is instruction, so none of it may reach a model as part of the procedure.
subagent_strip_frontmatter() {  # $1 = spec file
  awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{fm=2; next} fm!=1' "$1"
}

# Where a named subagent's canonical spec lives. One location for both hosts: the
# .claude/ path is the storage location, not a statement about which agent may use it.
subagent_spec_path() {  # $1 = agent name, $2 = tooling root
  printf '%s/.claude/agents/%s.md\n' "$2" "$1"
}

subagent_json_string() {  # arbitrary text -> one JSON string literal
  jq -Rn --arg value "$1" '$value'
}

# Load .agents/prompts/<group>/<name>.md and fill in its {{placeholders}}.
#
#   subagent_prompt audit/verdict-runner "$root" task_input_json="$input"
#
# Prompts live as Markdown rather than as shell string literals because that is what
# they are: documents someone edits, reviews in a diff, and reasons about without
# reading bash quoting around them. A prompt buried in a heredoc also silently inherits
# shell expansion rules — `$(...)` inside one is a command substitution, not text.
#
# Substitution is plain bash string replacement over an explicit key list. No eval and
# no envsubst: the values are branch names, file paths, and commit text, and a prompt
# is the last place to let an unreviewed `$(...)` become executable.
#
# Exit 3 when the template names a placeholder the caller supplied no value for. That
# is the failure worth catching loudly — a model handed the literal text "{{branch}}"
# will cheerfully treat it as a value and answer confidently about nothing.
subagent_prompt() (  # $1 = prompt name, $2 = tooling root, then key=value pairs
  # Preserve literal replacements on Bash 5.2 without changing the caller's options.
  shopt -u patsub_replacement 2>/dev/null || true
  local name="${1:-}" root="${2:-}"
  if [[ -z "$name" || -z "$root" ]]; then
    printf 'subagent_prompt: name and root are required\n' >&2
    return 2
  fi
  shift 2

  local file="$root/.agents/prompts/$name.md"
  if [[ ! -r "$file" ]]; then
    printf 'subagent_prompt: no such prompt: %s\n' "$file" >&2
    return 2
  fi

  local text pair key value supplied="" needed missing=""
  text="$(subagent_strip_frontmatter "$file")" || return 2
  if [[ "$text" != *[![:space:]]* ]]; then
    printf 'subagent_prompt: empty prompt: %s\n' "$file" >&2
    return 2
  fi

  for pair in "$@"; do
    supplied="$supplied ${pair%%=*}"
  done

  # Checked against the TEMPLATE, before any value is substituted in. Scanning the
  # finished text instead would read a {{ }} occurring inside a VALUE as an unfilled
  # placeholder — and one of these values is sanitized diff text, so any repository
  # with a Vue, Handlebars, Jinja, Mustache, or Go template in its change set would
  # fail its own commit audit citing a placeholder nobody wrote.
  needed="$(printf '%s' "$text" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' | tr -d '{}' | sort -u)"
  for key in $needed; do
    case " $supplied " in
      *" $key "*) ;;
      *) missing="$missing {{$key}}" ;;
    esac
  done
  if [[ -n "$missing" ]]; then
    printf 'subagent_prompt: no value supplied for placeholder(s) in %s:%s\n' "$name" "$missing" >&2
    return 3
  fi

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    text="${text//\{\{$key\}\}/$value}"
  done

  printf '%s\n' "$text"
)

# Timed subagents (design #328): every auditor works to one deadline. Past it, the auditor
# may only record its verdict, and one verdict-less stop is blocked. Hooks and runners
# call these helpers; each auditor supplies its deadline and its record step.

# Prints a timeout that is a decimal integer from 1 through the maximum; otherwise names
# the variable and fails. The length bound comes first: Bash 3.2 wraps integers wider
# than 64 bits, which could turn a huge value into a small accepted one.
subagent_timed_timeout() {  # variable name, value, maximum seconds
  if [[ "$2" =~ ^[1-9][0-9]*$ && ${#2} -le ${#3} ]] && (( $2 <= $3 )); then
    printf '%s\n' "$2"
    return 0
  fi
  printf '%s must be an integer from 1 to %s seconds\n' "$1" "$3" >&2
  return 1
}

# The deadline message a timed subagent receives, before or after its deadline.
subagent_timed_message() {  # passed|stop, record step
  case "$1" in
    passed) printf 'Deadline passed: record your verdict now. %s\n' "$2" ;;
    stop) printf 'Record your verdict before stopping. %s\n' "$2" ;;
    *) return 2 ;;
  esac
}

# Record grace never consumes investigation time or exceeds the lease ceiling.
subagent_timed_stop_seconds() { # investigation seconds, lease maximum
  local budget="$1" maximum="$2" grace=60
  (( budget >= grace )) || grace="$budget"
  if (( budget + grace > maximum )); then
    printf 'audit timeout leaves no room for the bounded record window\n' >&2
    return 2
  fi
  printf '%s\n' "$((budget + grace))"
}

# A resumed stop passes; unchecked results get more investigation only before expiry.
subagent_timed_stop() {  # deadline, recorded|missing|unchecked, resumed, record step
  [[ "$3" != true && "$2" != recorded ]] || return 0
  if (( $(date +%s) < $1 )); then
    case "$2" in
      missing) subagent_timed_message stop "$4" ;;
      unchecked) printf 'Time remains: run each unchecked check, then record again. %s\n' "$4" ;;
    esac
  elif [[ "$2" == missing ]]; then
    subagent_timed_message passed "$4"
  fi
}

# Runs a stream-json Claude CLI, started with --replay-user-messages, as a headless timed
# subagent. stdin holds the task, sent as the first user message. The first `result`
# closes stdin, so the CLI runs any queued turn and exits. At the deadline the record
# message is sent; Claude Code delivers it when the running call or thought ends and
# echoes it then. With no echo by deadline + grace, an interrupt ends that call or thought
# and the queued message runs next, so it is never sent twice; a delivered message is
# never interrupted. Events are matched by `type` and that echo only: an interrupted
# `result` lacks its `result` key (anthropics/claude-code#94741). At the stop time the
# alarm ends the driver (142); the caller then stops its process group. Otherwise it
# exits with the CLI's status. Native Win32 Perl selects only on sockets (perlport), so
# there the task runs without a record turn, as before #328.
subagent_timed_drive() {  # deadline (s), grace (s), stop (s), record message, CLI command...
  perl -MIO::Select -MIPC::Open2 -MJSON::PP -MEncode=decode -MTime::HiRes=time -e '
    use strict;
    use warnings;
    my ($deadline, $grace, $stop, $message, @command) = @ARGV;
    my $start = time;
    alarm $stop;
    $SIG{PIPE} = "IGNORE";
    my $json = JSON::PP->new->utf8->canonical;
    my $task = do { local $/; <STDIN> } // "";
    my $record = decode("UTF-8", $message);
    my $pid = open2(my $from_cli, my $to_cli, @command);
    $to_cli->autoflush(1);
    my $send = sub { print {$to_cli} $json->encode($_[0]), "\n" };
    my $say = sub {
      $send->({type => "user", message => {role => "user", content => $_[0]}});
    };
    my $finish = sub {
      waitpid $pid, 0;
      exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    };
    $say->(decode("UTF-8", $task));
    if ($^O eq "MSWin32") {
      close $to_cli;
      1 while sysread($from_cli, my $chunk, 65536);
      $finish->();
    }
    my @steps = (
      [$start + $deadline, sub { $say->($record) }],
      [$start + $deadline + $grace, sub {
        $send->({type => "control_request", request_id => "timed-subagent-deadline",
                 request => {subtype => "interrupt"}});
      }],
    );
    my ($open, $buffer, $select) = (1, "", IO::Select->new($from_cli));
    while (1) {
      my $wait = $open && @steps ? $steps[0][0] - time : undef;
      $wait = 0 if defined $wait && $wait < 0;
      if (!$select->can_read($wait)) {
        (shift @steps)->[1]->() if $open && @steps;
        next;
      }
      last unless sysread($from_cli, my $chunk, 65536);
      next unless $open;
      $buffer .= $chunk;
      while ($buffer =~ s/\A([^\n]*)\n//) {
        my $event = eval { $json->decode($1) };
        next unless ref $event eq "HASH";
        my $type = $event->{type} // "";
        if ($type eq "user" && $event->{isReplay} && ref $event->{message} eq "HASH") {
          my $content = $event->{message}{content};
          @steps = () if defined $content && !ref $content && $content eq $record;
          next;
        }
        next unless $type eq "result";
        close $to_cli;
        ($open, $buffer) = (0, "");
        last;
      }
    }
    close $to_cli if $open;
    $finish->();
  ' "$@"
}

# Print the block a gate puts in its deny reason.
#
#   subagent_instruction --agent commit-push-auditor --root "$tooling_root" \
#                        --task "$task" [--description D] [--artifact F]
#                        [--codex-task-name N] [--codex-retry-existing]
#                        [--headless CMD]
#
# Exit 2 on a usage error, so a miswired caller fails loudly in tests rather than
# silently emitting an instruction that names nothing.
subagent_instruction() {
  # Fail closed on a missing accessor rather than routing without one. Checked here,
  # not at load, so the library stays inert while sourcing; a fixture that stages this
  # file without hook-host.sh beside it gets an error, never the unknown-host menu.
  if ! declare -F hook_host_kind >/dev/null 2>&1; then
    printf 'subagent_instruction: host accessor is unavailable; stage hook-host.sh beside subagent.sh\n' >&2
    return 2
  fi
  local agent="" root="" task="" description="" artifact="" headless=""
  local codex_task_name="" codex_task_name_explicit=false codex_retry_existing=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --agent requires a value\n' >&2; return 2; }
        agent="$2"; shift 2 ;;
      --root)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --root requires a value\n' >&2; return 2; }
        root="$2"; shift 2 ;;
      --task)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --task requires a value\n' >&2; return 2; }
        task="$2"; shift 2 ;;
      --description)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --description requires a value\n' >&2; return 2; }
        description="$2"; shift 2 ;;
      --artifact)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --artifact requires a value\n' >&2; return 2; }
        artifact="$2"; shift 2 ;;
      --codex-task-name)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --codex-task-name requires a value\n' >&2; return 2; }
        codex_task_name="$2"; codex_task_name_explicit=true; shift 2 ;;
      --codex-retry-existing) codex_retry_existing=true; shift ;;
      --headless)
        [[ $# -ge 2 ]] || { printf 'subagent_instruction: --headless requires a value\n' >&2; return 2; }
        headless="$2"; shift 2 ;;
      *) printf 'subagent_instruction: unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$agent" || -z "$root" || -z "$task" ]]; then
    printf 'subagent_instruction: --agent, --root and --task are required\n' >&2
    return 2
  fi
  [[ -n "$description" ]] || description="$agent"
  if [[ -n "$codex_task_name" && ! "$codex_task_name" =~ ^[a-z0-9_]+$ ]]; then
    printf 'subagent_instruction: --codex-task-name must use lowercase letters, digits, or underscores\n' >&2
    return 2
  fi
  if [[ "$codex_retry_existing" == true && "$codex_task_name_explicit" != true ]]; then
    printf 'subagent_instruction: --codex-retry-existing requires --codex-task-name\n' >&2
    return 2
  fi

  local spec spec_json claude_agent task_json description_json claude_agent_json task_name_json
  local codex_message retry_message codex_message_json retry_message_json artifact_json
  spec="$(subagent_spec_path "$agent" "$root")"
  spec_json="$(subagent_json_string "$spec")" || return 2
  claude_agent="boxlite-agent-tooling:$agent"
  [[ -n "$codex_task_name" ]] || codex_task_name="${agent//-/_}"
  task_json="$(subagent_json_string "$task")" || return 2
  description_json="$(subagent_json_string "$description")" || return 2
  claude_agent_json="$(subagent_json_string "$claude_agent")" || return 2
  task_name_json="$(subagent_json_string "$codex_task_name")" || return 2
  # "the task prompt in the parent instruction" rather than "the Claude prompt":
  # the Claude route is not printed on a Codex host, so naming it would point this
  # message at text the reader cannot see.
  codex_message="$(subagent_prompt subagent/subagent-codex-task "$root" "spec_json=$spec_json")" || return 2
  retry_message="$(subagent_prompt subagent/subagent-retry-task "$root")" || return 2
  codex_message_json="$(subagent_json_string "$codex_message")" || return 2
  retry_message_json="$(subagent_json_string "$retry_message")" || return 2

  # Narrow to the caller's host; fall back to the whole menu when it is unknown.
  # The headless producer is a route of last resort, so it appears only alongside
  # that menu — an agent with a native built-in must not be offered a second CLI.
  local host show_claude=false show_codex=false show_headless=false
  host="$(hook_host_kind)"
  case "$host" in
    claude) show_claude=true ;;
    codex)  show_codex=true ;;
    *)      show_claude=true; show_codex=true; show_headless=true ;;
  esac
  [[ -n "$headless" ]] || show_headless=false

  local instruction section intro=subagent/subagent-intro
  [[ "$show_claude" != true || "$show_codex" != true ]] || intro=subagent/subagent-intro-menu
  instruction="$(subagent_prompt "$intro" "$root" "agent=$agent")" || return 2
  instruction+=$'\n\n'
  if [[ "$show_claude" == true ]]; then
    section="$(subagent_prompt subagent/subagent-claude "$root" "claude_agent_json=$claude_agent_json" \
      "description_json=$description_json" "task_json=$task_json")" || return 2
    instruction+="$section"$'\n\n'
  fi
  if [[ "$show_codex" == true ]]; then
    # Without Claude, the shared task must travel in its own block, exactly once.
    if [[ "$show_claude" != true ]]; then
      section="$(subagent_prompt subagent/subagent-task "$root" "task_json=$task_json")" || return 2
      instruction+="$section"$'\n\n'
    fi
    section="$(subagent_prompt subagent/subagent-codex "$root" "task_name_json=$task_name_json" \
      "codex_message_json=$codex_message_json")" || return 2
    instruction+="$section"$'\n\n'
  fi
  if [[ "$codex_retry_existing" == true && "$show_codex" == true ]]; then
    section="$(subagent_prompt subagent/subagent-retry "$root" "task_name_json=$task_name_json" \
      "retry_message_json=$retry_message_json")" || return 2
    instruction+="$section"$'\n\n'
  fi
  if [[ "$show_headless" == true ]]; then
    section="$(subagent_prompt subagent/subagent-headless "$root" "headless=$headless")" || return 2
    instruction+="$section"$'\n\n'
  fi
  if [[ -n "$artifact" ]]; then
    artifact_json="$(subagent_json_string "$artifact")" || return 2
    section="$(subagent_prompt subagent/subagent-artifact "$root" "artifact_json=$artifact_json")" || return 2
    instruction+="$section"$'\n'
  fi
  # Publish only after every selected template loaded successfully.
  printf '%s' "$instruction"
}
