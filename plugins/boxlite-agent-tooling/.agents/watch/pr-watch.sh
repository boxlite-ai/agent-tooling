#!/usr/bin/env bash
# Agent-agnostic CI + PR-state watcher.
#
# Armed by .githooks/pre-push after a push, so it runs identically for Claude
# Code, Codex, opencode, and a human at a terminal. Emits one JSON object per
# line — to stdout and to a generation-scoped journal — as checks conclude and as
# merge conflicts and comments/reviews arrive.
#
# Consumers:
#   Claude Code  .agents/hooks/post-remote-write-watch.sh arms a Monitor on the log
#   other agents tail the log, or run this in the foreground
#   humans       run pr-watch-stream.sh with the event path reported by the hook
#
# Usage:
#   pr-watch.sh --branch <name> [--sha <sha>] [--watch-id <id>]
#                                                # arm for a just-pushed branch
#   pr-watch.sh --pr <number>                   # watch a known PR
#   pr-watch.sh --pr <number> --once            # one poll pass, then exit
#
# The polling loop runs until the PR is MERGED or CLOSED. Going quiet is NOT a
# reason to stop; losing contact with GitHub or hitting the lifetime backstop is.
# (It also exits early for --once, on TERM/INT, when another watcher already
# holds the branch lock, and when no PR ever appears.)
#
# Env:
#   BOXLITE_PR_WATCH=0        disable entirely (checked by the caller and here)
#   PR_WATCH_INTERVAL         poll seconds (default 30; GitHub rate limits)
#   PR_WATCH_IDLE_TIMEOUT     give up after this long with no SUCCESSFUL poll
#                             (default 7200) — contact lost, not silence
#   PR_WATCH_MAX_LIFETIME     absolute cap for a PR that never merges
#                             (default 604800 = 7 days; 0 disables the cap)
#   PR_WATCH_COMMAND_TIMEOUT  max seconds for one git/gh request (default 60;
#                             hard max 3600)
#
# Design notes
# ------------
# * No `set -e`: a daemon must outlive a transient `gh` failure. Every network
#   call is `|| true`-guarded and its output validated before use.
# * Every terminal bucket is emitted, not just `pass`. A watcher that reports
#   only success is indistinguishable from one that died — silence must never
#   read as "still green".
# * De-dup is by a stable key per observation, persisted next to the log, so a
#   restarted watcher does not replay the whole history.
#
# Tests: bash .agents/watch/pr-watch.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_helpers="$script_dir/../lib/pr-watch-state.sh"
if [[ ! -r "$state_helpers" ]]; then
  printf 'pr-watch: state helper not found: %s\n' "$state_helpers" >&2
  exit 127
fi
# shellcheck source=../lib/pr-watch-state.sh
source "$state_helpers" || exit 127
safe_state_helpers="$script_dir/../lib/verdict-audit-state.sh"
if [[ ! -r "$safe_state_helpers" ]]; then
  printf 'pr-watch: safe state helper not found: %s\n' "$safe_state_helpers" >&2
  exit 127
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$safe_state_helpers" || exit 127

readonly DEFAULT_INTERVAL=30
# Time without a SUCCESSFUL poll — i.e. contact lost — not time without events.
readonly DEFAULT_IDLE_TIMEOUT=7200
# Backstop for a PR that is never merged or closed. A week is an arbitrary
# default, chosen long enough that it is not what normally ends a watch; override
# with PR_WATCH_MAX_LIFETIME, or 0 to remove the cap.
readonly DEFAULT_MAX_LIFETIME=604800
readonly DEFAULT_COMMAND_TIMEOUT=60
readonly HARD_MAX_INTERVAL=3600
readonly HARD_COMMAND_TIMEOUT=3600
readonly BODY_MAX_CHARS=600
readonly JOURNAL_MAX_BYTES=2097152
readonly JOURNAL_TERMINAL_RESERVE_BYTES=16384
readonly SEEN_RETAIN_MAX_BYTES=2097152
readonly EXTERNAL_OUTPUT_MAX_BYTES=8388608
readonly EXTERNAL_OUTPUT_MAX_KIB=8192

watch_positive_decimal_is_bounded() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 18 ]]
}

watch_nonnegative_decimal_is_bounded() {
  local value="$1"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ && ${#value} -le 18 ]]
}

branch=""
sha=""
pr_number=""
once=0
requested_watch_id=""
ready_fd=""

# Print the header block: every comment line after the shebang, stopping at the
# first non-comment. A hardcoded line range silently truncates --help the moment
# the header grows.
usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

# `shift 2` on a lone flag shifts nothing and leaves $1 in place, so the same
# case branch matches forever. Require the value before consuming it.
need_value() {
  [[ -n "${2+set}" ]] || { printf 'pr-watch: %s requires a value\n' "$1" >&2; usage 1; }
}

while (( $# )); do
  case "$1" in
    --branch) need_value "$1" ${2+"$2"}; branch="$2";    shift 2 ;;
    --sha)    need_value "$1" ${2+"$2"}; sha="$2";       shift 2 ;;
    --pr)     need_value "$1" ${2+"$2"}; pr_number="$2"; shift 2 ;;
    --watch-id)
              need_value "$1" ${2+"$2"}; requested_watch_id="$2"; shift 2 ;;
    --ready-fd)
              need_value "$1" ${2+"$2"}; ready_fd="$2"; shift 2 ;;
    --once)   once=1; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'pr-watch: unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

[[ "${BOXLITE_PR_WATCH:-1}" == "0" ]] && exit 0

interval="${PR_WATCH_INTERVAL:-$DEFAULT_INTERVAL}"
idle_timeout="${PR_WATCH_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}"
max_lifetime="${PR_WATCH_MAX_LIFETIME:-$DEFAULT_MAX_LIFETIME}"
command_timeout="${PR_WATCH_COMMAND_TIMEOUT:-$DEFAULT_COMMAND_TIMEOUT}"
if ! watch_positive_decimal_is_bounded "$interval" \
   || ! watch_positive_decimal_is_bounded "$idle_timeout" \
   || ! watch_nonnegative_decimal_is_bounded "$max_lifetime"; then
  printf 'pr-watch: polling limits must be integers (lifetime may be zero)\n' >&2
  exit 2
fi
if ! watch_positive_decimal_is_bounded "$command_timeout"; then
  printf 'pr-watch: command timeout must be a positive integer\n' >&2
  exit 2
fi
if (( interval > HARD_MAX_INTERVAL )); then
  printf 'pr-watch: polling interval exceeds hard maximum %d\n' \
    "$HARD_MAX_INTERVAL" >&2
  exit 2
fi
if (( command_timeout > HARD_COMMAND_TIMEOUT )); then
  printf 'pr-watch: command timeout exceeds hard maximum %d\n' \
    "$HARD_COMMAND_TIMEOUT" >&2
  exit 2
fi
started=$SECONDS
lifetime_deadline=0
if (( max_lifetime > 0 )); then
  lifetime_deadline=$((started + max_lifetime))
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
state_dir="$(git -C "$repo_root" rev-parse --git-path pr-watch 2>/dev/null || echo "$repo_root/.git/pr-watch")"
[[ "$state_dir" != /* ]] && state_dir="$repo_root/$state_dir"
mkdir -p "$state_dir" 2>/dev/null || {
  printf 'pr-watch: cannot create state directory\n' >&2
  exit 1
}
state_dir_identity="$(pr_watch_state_directory_identity "$state_dir" 2>/dev/null)" || {
  printf 'pr-watch: state directory is not a stable directory\n' >&2
  exit 1
}

# Slug from the remote URL rather than `gh repo view` — deterministic, offline,
# and correct before the push has landed.
repo_slug() {
  local url
  url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || echo '')"
  case "$url" in
    git@*:*)      printf '%s' "${url#*:}" ;;
    https://*|ssh://*) printf '%s' "${url#*://*/}" ;;
    *)            printf '%s' "$url" ;;
  esac | sed 's/\.git$//'
}
slug="$(repo_slug)"

if [[ -z "$branch" && -n "$pr_number" ]]; then
  branch="pr-${pr_number}"
fi
if [[ -z "$branch" ]]; then
  printf 'pr-watch: need --branch or --pr\n' >&2
  usage 1
fi

command -v gh >/dev/null 2>&1 || { printf 'pr-watch: gh not found\n' >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { printf 'pr-watch: jq not found\n' >&2; exit 127; }
command -v shasum >/dev/null 2>&1 || { printf 'pr-watch: shasum not found\n' >&2; exit 127; }
if [[ -n "$requested_watch_id" ]] && ! pr_watch_id_is_valid "$requested_watch_id"; then
  printf 'pr-watch: invalid watch-id\n' >&2
  exit 2
fi
if [[ -n "$ready_fd" && "$ready_fd" != "9" ]]; then
  printf 'pr-watch: ready-fd must be inherited descriptor 9\n' >&2
  exit 2
fi

branch_key="$(pr_watch_branch_key "$branch")" || {
  printf 'pr-watch: cannot derive state identity for branch\n' >&2
  exit 1
}
event_log="$state_dir/${branch_key}.jsonl"
seen_file="$state_dir/${branch_key}.seen"
lock_dir="$state_dir/${branch_key}.lock"
lock_owner="$lock_dir/owner.json"
lock_identity=""
lock_start_token=""
if ! pr_watch_prepare_regular_file "$event_log" "$state_dir_identity" \
    || ! pr_watch_prepare_regular_file "$seen_file" "$state_dir_identity"; then
  printf 'pr-watch: event state is not a stable regular file\n' >&2
  exit 1
fi

watch_id="$requested_watch_id"
if [[ -z "$watch_id" ]]; then
  watch_id="$(pr_watch_new_id "$state_dir" "$branch_key")" || {
    printf 'pr-watch: cannot allocate watch generation\n' >&2
    exit 1
  }
fi

announce_ready() {  # generation-id
  [[ "$ready_fd" == "9" ]] || return 0
  printf '%s\n' "$1" 2>/dev/null >&9 || true
  exec 9>&-
  ready_fd=""
}

# One atomic owner record binds PID reuse, generation readiness, and lock
# ownership. Readers select it through the bounded regular-state primitive, so
# crash-left FIFOs/symlinks cannot block a later push.
rewrite_lock_owner_exact() {  # mode directory-identity owner-state owner-identity owner-hash body
  perl -MFcntl=:DEFAULT,:flock -MDigest::SHA -MIO::Handle -MJSON::PP=decode_json -e '
    my ($mode, $directory, $expected_directory, $owner_state,
        $expected_owner, $expected_hash, $replacement,
        $self_pid, $self_token, $self_watch_id) = @ARGV;
    my $max = 65536;
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless $mode =~ /\A(?:initial|stale|owned|release)\z/
      && $expected_directory =~ /\A[0-9]+:[0-9]+\z/
      && $owner_state =~ /\A(?:absent|regular|owned)\z/
      && $self_pid =~ /\A[1-9][0-9]*\z/
      && $self_token =~ /\Acksum-[0-9]+-[0-9]+\z/
      && $self_watch_id =~ /\Awatch-[0-9a-f]{24}\z/
      && length($replacement) > 0 && length($replacement) <= 4096
      && $replacement !~ /[\0\r\n]/;

    # chdir pins relative owner.json operations to the selected directory inode.
    # Replacing the public pathname can make this update fail, but cannot redirect
    # the mutation into the replacement directory.
    chdir($directory) or exit 1;
    my @directory_opened = stat(".");
    my @directory_named = lstat($directory);
    exit 1 unless @directory_opened && @directory_named && -d "."
      && ($directory_opened[0] . ":" . $directory_opened[1]) eq $expected_directory
      && $directory_opened[0] == $directory_named[0]
      && $directory_opened[1] == $directory_named[1];

    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    my $created = 0;
    my $fh;
    if ($owner_state eq "absent") {
      exit 1 unless $mode eq "initial" || $mode eq "stale";
      $flags |= O_CREAT | O_EXCL;
      sysopen($fh, "owner.json", $flags, 0600) or exit 1;
      $created = 1;
    } else {
      exit 1 if lstat("owner.json") && -l _;
      sysopen($fh, "owner.json", $flags) or exit 1;
    }
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @owner_opened = stat($fh);
    my @owner_named = lstat("owner.json");
    exit 1 unless @owner_opened && @owner_named && -f $fh
      && $owner_opened[3] == 1
      && $owner_opened[0] == $owner_named[0]
      && $owner_opened[1] == $owner_named[1]
      && $owner_opened[7] <= $max;

    if (!$created) {
      exit 1 unless $owner_state eq "regular" || $owner_state eq "owned";
      exit 1 unless $expected_owner =~ /\A[0-9]+:[0-9]+\z/
        && ($owner_opened[0] . ":" . $owner_opened[1]) eq $expected_owner;
      my $body = "";
      while (length($body) <= $max) {
        my $chunk = "";
        my $count = sysread($fh, $chunk, $max + 1 - length($body));
        next if !defined($count) && $!{EINTR};
        exit 1 unless defined($count);
        last if $count == 0;
        $body .= $chunk;
      }
      exit 1 if length($body) > $max || $body =~ /[\0\r]/;
      $body =~ s/\n\z//;
      if ($owner_state eq "regular") {
        exit 1 unless $mode eq "stale"
          && $expected_hash =~ /\A[0-9a-f]{64}\z/
          && Digest::SHA::sha256_hex($body) eq $expected_hash;
      } else {
        exit 1 unless $mode eq "owned" || $mode eq "release";
        my $decoded = eval { decode_json($body) };
        exit 1 if $@
          || ref($decoded) ne "HASH"
          || !exists($decoded->{schema}) || $decoded->{schema} != 1
          || !exists($decoded->{pid}) || $decoded->{pid} != $self_pid
          || !exists($decoded->{start_token})
          || $decoded->{start_token} ne $self_token
          || !exists($decoded->{watch_id})
          || $decoded->{watch_id} ne $self_watch_id;
      }
    }

    @directory_named = lstat($directory);
    exit 1 unless @directory_named
      && $directory_opened[0] == $directory_named[0]
      && $directory_opened[1] == $directory_named[1];
    truncate($fh, 0) or exit 1;
    sysseek($fh, 0, 0) or exit 1;
    my $record = $replacement . "\n";
    my $offset = 0;
    while ($offset < length($record)) {
      my $written = syswrite($fh, $record, length($record) - $offset, $offset);
      next if !defined($written) && $!{EINTR};
      exit 1 unless defined($written) && $written > 0;
      $offset += $written;
    }
    $fh->sync or exit 1;
    @owner_opened = stat($fh);
    @owner_named = lstat("owner.json");
    @directory_named = lstat($directory);
    exit 1 unless @owner_opened && @owner_named && @directory_named
      && $owner_opened[3] == 1
      && $owner_opened[0] == $owner_named[0]
      && $owner_opened[1] == $owner_named[1]
      && $owner_opened[7] == length($record)
      && $directory_opened[0] == $directory_named[0]
      && $directory_opened[1] == $directory_named[1];
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$lock_dir" "$2" "$3" "$4" "$5" "$6" \
    "$$" "$lock_start_token" "$watch_id"
}

write_lock_owner() {  # ready-boolean
  local ready="$1" owner_identity record
  owner_identity="$(verdict_audit_path_identity "$lock_owner" 2>/dev/null)" \
    || return 1
  record="$(jq -nc --argjson pid "$$" --arg start_token "$lock_start_token" \
    --arg watch_id "$watch_id" --argjson ready "$ready" \
    '{schema:1,pid:$pid,start_token:$start_token,watch_id:$watch_id,ready:$ready}')" \
    || return 1
  rewrite_lock_owner_exact owned "$lock_identity" owned "$owner_identity" "" \
    "$record"
}

read_live_lock() {
  local selected_identity snapshot body owner_pid owner_token current_token active_watch_id is_ready
  local owner_identity owner_identity_after
  lock_observed_directory=""
  lock_observed_owner_state=""
  lock_observed_owner_identity=""
  lock_observed_owner_hash=""
  selected_identity="$(verdict_audit_path_identity "$lock_dir" 2>/dev/null)" || return 2
  if ! owner_identity="$(verdict_audit_path_identity "$lock_owner" 2>/dev/null)"; then
    [[ ! -e "$lock_owner" && ! -L "$lock_owner" ]] || return 2
    verdict_audit_selected_identity_matches "$lock_dir" "$selected_identity" \
      2>/dev/null || return 2
    lock_observed_directory="$selected_identity"
    lock_observed_owner_state=absent
    return 1
  fi
  snapshot="$(verdict_audit_read_json_snapshot "$lock_owner" 2>/dev/null)" || return 2
  owner_identity_after="$(verdict_audit_path_identity "$lock_owner" 2>/dev/null)" \
    || return 2
  [[ "$owner_identity_after" == "$owner_identity" ]] || return 2
  verdict_audit_selected_identity_matches "$lock_dir" "$selected_identity" \
    2>/dev/null || return 2
  if [[ "$snapshot" == *$'\n'* ]]; then
    body="${snapshot#*$'\n'}"
  else
    # An owner created immediately before a crash is a valid empty regular
    # record. Command substitution removes the snapshot separator in that one
    # case; hash the actual empty body so stale reuse can recover it exactly.
    body=""
  fi
  lock_observed_directory="$selected_identity"
  lock_observed_owner_state=regular
  lock_observed_owner_identity="$owner_identity"
  lock_observed_owner_hash="$(LC_ALL=C printf '%s' "$body" \
    | shasum -a 256 | awk '{print $1}')" || return 2
  [[ "$lock_observed_owner_hash" =~ ^[0-9a-f]{64}$ ]] || return 2
  printf '%s' "$body" | jq -e '
    type == "object" and (keys | sort) == ["pid","ready","schema","start_token","watch_id"]
    and .schema == 1
    and (.pid | type == "number" and . > 0 and floor == .)
    and (.start_token | type == "string" and test("^cksum-[0-9]+-[0-9]+$"))
    and (.watch_id | type == "string" and test("^watch-[0-9a-f]{24}$"))
    and (.ready | type == "boolean")' >/dev/null 2>&1 || return 1
  owner_pid="$(printf '%s' "$body" | jq -r '.pid')"
  owner_token="$(printf '%s' "$body" | jq -r '.start_token')"
  current_token="$(verdict_audit_process_start_token "$owner_pid" 2>/dev/null)" || return 1
  [[ "$current_token" == "$owner_token" ]] || return 1
  active_watch_id="$(printf '%s' "$body" | jq -r '.watch_id')"
  is_ready="$(printf '%s' "$body" | jq -r '.ready')"
  [[ "$is_ready" == "true" ]] && announce_ready "$active_watch_id"
  return 0
}

lock_owner_matches_self() {
  local snapshot body
  snapshot="$(verdict_audit_read_json_snapshot "$lock_owner" 2>/dev/null)" || return 1
  body="${snapshot#*$'\n'}"
  printf '%s' "$body" | jq -e --argjson pid "$$" \
    --arg start_token "$lock_start_token" --arg watch_id "$watch_id" '
      type == "object"
      and (keys | sort) == ["pid","ready","schema","start_token","watch_id"]
      and .schema == 1 and .pid == $pid
      and .start_token == $start_token and .watch_id == $watch_id
      and (.ready | type == "boolean")' >/dev/null 2>&1
}

remove_lock_identity() {  # expected-device:inode stale|release
  local expected="$1" mode="$2" record owner_identity owner_state owner_hash
  verdict_audit_selected_identity_matches "$lock_dir" "$expected" \
    2>/dev/null || return 1
  if [[ "$mode" == release ]]; then
    owner_identity="$(verdict_audit_path_identity "$lock_owner" 2>/dev/null)" \
      || return 1
    rewrite_lock_owner_exact release "$expected" owned "$owner_identity" "" \
      retired
    return
  fi
  [[ "$mode" == stale && "$expected" == "$lock_observed_directory" ]] \
    || return 1
  owner_state="$lock_observed_owner_state"
  owner_identity="$lock_observed_owner_identity"
  owner_hash="$lock_observed_owner_hash"
  lock_start_token="$(verdict_audit_process_start_token "$$" 2>/dev/null)" \
    || return 1
  record="$(jq -nc --argjson pid "$$" --arg start_token "$lock_start_token" \
    --arg watch_id "$watch_id" \
    '{schema:1,pid:$pid,start_token:$start_token,watch_id:$watch_id,ready:false}')" \
    || return 1
  rewrite_lock_owner_exact stale "$expected" "$owner_state" "$owner_identity" \
    "$owner_hash" "$record" || return 1
  lock_identity="$expected"
}

release_lock() {
  [[ -n "$lock_identity" ]] || return 0
  if lock_owner_matches_self \
      && verdict_audit_selected_identity_matches "$lock_dir" "$lock_identity" \
        2>/dev/null; then
    remove_lock_identity "$lock_identity" release || true
  fi
  lock_identity=""
}

claim_new_lock() {
  mkdir "$lock_dir" 2>/dev/null || return 1
  lock_identity="$(verdict_audit_path_identity "$lock_dir" 2>/dev/null)" || return 1
  lock_start_token="$(verdict_audit_process_start_token "$$" 2>/dev/null)" || {
    release_lock
    return 1
  }
  local record
  record="$(jq -nc --argjson pid "$$" --arg start_token "$lock_start_token" \
    --arg watch_id "$watch_id" \
    '{schema:1,pid:$pid,start_token:$start_token,watch_id:$watch_id,ready:false}')" \
    || return 1
  rewrite_lock_owner_exact initial "$lock_identity" absent "" "" "$record" || {
    release_lock
    return 1
  }
}

acquire_lock() {
  local stale_identity live_status
  claim_new_lock && return 0
  read_live_lock
  live_status=$?
  (( live_status == 0 )) && return 1
  (( live_status == 1 )) || return 1
  stale_identity="$lock_observed_directory"
  remove_lock_identity "$stale_identity" stale
}
acquire_lock || exit 0

# One branch lock owns one live generation. Retire the previous journal and bound
# the persistent de-dup ledger only after that lock is acquired: duplicate
# producers cannot mutate active state, while readers that still hold an ended
# journal's inode fail closed on the byte regression. Small de-dup ledgers survive
# restarts; an oversized one keeps only its newest complete records. The no-follow
# descriptor and before/after identity checks keep pathname replacement from
# redirecting either rewrite.
retire_generation_file() {  # path retained-tail-bytes (0 truncates)
  perl -MFcntl=:DEFAULT,:flock -MFile::Basename=dirname -MIO::Handle -e '
    my ($path, $parent_identity, $retain) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 2;
    exit 1 unless $parent_identity =~ /\A[0-9]+:[0-9]+\z/
      && $retain =~ /\A(?:0|[1-9][0-9]*)\z/;
    my $parent = dirname($path);
    my @parent_before = lstat($parent);
    exit 1 unless @parent_before && -d _ && !-l _
      && ($parent_before[0] . ":" . $parent_before[1]) eq $parent_identity;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $body = "";
    if ($retain > 0 && $opened[7] > $retain) {
      sysseek($fh, $opened[7] - $retain, 0) or exit 1;
      while (length($body) < $retain) {
        my $chunk = "";
        my $count = sysread($fh, $chunk, $retain - length($body));
        exit 1 unless defined($count);
        last if $count == 0;
        $body .= $chunk;
      }
      $body =~ s/\A[^\n]*\n//;
      exit 1 if $body =~ /[\0\r]/ || ($body ne "" && $body !~ /\n\z/);
    }
    if ($retain == 0 || $opened[7] > $retain) {
      truncate($fh, 0) or exit 1;
      sysseek($fh, 0, 0) or exit 1;
      my $offset = 0;
      while ($offset < length($body)) {
        my $written = syswrite($fh, $body, length($body) - $offset, $offset);
        exit 1 unless defined($written) && $written > 0;
        $offset += $written;
      }
      $fh->sync or exit 1;
    }
    @opened = stat($fh);
    @named = lstat($path);
    my @parent_after = lstat($parent);
    exit 1 unless @opened && @named && @parent_after && -f $fh
      && $opened[3] == 1 && $opened[7] <= $retain
      && $opened[0] == $named[0] && $opened[1] == $named[1]
      && -d $parent && !-l $parent
      && ($parent_after[0] . ":" . $parent_after[1]) eq $parent_identity;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$state_dir_identity" "$2"
}
if ! retire_generation_file "$event_log" 0 \
   || ! retire_generation_file "$seen_file" "$SEEN_RETAIN_MAX_BYTES"; then
  printf 'pr-watch: cannot reset generation state safely\n' >&2
  release_lock
  exit 1
fi
journal_bytes=0
watch_generation_started=0
watch_generation_ended=0

# Network commands run in a dedicated process group, never hidden inside command
# substitutions. Bash defers a TERM trap while an untracked foreground child is
# stuck; the owned group lets cancellation and the per-call deadline terminate
# and reap the command plus any descendants.
active_external_pid=0
active_external_pgid=0
active_external_timeout_pid=0
active_external_limit_pid=0
external_launch_in_progress=0
pending_external_signal_status=0
pending_external_signal_name=""
external_output=""
# Bookkeeping monitors have no shutdown work. Kill them unconditionally before
# waiting: TERM alone can leave a monitor alive and block cleanup.
terminate_external() {
  local pid="$active_external_pid" pgid="$active_external_pgid"
  local timeout_pid="$active_external_timeout_pid"
  local limit_pid="$active_external_limit_pid" grace=10 is_alive
  active_external_pid=0
  active_external_pgid=0
  active_external_timeout_pid=0
  active_external_limit_pid=0
  if [[ "$timeout_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
  fi
  if [[ "$limit_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$limit_pid" 2>/dev/null || true
    wait "$limit_pid" 2>/dev/null || true
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if [[ "$pgid" == "$pid" ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
  fi
  # If TERM arrived before the child established its group, the direct signal
  # still closes that narrow startup race.
  kill -TERM "$pid" 2>/dev/null || true
  while (( grace > 0 )); do
    is_alive=0
    if [[ "$pgid" == "$pid" ]]; then
      kill -0 -- "-$pgid" 2>/dev/null && is_alive=1
    else
      kill -0 "$pid" 2>/dev/null && is_alive=1
    fi
    (( is_alive )) || break
    sleep 0.1
    grace=$((grace - 1))
  done
  if [[ "$pgid" == "$pid" ]]; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exec 8>&- || true
}

start_external_group() {  # timeout-seconds command...
  local effective_timeout="$1"
  local target_identity
  shift
  external_launch_in_progress=1
  perl -MPOSIX -e '
    POSIX::setpgid(0, 0) == 0 or exit 125;
    my ($limit_kib, @command) = @ARGV;
    exit 125 unless $limit_kib =~ /\A[1-9][0-9]*\z/ && @command;
    exec {"bash"} "bash", "-c", q{
      limit_kib="$1"
      shift
      current_limit="$(ulimit -S -f)" || exit 125
      case "$current_limit" in
        unlimited) ulimit -S -f "$limit_kib" || exit 125 ;;
        ""|*[!0-9]*) exit 125 ;;
        *)
          if (( current_limit > limit_kib )); then
            ulimit -S -f "$limit_kib" || exit 125
          fi
          ;;
      esac
      exec "$@"
    }, "pr-watch-output-limit", $limit_kib, @command;
    exit 127;
  ' "$EXTERNAL_OUTPUT_MAX_KIB" "$@" >&8 2>/dev/null &
  active_external_pid=$!
  # The wrapper makes its own PID the process-group id before exec. Recording
  # that identity immediately also leaves terminate_external a direct-PID
  # fallback if a signal wins the tiny pre-setpgid startup race.
  active_external_pgid=$active_external_pid
  target_identity="$(ps -p "$active_external_pid" -o ppid= -o lstart= \
    2>/dev/null)" || target_identity=""
  if [[ -z "$target_identity" ]]; then
    terminate_external
    finish_external_launch
    return 125
  fi
  perl -e '
    my ($seconds, $pid, $parent, $expected) = @ARGV;
    sub target_is_current {
      open(my $state, "-|", "ps", "-p", $pid, "-o", "ppid=", "-o", "lstart=")
        or return 0;
      local $/;
      my $current = <$state>;
      close($state) or return 0;
      return 0 unless defined($current);
      $current =~ s/[\r\n]+\z//;
      return $current eq $expected && $current =~ /^\s*\Q$parent\E\s+/;
    }
    select undef, undef, undef, $seconds;
    exit 0 unless target_is_current();
    kill "TERM", -$pid;
    select undef, undef, undef, 1;
    exit 0 unless target_is_current();
    kill "KILL", -$pid;
  ' "$effective_timeout" "$active_external_pid" "$$" "$target_identity" \
    >/dev/null 2>&1 &
  active_external_timeout_pid=$!
  # RLIMIT_FSIZE is the synchronous write boundary. This independent monitor
  # turns reaching that boundary into immediate process-group cancellation,
  # including commands that ignore SIGXFSZ or spin on EFBIG.
  perl -e '
    my ($max_bytes, $pid, $parent, $expected) = @ARGV;
    $SIG{TERM} = sub { exit 0 };
    exit 125 unless $max_bytes =~ /\A[1-9][0-9]*\z/
      && $pid =~ /\A[1-9][0-9]*\z/
      && $parent =~ /\A[1-9][0-9]*\z/;
    sub target_is_current {
      open(my $state, "-|", "ps", "-p", $pid, "-o", "ppid=", "-o", "lstart=")
        or return 0;
      local $/;
      my $current = <$state>;
      close($state) or return 0;
      return 0 unless defined($current);
      $current =~ s/[\r\n]+\z//;
      return $current eq $expected && $current =~ /^\s*\Q$parent\E\s+/;
    }
    while (1) {
      my @state = stat(STDIN);
      exit 125 unless @state && -f STDIN;
      if ($state[7] >= $max_bytes) {
        exit 0 unless target_is_current();
        kill "TERM", -$pid;
        select undef, undef, undef, 1;
        exit 0 unless target_is_current();
        kill "KILL", -$pid;
        exit 42;
      }
      exit 0 unless kill 0, $pid;
      select undef, undef, undef, 0.01;
    }
  ' "$EXTERNAL_OUTPUT_MAX_BYTES" "$active_external_pid" "$$" \
    "$target_identity" <&8 \
    >/dev/null 2>&1 &
  active_external_limit_pid=$!
  finish_external_launch
}

stop_external_timeout() {
  local timeout_pid="$active_external_timeout_pid"
  active_external_timeout_pid=0
  if [[ "$timeout_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true
  fi
}

stop_external_limit() {
  local limit_pid="$active_external_limit_pid"
  active_external_limit_pid=0
  if [[ "$limit_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$limit_pid" 2>/dev/null || true
    wait "$limit_pid" 2>/dev/null || true
  fi
}

interruptible_pause() {  # whole seconds
  local status=0
  external_launch_in_progress=1
  perl -e 'select undef, undef, undef, $ARGV[0]' "$1" &
  active_external_pid=$!
  active_external_pgid=0
  active_external_timeout_pid=0
  active_external_limit_pid=0
  finish_external_launch
  wait "$active_external_pid" || status=$?
  active_external_pid=0
  return "$status"
}

bounded_watch_deadline() {  # requested-absolute-seconds
  local requested="$1"
  if (( lifetime_deadline > 0 && lifetime_deadline < requested )); then
    printf '%s' "$lifetime_deadline"
  else
    printf '%s' "$requested"
  fi
}

interruptible_pause_until() {  # requested-seconds absolute-deadline
  local requested="$1" deadline="$2" remaining pause
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || return 1
  pause="$requested"
  (( pause <= remaining )) || pause="$remaining"
  interruptible_pause "$pause"
}

capture_external_impl() {  # absolute-deadline-or-zero command...
  local requested_deadline="$1"
  shift
  local output_path output_identity status=0 output_size pid pgid
  local effective_deadline="$requested_deadline" remaining effective_timeout
  external_output=""
  if (( lifetime_deadline > 0 \
        && (effective_deadline == 0 || lifetime_deadline < effective_deadline) )); then
    effective_deadline="$lifetime_deadline"
  fi
  effective_timeout="$command_timeout"
  if (( effective_deadline > 0 )); then
    remaining=$((effective_deadline - SECONDS))
    (( remaining > 0 )) || return 124
    (( effective_timeout <= remaining )) || effective_timeout="$remaining"
  fi
  output_path="$(mktemp "$state_dir/.external-output.XXXXXX" 2>/dev/null)" \
    || return 1
  exec 8<> "$output_path" || {
    rm -f "$output_path" 2>/dev/null || true
    return 1
  }
  output_identity="$(verdict_audit_path_identity "$output_path" 2>/dev/null)" || {
    exec 8>&-
    rm -f "$output_path" 2>/dev/null || true
    return 1
  }
  verdict_audit_unlink_if_identity "$output_path" "$output_identity" \
    2>/dev/null || {
      exec 8>&-
      return 1
    }
  start_external_group "$effective_timeout" "$@"
  status=$?
  if (( status != 0 )); then
    exec 8>&-
    return "$status"
  fi
  pid="$active_external_pid"
  pgid="$active_external_pgid"
  wait "$pid" || status=$?
  stop_external_timeout
  stop_external_limit
  active_external_pid=0
  active_external_pgid=0
  # A command that daemonized a descendant cannot leave it behind after the
  # leader exits. Its owned group is still unambiguously this invocation here.
  if kill -0 -- "-$pgid" 2>/dev/null; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    sleep 0.1
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  output_size="$(perl -e '
    my @state = stat(STDIN);
    exit 1 unless @state && -f STDIN;
    print $state[7];
  ' <&8 2>/dev/null)" || output_size=""
  if [[ ! "$output_size" =~ ^[0-9]+$ \
     || "$output_size" -ge "$EXTERNAL_OUTPUT_MAX_BYTES" ]]; then
    exec 8>&-
    return 1
  fi
  perl -e 'sysseek(STDIN, 0, 0) or exit 1' <&8 || {
    exec 8>&-
    return 1
  }
  external_output="$(cat <&8)"
  exec 8>&-
  return "$status"
}

capture_external() {  # command...
  capture_external_impl 0 "$@"
}

capture_external_until() {  # absolute-deadline command...
  local requested_deadline="$1"
  shift
  capture_external_impl "$requested_deadline" "$@"
}

# Signal traps must exit explicitly. A bare `trap '<cleanup>' TERM` runs the
# handler and then RESUMES the loop — the daemon would survive every kill short
# of SIGKILL, and each push would leave another one running.
signal_shutdown() {  # exit-status signal-name
  local status="$1" signal_name="$2"
  if (( external_launch_in_progress )); then
    if (( pending_external_signal_status == 0 )); then
      pending_external_signal_status="$status"
      pending_external_signal_name="$signal_name"
    fi
    return 0
  fi
  trap '' TERM INT
  terminate_external
  if (( watch_generation_started && ! watch_generation_ended )); then
    emit watch_end reason "watcher terminated by ${signal_name}" || true
  fi
  release_lock
  exit "$status"
}

finish_external_launch() {
  local status signal_name
  external_launch_in_progress=0
  (( pending_external_signal_status != 0 )) || return 0
  status="$pending_external_signal_status"
  signal_name="$pending_external_signal_name"
  pending_external_signal_status=0
  pending_external_signal_name=""
  signal_shutdown "$status" "$signal_name"
}
trap 'terminate_external; release_lock' EXIT
trap 'signal_shutdown 143 TERM' TERM
trap 'signal_shutdown 130 INT' INT

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One event = one line of JSON on stdout and in the log. jq builds it so bodies
# with quotes/newlines can't corrupt the stream.
emit() {
  local kind="$1"; shift
  local line line_bytes sync=0 journal_full=0
  line="$(jq -nc \
    --arg ts "$(now_iso)" \
    --arg kind "$kind" \
    --arg pr "$pr_number" \
    --arg branch "$branch" \
    --arg watch_id "$watch_id" \
    --args '$ARGS.positional
            | ($ARGS.positional | length) as $n
            | reduce range(0; $n; 2) as $i ({}; .[$ARGS.positional[$i]] = $ARGS.positional[$i+1])
            | {ts:$ts, kind:$kind, watch_id:$watch_id, pr:$pr, branch:$branch} + .' \
    "$@" 2>/dev/null)" || {
      printf 'pr-watch: cannot encode %s event\n' "$kind" >&2
      exit 1
    }
  [[ -n "$line" ]] || {
    printf 'pr-watch: cannot encode %s event\n' "$kind" >&2
    exit 1
  }
  line_bytes="$(LC_ALL=C printf '%s\n' "$line" | wc -c | tr -d ' ')"
  [[ "$line_bytes" =~ ^[1-9][0-9]*$ ]] || {
    printf 'pr-watch: cannot measure %s event\n' "$kind" >&2
    exit 1
  }
  if [[ "$kind" != "watch_end" ]] \
     && (( journal_bytes + line_bytes \
           > JOURNAL_MAX_BYTES - JOURNAL_TERMINAL_RESERVE_BYTES )); then
    kind="watch_end"
    journal_full=1
    line="$(jq -nc --arg ts "$(now_iso)" --arg kind "$kind" \
      --arg pr "$pr_number" --arg branch "$branch" --arg watch_id "$watch_id" \
      --arg reason "journal capacity reached; start a new watch generation" \
      '{ts:$ts,kind:$kind,watch_id:$watch_id,pr:$pr,branch:$branch,reason:$reason}' \
      2>/dev/null)" || exit 1
    line_bytes="$(LC_ALL=C printf '%s\n' "$line" | wc -c | tr -d ' ')"
  fi
  if [[ ! "$line_bytes" =~ ^[1-9][0-9]*$ ]] \
     || (( journal_bytes + line_bytes > JOURNAL_MAX_BYTES )); then
    printf 'pr-watch: generation journal capacity exhausted\n' >&2
    exit 1
  fi
  [[ "$kind" == "watch_start" ]] && sync=1
  pr_watch_append_regular_line "$event_log" "$state_dir_identity" "$line" "$sync" || {
    printf 'pr-watch: cannot append %s event\n' "$kind" >&2
    exit 1
  }
  journal_bytes=$((journal_bytes + line_bytes))
  if [[ "$kind" == "watch_start" ]]; then
    watch_generation_started=1
  elif [[ "$kind" == "watch_end" ]]; then
    watch_generation_ended=1
  fi
  printf '%s\n' "$line" || exit 1
  (( journal_full )) && exit 0
  return 0
}

seen() {
  local status=0
  pr_watch_regular_file_has_line "$seen_file" "$state_dir_identity" "$1" \
    || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) printf 'pr-watch: seen state is not a stable regular file\n' >&2; exit 1 ;;
  esac
}
mark_seen() {
  pr_watch_append_regular_line "$seen_file" "$state_dir_identity" "$1" || {
    printf 'pr-watch: cannot append seen state\n' >&2
    exit 1
  }
}

# Record/field separators for the rows jq hands to `read`.
#
# NOT a literal tab: bash treats tab as an IFS *whitespace* character, so `read`
# collapses runs of them and every row with an empty field (a check with no
# `workflow`, a comment with no `path`) silently shifts its remaining values one
# column left. US/RS are non-whitespace, so each occurrence delimits exactly one
# field or record.
#
# These also let us drop @tsv entirely. @tsv escapes \n \r \t \\ inside values,
# which then have to be un-escaped — and un-escaping by hand corrupts a backslash
# followed by t, r or n. C:\temp arrives as C:\\temp, and a left-to-right pass
# reads the second backslash plus `t` as an escaped tab, yielding C:\<TAB>emp.
# (C:\dir, a\b and \d+ round-trip intact; only those three letters collide.)
# Emitting raw values between control-character separators means
# nothing is ever escaped, so nothing has to be decoded: review bodies keep their
# real newlines, tabs, quotes, and backslashes.
#
# Residual: a body containing a literal 0x1f/0x1e byte would split a field or
# record. Traded knowingly — those control bytes are far rarer in PR prose than
# the \t / \r / \n sequences the escaping approach corrupted.
readonly FS=$'\037'   # unit separator  — between fields
readonly RS=$'\036'   # record separator — between rows

# $1 is a jq expression producing an ARRAY per row.
rows() { jq -j "$1"' | join("\u001f") + "\u001e"'; }

truncate_body() {
  local body="$1"
  if (( ${#body} > BODY_MAX_CHARS )); then
    printf '%s… [truncated, see url]' "${body:0:$BODY_MAX_CHARS}"
  else
    printf '%s' "$body"
  fi
}

# ── discovery ────────────────────────────────────────────────────────────────

# Wait for the pushed sha to appear on the remote. Arming happens in pre-push,
# i.e. BEFORE the push completes, so polling the PR immediately would race.
wait_for_push_landed() {
  [[ -z "$sha" ]] && return 0
  local deadline
  deadline="$(bounded_watch_deadline "$((SECONDS + 300))")"
  while (( SECONDS < deadline )); do
    local remote_sha
    capture_external_until "$deadline" \
      git -C "$repo_root" ls-remote origin "refs/heads/$branch" || true
    remote_sha="$(printf '%s' "$external_output" | awk '{print $1}')"
    [[ "$remote_sha" == "$sha" ]] && return 0
    interruptible_pause_until 5 "$deadline" || return 1
  done
  emit warn message "pushed sha never appeared on origin/$branch; watching anyway" sha "$sha"
  return 0
}

# A push may precede `gh pr create` by minutes. Polling for the PR to appear is
# what lets one pre-push arm cover PR creation too — no `gh` hook needed.
resolve_pr_number() {
  [[ -n "$pr_number" ]] && return 0
  local deadline found
  deadline="$(bounded_watch_deadline "$((SECONDS + 900))")"
  while (( SECONDS < deadline )); do
    capture_external_until "$deadline" \
      gh pr list --repo "$slug" --head "$branch" --state open \
        --json number --jq '.[0].number // empty' || true
    found="$external_output"
    if [[ "$found" =~ ^[0-9]+$ ]]; then
      pr_number="$found"
      emit pr_found url "https://github.com/$slug/pull/$found"
      return 0
    fi
    (( once )) && return 1
    interruptible_pause_until "$interval" "$deadline" || return 1
  done
  return 1
}

# ── polling ──────────────────────────────────────────────────────────────────

# Emits every check that has left `pending`, including skips, exactly once.
# Matrix jobs share a name in this repo (the `${{ matrix.* }}` expression is not
# expanded in the check name), so `link` is the de-dup discriminator.
poll_checks() {
  local checks
  capture_external gh pr checks "$pr_number" --repo "$slug" \
    --json name,state,bucket,workflow,link || true
  checks="$external_output"
  if ! printf '%s' "$checks" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return 1
  fi

  local total concluded
  total="$(printf '%s' "$checks" | jq 'length')"
  (( total == 0 )) && return 1

  while IFS="$FS" read -r -d "$RS" name bucket state workflow link; do
    [[ -z "$name" ]] && continue
    local key="check:${link:-$name}:${bucket}"
    seen "$key" && continue
    emit check name "$name" bucket "$bucket" state "$state" \
                workflow "$workflow" url "$link"
    mark_seen "$key"
  done < <(printf '%s' "$checks" \
            | rows '.[] | select(.bucket != "pending")
                    | [.name, .bucket, .state, (.workflow // ""), (.link // "")]')

  concluded="$(printf '%s' "$checks" | jq '[.[] | select(.bucket != "pending")] | length')"
  # Key on the identity of the concluded set, not its size. One watcher spans the
  # whole PR, so a re-run or a new push produces a fresh set of job URLs; keying
  # on the count alone would report the first completion and stay silent for
  # every later one, including a run that goes from green to red.
  local done_key
  done_key="checks_done:$(printf '%s' "$checks" \
    | jq -r '[.[] | "\(.link // .name):\(.bucket)"] | sort | join("|")' \
    | shasum -a 256 | awk '{print $1}')"
  if (( concluded == total )) && ! seen "$done_key"; then
    emit checks_done \
      total "$total" \
      failed "$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length')" \
      passed "$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "pass")] | length')" \
      skipped "$(printf '%s' "$checks" | jq '[.[] | select(.bucket == "skipping")] | length')"
    mark_seen "$done_key"
  fi
  return 0
}

# PR state, mergeability, issue comments, and review submissions. Inline review
# threads live in neither of these and are fetched separately below.
#
# Reports the PR state by assigning the global `pr_state`, NOT by echoing it.
# `emit` writes events to stdout, so a caller using `state=$(poll_conversation)`
# would capture every comment and review into that variable instead of letting
# them reach the event stream — they'd survive only in the log file.
poll_conversation() {
  local view
  capture_external gh pr view "$pr_number" --repo "$slug" \
    --json state,comments,reviews,mergeable,headRefOid,baseRefOid || true
  view="$external_output"
  printf '%s' "$view" | jq -e '
    type == "object"
    and (.mergeable == "MERGEABLE"
         or .mergeable == "CONFLICTING"
         or .mergeable == "UNKNOWN")
    and (.headRefOid | type == "string")
    and (.baseRefOid | type == "string")
  ' >/dev/null 2>&1 || return 1

  while IFS="$FS" read -r -d "$RS" id author body url; do
    [[ -z "$id" ]] && continue
    seen "comment:$id" && continue
    emit comment author "$author" body "$(truncate_body "$body")" url "$url"
    mark_seen "comment:$id"
  done < <(printf '%s' "$view" \
            | rows '.comments[]? | [(.id|tostring), (.author.login // "?"), (.body // ""), (.url // "")]')

  while IFS="$FS" read -r -d "$RS" id author review_state body; do
    [[ -z "$id" ]] && continue
    seen "review:$id" && continue
    emit review author "$author" state "$review_state" \
                body "$(truncate_body "$body")" \
                url "https://github.com/$slug/pull/$pr_number"
    mark_seen "review:$id"
  done < <(printf '%s' "$view" \
            | rows '.reviews[]? | [(.id|tostring), (.author.login // "?"), (.state // ""), (.body // "")]')

  # UNKNOWN is a normal transient while GitHub calculates mergeability. Alert
  # only on its authoritative CONFLICTING result, and scope de-duplication to
  # both compared revisions: movement on either side can create a new conflict.
  local mergeability head_sha base_sha conflict_key
  mergeability="$(printf '%s' "$view" | jq -r '.mergeable // "UNKNOWN"')"
  if [[ "$mergeability" == "CONFLICTING" ]]; then
    head_sha="$(printf '%s' "$view" | jq -r '.headRefOid // ""')"
    base_sha="$(printf '%s' "$view" | jq -r '.baseRefOid // ""')"
    conflict_key="conflict:${head_sha}:${base_sha}"
    if ! seen "$conflict_key"; then
      emit conflict head_sha "$head_sha" base_sha "$base_sha" \
                    url "https://github.com/$slug/pull/$pr_number"
      mark_seen "$conflict_key"
    fi
  fi

  pr_state="$(printf '%s' "$view" | jq -r '.state // "OPEN"')"
}

poll_inline_comments() {
  local inline
  capture_external gh api "repos/$slug/pulls/$pr_number/comments?per_page=100" || true
  inline="$external_output"
  printf '%s' "$inline" | jq -e 'type == "array"' >/dev/null 2>&1 || return 0

  while IFS="$FS" read -r -d "$RS" id author path body url; do
    [[ -z "$id" ]] && continue
    seen "inline:$id" && continue
    emit review_comment author "$author" path "$path" \
                        body "$(truncate_body "$body")" url "$url"
    mark_seen "inline:$id"
  done < <(printf '%s' "$inline" \
            | rows '.[] | [(.id|tostring), (.user.login // "?"), (.path // ""), (.body // ""), (.html_url // "")]')
}

# ── main ─────────────────────────────────────────────────────────────────────

# Publish the generation before waiting for the push or PR discovery. A consumer
# attached after `git push` can ignore ended history and wait on this live run.
if ! emit watch_start url "${pr_number:+https://github.com/$slug/pull/$pr_number}" interval "$interval"; then
  printf 'pr-watch: cannot publish watch generation\n' >&2
  exit 1
fi
if ! write_lock_owner true; then
  printf 'pr-watch: cannot publish live watch identity\n' >&2
  exit 1
fi
announce_ready "$watch_id"
wait_for_push_landed

if ! resolve_pr_number; then
  if (( lifetime_deadline > 0 && SECONDS >= lifetime_deadline )); then
    emit watch_end reason "max lifetime ${max_lifetime}s reached before merge"
  else
    emit watch_end reason "no open PR found for branch"
  fi
  exit 0
fi

last_contact=$SECONDS
while :; do
  poll_checks
  poll_inline_comments
  # Cleared each pass: only a successful poll may declare a terminal state, so a
  # failed one leaves this empty and the watch continues.
  pr_state=""
  if poll_conversation; then
    last_contact=$SECONDS
  fi

  if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
    emit watch_end reason "PR ${pr_state}"
    break
  fi

  if (( once )); then
    emit watch_end reason "once complete"
    break
  fi

  # Give up on LOST CONTACT, never on silence. A PR with green CI awaiting human
  # review emits nothing for hours or days; an earlier version measured "time
  # since the last new event" and so stopped watching long before the merge it
  # was supposed to report. A poll that reaches GitHub and confirms the PR is
  # still open IS liveness, even when it yields no new events.
  if (( SECONDS - last_contact >= idle_timeout )); then
    emit watch_end reason "no contact with PR for ${idle_timeout}s"
    break
  fi

  # Absolute backstop so an abandoned PR cannot leak a poller forever.
  if (( max_lifetime > 0 && SECONDS >= lifetime_deadline )); then
    emit watch_end reason "max lifetime ${max_lifetime}s reached before merge"
    break
  fi

  pause_deadline=$((SECONDS + interval))
  contact_deadline=$((last_contact + idle_timeout))
  (( contact_deadline >= pause_deadline )) || pause_deadline="$contact_deadline"
  pause_deadline="$(bounded_watch_deadline "$pause_deadline")"
  interruptible_pause_until "$interval" "$pause_deadline" || true
done
