#!/usr/bin/env bash
# PostToolUse hook: after a successful remote write, tell the running agent to
# attach a consumer to the pr-watch event stream. .githooks/pre-push starts the
# producer for every pusher; this hook bridges its stream into the session.
#
# * Advisory, not `decision: "block"`: the write already happened, and the
#   auto-fix loop this arms ends in a push, so a block would deadlock it.
# * Host matchers name tools only, so this filters Bash commands itself and
#   exits 0 on unrelated commands.
# * `gh pr` writes re-attach a session that pushed earlier or elsewhere.
# * The context names this host's attach route, or every route when
#   hook_host_kind answers `unknown`.
#
# Tests: bash tests/watch/hooks/post-remote-write-watch.test.sh
set -euo pipefail

tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib_dir="$tooling_root/.agents/lib"
load_failure() {
  printf 'post-remote-write-watch: cannot load %s\n' "$1" >&2
  exit 1
}
# shellcheck source=../lib/hook-host.sh
source "$lib_dir/hook-host.sh" || load_failure "$lib_dir/hook-host.sh"

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.cmd // ""')"

remote_write_kind=""
guarded_launcher=""
if [[ "$command" == *gh-pr.sh* ]]; then
  # Recognize a direct, literal launcher call without evaluating shell text.
  guarded_launcher="$(perl -0777 -ne '
    my $single = qr/\x27[^\x27\r\n]*\x27/;
    my $double = qr/"[^\x22\x5c\x24\x60\r\n]*"/;
    my $bare = qr{[A-Za-z0-9._/:=@+%,-]++};
    my $literal = qr/(?:$single|$double|$bare)/;
    if (/\A[ \t]*bash[ \t]+(?:--[ \t]+)?($literal)[ \t]+(?:create|edit)(?:[ \t]+$literal++)*[ \t]*\n?\z/) {
      my $path = $1;
      $path =~ s/\A(["\x27])(.*)\1\z/$2/;
      print $path;
    }
  ' <<<"$command")"
fi
if [[ -n "$guarded_launcher" ]]; then
  remote_write_kind="gh_pr_file"
elif hook_command_segment_verb "$command" 'git[[:space:]]+(push)' >/dev/null; then
  remote_write_kind="git_push"
elif hook_command_segment_verb "$command" \
    'gh[[:space:]]+pr[[:space:]]+(create|edit|ready|comment|review)' >/dev/null; then
  remote_write_kind="gh_pr"
else
  exit 0
fi

[[ "${BOXLITE_PR_WATCH:-1}" == "0" ]] && exit 0

# Native shell results can report failure without Git's usual diagnostic text.
if printf '%s' "$payload" | jq -e '
  (.tool_response | type) == "object"
  and (.tool_response | has("exit_code"))
  and .tool_response.exit_code != 0' >/dev/null; then
  exit 0
fi

# tool_response is a string for some tools and an object for Bash; accept both
# rather than assuming a shape.
response="$(printf '%s' "$payload" \
  | jq -r 'if (.tool_response | type) == "string"
           then .tool_response
           else ((.tool_response.stdout // .tool_response.output // "") + "\n" + (.tool_response.stderr // ""))
           end' 2>/dev/null || echo '')"

# Hosts without an exit code are checked against Git's output. Match the whole
# `error:`/`fatal:` class: a rejecting local pre-push hook prints only
# `error: failed to push some refs`. Over-matching costs an un-armed watch;
# under-matching reports a push that never happened.
failure_re='(^|[[:space:]])(fatal|error):|\[(remote )?rejected\]|Everything up-to-date|Permission denied'
if [[ "$response" =~ $failure_re ]]; then
  exit 0
fi

if [[ "$remote_write_kind" == gh_pr_file ]]; then
  command_dir="$(hook_payload_workdir "$payload" "$PWD")" || exit 0
  cd -- "$command_dir" 2>/dev/null || exit 0
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
# The stream script and escalation policy live in this tooling tree, never at
# the consumer's repository root.
# shellcheck source=../lib/verdict-audit-state.sh
source "$lib_dir/verdict-audit-state.sh" || load_failure "$lib_dir/verdict-audit-state.sh"
# shellcheck source=../lib/pr-watch-state.sh
source "$lib_dir/pr-watch-state.sh" || load_failure "$lib_dir/pr-watch-state.sh"
state_dir="$(git -C "$repo_root" rev-parse --git-path pr-watch 2>/dev/null || echo '')"
[[ -z "$state_dir" ]] && exit 0
[[ "$state_dir" != /* ]] && state_dir="$repo_root/$state_dir"

guarded_pr_url=""
if [[ "$remote_write_kind" == gh_pr_file ]]; then
  [[ "$guarded_launcher" -ef "$tooling_root/scripts/gh-pr.sh" ]] || exit 0
  guarded_result="$(jq -er '
    def lines: gsub("\r\n"; "\n") | sub("\n+\\z"; "");
    .tool_response | if type == "string" then lines
      elif type == "object" then
        (.stdout // .output | strings | lines) as $out
        | (.stderr // "" | strings | lines) as $err
        | if $err == "" then $out else $out + "\n" + $err end
      else empty end
  ' <<<"$payload")" || exit 0
  guarded_pr_url="${guarded_result%%$'\n'*}"
  pr_watch_url_is_valid "$guarded_pr_url" || exit 0
  checkout="$(pr_watch_checkout_digest "$repo_root")" || exit 0
  [[ "$guarded_result" == "$guarded_pr_url"$'\n'"boxlite-pr-write $checkout $guarded_pr_url" ]] || exit 0
fi

attachment_body=""
attachment_claim=""
attachment_claim_identity=""
attachment_claim_hash=""
attachment_prompt_epoch=""
attachment_prompt_epoch_path=""
attachment_manifest=""
attachment_manifest_identity=""
attachment_marker_identity=""
attachment_owner_pid=""
attachment_owner_token=""
attachment_recovery_marker=""
attachment_recovery_source_marker=""
attachment_lease_pid=""
attachment_lease_nonce=""
attachment_lease_identity=""
attachment_lease_fd_open=false
attachment_published=false
active_lookup_pid=""
active_lookup_fd_open=false

# A separate kernel flock is the live lease, so recovery never trusts a recycled
# PID or a wall-clock-resolution start token. `discard` leaves an unparsed
# `retired:` record, which no reader accepts.
transition_attachment_claim_state() {  # check|acquire|retry|discard
  local target="$1" target_record new_identity
  [[ -n "$attachment_manifest" && -n "$attachment_manifest_identity" \
     && -n "$attachment_marker_identity" \
     && -n "$attachment_claim" && -n "$attachment_claim_identity" \
     && "$attachment_claim_hash" =~ ^[0-9a-f]{64}$ \
     && "$attachment_lease_pid" =~ ^[1-9][0-9]*$ \
     && "$attachment_lease_nonce" =~ ^[0-9a-f]{32}$ \
     && "$attachment_lease_identity" =~ ^[0-9]+:[0-9]+$ \
     && -n "$attachment_prompt_epoch" \
     && -n "$attachment_prompt_epoch_path" \
     && "$target" =~ ^(check|acquire|retry|discard)$ ]] || return 1
  if [[ "$target" == acquire ]]; then
    [[ -n "$attachment_recovery_marker" \
       && -n "$attachment_recovery_source_marker" ]] || return 1
    target_record="$attachment_recovery_marker"
  elif [[ "$target" == check ]]; then
    [[ -n "$attachment_recovery_source_marker" ]] || return 1
    target_record="$attachment_recovery_source_marker"
  elif [[ "$target" == retry ]]; then
    target_record="retry:${attachment_manifest_identity}:${attachment_claim_hash}"
  else
    target_record="retired:${attachment_manifest_identity}:${attachment_claim_hash}"
  fi
  new_identity="$(pr_watch_attachment_transition "$attachment_manifest" \
    "$attachment_manifest_identity" "$attachment_marker_identity" \
    "$attachment_claim" "$attachment_claim_identity" "$attachment_claim_hash" \
    "$target" "$attachment_recovery_source_marker" "$target_record" \
    "${attachment_manifest}.lease" "$attachment_lease_identity" \
    "$attachment_lease_nonce" "$attachment_prompt_epoch_path" \
    "$attachment_prompt_epoch")" || return 1
  [[ "$new_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  attachment_marker_identity="$new_identity"
  attachment_recovery_source_marker="$target_record"
}

stop_attachment_recovery_lease() {
  if [[ "$attachment_lease_fd_open" == true ]]; then
    exec 6<&-
    attachment_lease_fd_open=false
  fi
  if [[ "$attachment_lease_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$attachment_lease_pid" 2>/dev/null || true
    wait "$attachment_lease_pid" 2>/dev/null || true
  fi
  attachment_lease_pid=""
  attachment_lease_nonce=""
  attachment_lease_identity=""
}

start_attachment_recovery_lease() {
  local lease_path="${attachment_manifest}.lease" lease_signal=""
  local ready_record ready_pid ready_nonce ready_device ready_inode
  [[ -n "$attachment_manifest" && -n "$attachment_marker_identity" ]] || return 1
  trap 'lease_signal=TERM' TERM
  trap 'lease_signal=INT' INT
  exec 6< <(pr_watch_attachment_lease_hold "$lease_path" "$$")
  attachment_lease_pid=$!
  attachment_lease_fd_open=true
  trap 'exit 143' TERM
  trap 'exit 130' INT
  case "$lease_signal" in
    TERM) exit 143 ;;
    INT) exit 130 ;;
  esac
  if ! IFS= read -r -t 2 ready_record <&6; then
    stop_attachment_recovery_lease
    return 1
  fi
  if [[ "$ready_record" =~ ^lease:([1-9][0-9]*):([0-9a-f]{32}):([0-9]+):([0-9]+)$ ]]; then
    ready_pid="${BASH_REMATCH[1]}"
    ready_nonce="${BASH_REMATCH[2]}"
    ready_device="${BASH_REMATCH[3]}"
    ready_inode="${BASH_REMATCH[4]}"
  else
    stop_attachment_recovery_lease
    return 1
  fi
  [[ "$ready_pid" == "$attachment_lease_pid" ]] || {
    stop_attachment_recovery_lease
    return 1
  }
  attachment_lease_pid="$ready_pid"
  attachment_lease_nonce="$ready_nonce"
  attachment_lease_identity="${ready_device}:${ready_inode}"
}

clear_attachment_claim_state() {
  attachment_body=""
  attachment_claim=""
  attachment_claim_identity=""
  attachment_claim_hash=""
  attachment_prompt_epoch=""
  attachment_prompt_epoch_path=""
  attachment_manifest=""
  attachment_manifest_identity=""
  attachment_marker_identity=""
  attachment_owner_pid=""
  attachment_owner_token=""
  attachment_recovery_marker=""
  attachment_recovery_source_marker=""
  attachment_lease_identity=""
}

discard_attachment_claim() {
  if [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]]; then
    transition_attachment_claim_state discard 2>/dev/null || true
  fi
  stop_attachment_recovery_lease
  clear_attachment_claim_state
}

terminate_active_lookup() {
  local deadline
  if [[ "$active_lookup_fd_open" == true ]]; then
    exec 7<&-
    active_lookup_fd_open=false
  fi
  if [[ "$active_lookup_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM -- "-$active_lookup_pid" 2>/dev/null || true
    deadline=$(( SECONDS + 1 ))
    while (( SECONDS < deadline )) \
       && kill -0 -- "-$active_lookup_pid" 2>/dev/null; do
      sleep 0.05
    done
    kill -KILL -- "-$active_lookup_pid" 2>/dev/null || true
    wait "$active_lookup_pid" 2>/dev/null || true
  fi
  active_lookup_pid=""
}

post_write_cleanup() {
  local status=$?
  set +e
  trap - EXIT TERM INT
  trap '' TERM INT
  terminate_active_lookup
  if [[ -n "$attachment_claim" ]]; then
    # Hook stdout has no durable host acknowledgement. Keep retry authority
    # until the rendered consumer consumes the exact claim capability.
    if ! transition_attachment_claim_state retry 2>/dev/null \
       && (( status == 0 )); then
      status=1
    fi
    stop_attachment_recovery_lease
    clear_attachment_claim_state
  fi
  exit "$status"
}

trap post_write_cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

bounded_pr_number=""
lookup_pr_number_bounded() {  # repository-slug branch
  local slug="$1" branch="$2" lookup_signal="" lookup_record=""
  bounded_pr_number=""
  trap 'lookup_signal=TERM' TERM
  trap 'lookup_signal=INT' INT
  # The process-substitution pipe is the only parent-facing descriptor. The
  # supervisor replaces stdout and closes every internal descriptor before gh,
  # so the child cannot forge completion. No filesystem temp path exists.
  exec 7< <(exec perl -MFcntl=:DEFAULT -MIO::Select -MPOSIX=:sys_wait_h \
      -MTime::HiRes=time -e '
    use strict;
    use warnings;
    my ($slug, $branch) = @ARGV;
    my $max = 128;
    my $deadline = time() + 5;
    my $cancel = 0;
    $SIG{TERM} = sub { $cancel = 1 };
    $SIG{INT} = sub { $cancel = 1 };
    POSIX::setpgid(0, 0);
    pipe(my $reader, my $writer) or exit 1;
    my $child = fork();
    exit 1 unless defined($child);
    if ($child == 0) {
      POSIX::setpgid(0, 0);
      close($reader);
      POSIX::dup2(fileno($writer), 1) >= 0 or exit 125;
      sysopen(my $null, "/dev/null", O_WRONLY) or exit 125;
      POSIX::dup2(fileno($null), 2) >= 0 or exit 125;
      for my $fd (3 .. 255) { POSIX::close($fd) }
      exec {"/bin/bash"} "bash", "-c", q{gh "$@"}, "gh",
        "pr", "list", "--repo", $slug, "--head", $branch,
        "--state", "open", "--json", "number", "--jq",
        ".[0].number // empty";
      exit 127;
    }
    POSIX::setpgid($child, $child);
    close($writer);
    my $flags = fcntl($reader, F_GETFL, 0);
    exit 1 unless defined($flags) && fcntl($reader, F_SETFL, $flags | O_NONBLOCK);
    my $selector = IO::Select->new($reader);
    my $output = "";
    my $status;
    my $reaped = 0;
    my $over_limit = 0;
    while (!$cancel && time() < $deadline) {
      my $waited = waitpid($child, WNOHANG);
      if ($waited == $child) {
        $status = $?;
        $reaped = 1;
      }
      my @ready = $selector->can_read(0.02);
      if (@ready) {
        my $chunk = "";
        my $wanted = $max + 1 - length($output);
        $wanted = 1 if $wanted < 1;
        my $count = sysread($reader, $chunk, $wanted);
        if (defined($count)) {
          last if $count == 0 && $reaped;
          $output .= $chunk if $count > 0;
          if (length($output) > $max) {
            $over_limit = 1;
            last;
          }
        } elsif (!$!{EAGAIN} && !$!{EWOULDBLOCK} && !$!{EINTR}) {
          last;
        }
      }
      last if $reaped && !@ready;
    }
    kill "TERM", -$child;
    my $kill_deadline = time() + 0.25;
    while (!$reaped && time() < $kill_deadline) {
      my $waited = waitpid($child, WNOHANG);
      if ($waited == $child) {
        $status = $?;
        $reaped = 1;
        last;
      }
      select(undef, undef, undef, 0.01);
    }
    if (!$reaped) {
      kill "KILL", -$child;
      waitpid($child, 0);
      $status = $?;
      $reaped = 1;
    }
    close($reader);
    my $exit_ok = defined($status) && POSIX::WIFEXITED($status)
      && POSIX::WEXITSTATUS($status) == 0;
    if (!$cancel && !$over_limit && time() <= $deadline && $exit_ok) {
      $output =~ s/\n\z//;
      if ($output eq "") {
        print "none:\n";
        exit 0;
      }
      if ($output =~ /\A[1-9][0-9]*\z/ && length($output) <= $max) {
        print "ok:", $output, "\n";
        exit 0;
      }
    }
    print "error:\n";
    exit 1;
  ' "$slug" "$branch")
  active_lookup_pid=$!
  active_lookup_fd_open=true
  trap 'exit 143' TERM
  trap 'exit 130' INT
  case "$lookup_signal" in
    TERM) exit 143 ;;
    INT) exit 130 ;;
  esac
  if ! IFS= read -r -t 7 lookup_record <&7; then
    terminate_active_lookup
    return 1
  fi
  exec 7<&-
  active_lookup_fd_open=false
  wait "$active_lookup_pid" 2>/dev/null || true
  active_lookup_pid=""
  if [[ "$lookup_record" =~ ^ok:([1-9][0-9]*)$ ]]; then
    bounded_pr_number="${BASH_REMATCH[1]}"
    return 0
  fi
  [[ "$lookup_record" == none: ]]
}

attachment_epoch_is_current() {
  local current_prompt_epoch
  [[ -n "$attachment_body" && -n "$attachment_prompt_epoch" \
     && -n "$attachment_prompt_epoch_path" ]] || return 1
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$attachment_prompt_epoch_path" 2>/dev/null)" || return 1
  [[ "$current_prompt_epoch" == "$attachment_prompt_epoch" ]]
}

inspect_attachment_manifest() {
  local session_scope command_hash attachment_key manifest manifest_identity manifest_hash
  local snapshot mtime body now marker_identity marker_hash
  local slot candidate_claim candidate_identity candidate_snapshot
  local candidate_mtime candidate_body candidate_hash claim_matches=0
  local recovered_claim="" recovered_claim_identity=""
  local recovery_source_marker="" recovery_owner_pid recovery_owner_token
  local manifest_prompt_epoch prompt_epoch_path current_prompt_epoch
  local owner_pid owner_token entry branch_key expected_log branch
  session_scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo_root" 2>/dev/null)" || return 1
  command_hash="$(LC_ALL=C printf '%s' "$command" | verdict_audit_sha256)" || return 1
  attachment_key="$(pr_watch_attachment_key "$session_scope" "$command_hash" 2>/dev/null)" || return 1
  manifest="$state_dir/${attachment_key}.json"
  manifest_identity="$(verdict_audit_path_identity "$manifest" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$manifest" 2>/dev/null)" || return 1
  verdict_audit_selected_identity_matches \
    "$manifest" "$manifest_identity" 2>/dev/null || return 1
  [[ "$snapshot" == *$'\n'* ]] || return 1
  mtime="${snapshot%%$'\n'*}"
  body="${snapshot#*$'\n'}"
  now="$(date +%s)"
  [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime <= now && now - mtime <= 300 )) || return 1
  if [[ "$body" =~ ^(consumed|retry):([0-9]+):([0-9]+):([0-9a-f]{64})$ ]]; then
    marker_identity="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    marker_hash="${BASH_REMATCH[4]}"
    recovery_source_marker="$body"
  elif [[ "$body" =~ ^recovering:([0-9]+):([0-9]+):([0-9a-f]{64}):([1-9][0-9]*):(lease-[0-9a-f]{32}):([0-9]+):([0-9]+)$ ]]; then
    marker_identity="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    marker_hash="${BASH_REMATCH[3]}"
    recovery_owner_pid="${BASH_REMATCH[4]}"
    recovery_owner_token="${BASH_REMATCH[5]}"
    [[ ${#recovery_owner_pid} -le 18 \
       && -n "$recovery_owner_token" \
       && ${#BASH_REMATCH[6]} -le 20 \
       && ${#BASH_REMATCH[7]} -le 20 ]] || return 1
    recovery_source_marker="$body"
  elif [[ "$body" =~ ^recovering:[0-9]+:[0-9]+:[0-9a-f]{64}:[1-9][0-9]*:(cksum-[0-9]+-[0-9]+|lease-[0-9a-f]{32})$ ]]; then
    # A recovery record without the lease inode is unsupported.
    printf 'agent-tooling: unsupported watch recovery record; restart the PR watch\n' >&2
    return 1
  fi
  if [[ -n "$recovery_source_marker" ]]; then
    for slot in 0 1 2 3; do
      candidate_claim="${manifest}.claim.${slot}"
      candidate_identity="$(verdict_audit_path_identity \
        "$candidate_claim" 2>/dev/null)" || continue
      candidate_snapshot="$(verdict_audit_read_json_snapshot \
        "$candidate_claim" 2>/dev/null)" || continue
      verdict_audit_selected_identity_matches \
        "$candidate_claim" "$candidate_identity" 2>/dev/null || continue
      [[ "$candidate_snapshot" == *$'\n'* ]] || continue
      candidate_mtime="${candidate_snapshot%%$'\n'*}"
      candidate_body="${candidate_snapshot#*$'\n'}"
      [[ "$candidate_mtime" =~ ^[0-9]+$ \
         && ${#candidate_mtime} -le 18 ]] || continue
      (( candidate_mtime <= now && now - candidate_mtime <= 600 )) || continue
      candidate_hash="$(LC_ALL=C printf '%s' "$candidate_body" \
        | verdict_audit_sha256)" || continue
      [[ "$candidate_hash" == "$marker_hash" ]] || continue
      claim_matches=$((claim_matches + 1))
      recovered_claim="$candidate_claim"
      recovered_claim_identity="$candidate_identity"
      body="$candidate_body"
    done
    (( claim_matches == 1 )) || return 1
    manifest_hash="$marker_hash"
  else
    manifest_hash="$(LC_ALL=C printf '%s' "$body" \
      | verdict_audit_sha256)" || return 1
    [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  printf '%s' "$body" | jq -e -L "$lib_dir" --arg command_hash "$command_hash" \
    --arg session_scope "$session_scope" --argjson now "$now" '
      include "pr-watch-attachment";
      pr_watch_attachment_lifecycle($now; 300) and pr_watch_attachment_entries
      and .command_hash == $command_hash and .session_scope == $session_scope' \
    >/dev/null 2>&1 || return 1
  manifest_prompt_epoch="$(printf '%s' "$body" | jq -r '.prompt_epoch')"
  prompt_epoch_path="$(verdict_audit_state_path \
    "$repo_root/.agents/state/verdict-prompt-epoch" "$session_scope")"
  current_prompt_epoch="$(verdict_audit_read_single_record \
    "$prompt_epoch_path" 2>/dev/null)" || return 1
  [[ "$current_prompt_epoch" == "$manifest_prompt_epoch" ]] || return 1
  owner_pid="$(printf '%s' "$body" | jq -r '.owner.pid')"
  owner_token="$(printf '%s' "$body" | jq -r '.owner.start_token')"
  verdict_audit_process_has_ancestor "$owner_pid" "$owner_token" || return 1
  while IFS= read -r entry; do
    branch="$(printf '%s' "$entry" | jq -r '.branch')"
    git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1
    branch_key="$(pr_watch_branch_key "$branch" 2>/dev/null)" || return 1
    expected_log="$state_dir/${branch_key}.jsonl"
    [[ "$(printf '%s' "$entry" | jq -r '.event_log')" == "$expected_log" ]] || return 1
  done < <(printf '%s' "$body" | jq -c '.entries[]')

  attachment_body="$body"
  attachment_claim="$recovered_claim"
  attachment_claim_identity="$recovered_claim_identity"
  attachment_manifest="$manifest"
  attachment_manifest_identity="${marker_identity:-$manifest_identity}"
  attachment_marker_identity="$manifest_identity"
  attachment_claim_hash="$manifest_hash"
  attachment_prompt_epoch="$manifest_prompt_epoch"
  attachment_prompt_epoch_path="$prompt_epoch_path"
  attachment_owner_pid="$owner_pid"
  attachment_owner_token="$owner_token"
  if [[ -n "$recovery_source_marker" ]]; then
    start_attachment_recovery_lease || {
      clear_attachment_claim_state
      return 1
    }
    attachment_recovery_source_marker="$recovery_source_marker"
    attachment_recovery_marker="recovering:${attachment_manifest_identity}:${manifest_hash}:${attachment_lease_pid}:lease-${attachment_lease_nonce}:${attachment_lease_identity}"
    transition_attachment_claim_state acquire 2>/dev/null || {
      stop_attachment_recovery_lease
      clear_attachment_claim_state
      return 1
    }
  fi
}

claim_attachment_manifest() {
  local now slot candidate_claim candidate_identity claimed_snapshot claimed_body
  local claim_signal=""
  [[ -n "$attachment_body" && -n "$attachment_manifest" \
     && -n "$attachment_manifest_identity" \
     && "$attachment_claim_hash" =~ ^[0-9a-f]{64}$ \
     && "$attachment_owner_pid" =~ ^[1-9][0-9]*$ \
     && "$attachment_owner_token" =~ ^cksum-[0-9]+-[0-9]+$ ]] || return 1
  attachment_epoch_is_current || return 1
  verdict_audit_process_has_ancestor \
    "$attachment_owner_pid" "$attachment_owner_token" || return 1
  now="$(date +%s)"
  attachment_claim=""
  attachment_claim_identity=""
  for slot in 0 1 2 3; do
    candidate_claim="${attachment_manifest}.claim.${slot}"
    pr_watch_retire_attachment_claim "$candidate_claim" "$now" 600 \
      2>/dev/null || true
    # A signal is delivered between Bash simple commands. Defer its exit across
    # claim selection so cleanup always learns the exact destination identity.
    trap 'claim_signal=TERM' TERM
    trap 'claim_signal=INT' INT
    candidate_identity=""
    if candidate_identity="$(pr_watch_claim_regular_file \
        "$attachment_manifest" "$candidate_claim" \
        "$attachment_manifest_identity" "$attachment_claim_hash" \
        2>/dev/null)"; then
      attachment_claim="$candidate_claim"
      attachment_claim_identity="$candidate_identity"
    fi
    trap 'exit 143' TERM
    trap 'exit 130' INT
    case "$claim_signal" in
      TERM) exit 143 ;;
      INT) exit 130 ;;
    esac
    [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]] \
      || continue
    break
  done
  [[ -n "$attachment_claim" && -n "$attachment_claim_identity" ]] || return 1
  start_attachment_recovery_lease || {
    clear_attachment_claim_state
    return 1
  }
  attachment_recovery_source_marker="$attachment_body"
  attachment_recovery_marker="recovering:${attachment_manifest_identity}:${attachment_claim_hash}:${attachment_lease_pid}:lease-${attachment_lease_nonce}:${attachment_lease_identity}"
  transition_attachment_claim_state acquire 2>/dev/null || {
    # Another exact hook may have won the JSON-to-recovering CAS during the few
    # instructions after same-inode claim publication. It owns the claim.
    stop_attachment_recovery_lease
    clear_attachment_claim_state
    return 1
  }
  claimed_snapshot="$(verdict_audit_read_json_snapshot "$attachment_claim" 2>/dev/null)" || {
    discard_attachment_claim
    return 1
  }
  verdict_audit_selected_identity_matches \
    "$attachment_claim" "$attachment_claim_identity" 2>/dev/null || {
    discard_attachment_claim
    return 1
  }
  claimed_body="${claimed_snapshot#*$'\n'}"
  if [[ "$claimed_body" != "$attachment_body" ]] \
     || ! transition_attachment_claim_state check 2>/dev/null; then
    discard_attachment_claim
    return 1
  fi
}

if [[ "$remote_write_kind" == "git_push" ]] \
   && printf '%s' "$payload" | jq -e '(.session_id | type) == "string" and (.session_id | length) > 0' \
      >/dev/null 2>&1; then
  inspect_attachment_manifest || exit 0
fi

branch_count=1
omitted_ref_count=0
if [[ -n "$attachment_body" ]]; then
  branch="$(printf '%s' "$attachment_body" | jq -r '.entries[0].branch')"
  branch_count="$(printf '%s' "$attachment_body" | jq -r '.entries | length')"
  omitted_ref_count="$(printf '%s' "$attachment_body" | jq -r '.omitted_refs')"
else
  branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '')"
fi
[[ -z "$branch" ]] && exit 0

slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null \
        | sed -e 's#^git@[^:]*:##' -e 's#^[a-z+]*://[^/]*/##' -e 's#\.git$##')"
if [[ -n "$guarded_pr_url" ]]; then
  origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null)" || exit 0
  case "$origin" in
    git@github.com:*|https://github.com/*|ssh://git@github.com/*) ;;
    *) exit 0 ;;
  esac
  [[ "$guarded_pr_url" == "https://github.com/$slug/pull/"* ]] || exit 0
  pr_number="${guarded_pr_url##*/}"
else
  pr_number="$(printf '%s' "$response" \
    | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -1)"
  if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    lookup_pr_number_bounded "$slug" "$branch" || true
    pr_number="$bounded_pr_number"
  fi
fi

# All potentially slow work is complete. Consume the manifest only when this
# invocation can immediately render and publish the exact claim command.
if [[ -n "$attachment_body" && -z "$attachment_claim" ]]; then
  claim_attachment_manifest || exit 0
fi

stream_script="$tooling_root/.agents/watch/pr-watch-stream.sh"
attach_script="$tooling_root/.agents/watch/pr-watch-attach.sh"
policy_path="$tooling_root/.agents/watch/escalation-policy.md"
# Both paths can contain shell metacharacters; the branch-derived event path is
# attacker-controlled within Git's ref grammar. Emit one Bash-copyable command whose
# arguments stay data even for quotes, dollars, semicolons, and substitutions.
if [[ -n "$attachment_body" ]]; then
  printf -v stream_command 'bash %q %q %q %q' \
    "$attach_script" "$attachment_claim" "$attachment_claim_identity" \
    "$attachment_claim_hash"
else
  branch_key="$(pr_watch_branch_key "$branch")" || {
    printf 'post-remote-write-watch: cannot derive branch state identity\n' >&2
    exit 1
  }
  event_log="$state_dir/${branch_key}.jsonl"
  if [[ -n "$guarded_pr_url" ]]; then
    owner="$(pr_watch_owner_read "$state_dir/$branch_key.lock")" || exit 0
    IFS=$'\t' read -r _ watch_id owner_ready <<<"$owner"
    [[ "$owner_ready" == true ]] || exit 0
    printf -v stream_command 'bash %q %q --watch-id %q --expect-pr-url %q' \
      "$stream_script" "$event_log" "$watch_id" "$guarded_pr_url"
  else
    printf -v stream_command 'bash %q %q' "$stream_script" "$event_log"
  fi
fi
policy_path_json="$(jq -Rn --arg path "$policy_path" '$path')"

pr_line="No open PR for '${branch}' yet; the watcher polls until one appears."
compact_pr_line="No open PR may exist yet; the watcher polls."
if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
  pr_line="PR #${pr_number}: https://github.com/${slug}/pull/${pr_number}"
  compact_pr_line="PR #${pr_number}."
fi

branch_line="Remote write succeeded on '${branch}'."
if (( branch_count > 1 || omitted_ref_count > 0 )); then
  pushed_ref_count=$((branch_count + omitted_ref_count))
  branch_line="Remote write succeeded for ${pushed_ref_count} pushed branches; ${branch_count} exact watcher generations attached, ${omitted_ref_count} omitted."
fi
# shellcheck source=../lib/subagent.sh
source "$tooling_root/.agents/lib/subagent.sh" || exit 1
# Keep host-specific setup within the context budget.
schedule_prompt_path_json="$(jq -Rn --arg path "$tooling_root/.agents/prompts/watch/pr-watch-schedule.md" '$path')"
codex_attach_line="$(subagent_prompt watch/watch-attach-codex "$tooling_root" \
  "schedule_prompt_path_json=$schedule_prompt_path_json")" || exit 1
codex_compact_line="$(subagent_prompt watch/watch-attach-codex-compact "$tooling_root")" || exit 1
if [[ -n "$guarded_pr_url" ]]; then
  codex_attach_line='Codex: run the stream in the active shell session. Drain it as the task continues.'
  codex_compact_line="$codex_attach_line"
fi
host_kind="$(hook_host_kind)"
case "$host_kind" in
  claude)
    attach_line="$(subagent_prompt watch/watch-attach-claude "$tooling_root")" || exit 1
    compact_attach_line="$(subagent_prompt watch/watch-attach-claude-compact "$tooling_root")" || exit 1 ;;
  codex)
    attach_line="$codex_attach_line"
    compact_attach_line="$codex_compact_line" ;;
  *)
    attach_line="$(subagent_prompt watch/watch-attach-claude "$tooling_root")" || exit 1
    attach_line+=" ${codex_attach_line}"
    compact_attach_line="$(subagent_prompt watch/watch-attach-claude-compact "$tooling_root")" || exit 1
    compact_attach_line+=" ${codex_compact_line}" ;;
esac

context="$(subagent_prompt watch/watch-attach "$tooling_root" \
  "branch_line=$branch_line" "pr_line=$pr_line" "policy_path_json=$policy_path_json" \
  "stream_command=$stream_command" "attach_line=$attach_line")" || exit 1

context_max_bytes=1400
context_bytes="$(LC_ALL=C printf '%s' "$context" | wc -c | tr -d ' ')"
if (( context_bytes > context_max_bytes )); then
  # Preserve the exact command and resolved PR when paths exhaust the budget.
  context="$(subagent_prompt watch/watch-attach-compact "$tooling_root" \
    "branch_line=$branch_line" "compact_pr_line=$compact_pr_line" \
    "policy_path_json=$policy_path_json" "stream_command=$stream_command" \
    "compact_attach_line=$compact_attach_line")" || exit 1
fi

# Recheck dynamic paths; raw replay cannot safely replace generation binding.
context_bytes="$(LC_ALL=C printf '%s' "$context" | wc -c | tr -d ' ')"
if (( context_bytes > context_max_bytes )); then
  [[ -z "$attachment_claim" ]] || discard_attachment_claim
  context="$(subagent_prompt watch/watch-attach-oversized "$tooling_root")" || exit 1
fi

# A later real prompt or replacement lease revokes this exact publisher. Recheck
# the marker, claim, epoch, nonce, and locked lease inode immediately before output.
if [[ -n "$attachment_body" ]] \
   && ! transition_attachment_claim_state check 2>/dev/null; then
  stop_attachment_recovery_lease
  clear_attachment_claim_state
  exit 0
fi

if jq -nc --arg c "$context" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $c
    }
  }'; then
  # shellcheck disable=SC2034 # Lifecycle fault-injection probes this boundary.
  attachment_published=true
else
  exit 1
fi
exit 0
