#!/usr/bin/env bash
# The one-time nonce that marks an asyncRewake wake as internal: mint it, hash it, and
# recognise it in the prompt Claude Code submits when the hook exits 2.
# Source this file; it performs no work on load. Requires jq, perl, shasum and awk.
#
# The host wraps the hook's stderr, not the envelope, so a marker the hook prints lands
# in the trailing system-reminder. Shape captured from a live Claude Code 2.1.278 session:
#
#   <task-notification>
#   <summary>Stop hook feedback</summary>
#   </task-notification>
#   <system-reminder>
#   Stop hook blocking error from command "<Event>:<match>": <hook stderr>
#
#   </system-reminder>
#
# Only the shape is checked here, not the host's wording inside the reminder: the nonce
# is what authenticates, and a reworded reminder must not turn every wake into a new
# prompt. A wake is internal only while its nonce is unspent, and its owner spends it on
# first acceptance, so a copy of a spent wake is a real prompt. Text after the reminder,
# or a second reminder, means a person's words rode along, and that is a real prompt too.

# Print a fresh 64-hex nonce for a hook's `[<name>:<nonce>]` wake marker.
hook_wake_new_nonce() {
  perl -e '
    open(my $random, "<", "/dev/urandom") or exit 1;
    read($random, my $bytes, 32) == 32 or exit 1;
    print unpack("H*", $bytes);
  '
}

# Print the SHA-256 an owner stores in place of the nonce, so state never holds one.
hook_wake_nonce_hash() {  # nonce
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# Print the 64-hex nonce of the first `[<name>:<nonce>]` marker in a wake's reminder.
hook_wake_marker() {  # prompt marker-name -> nonce on stdout; status 1 when absent
  local prompt="$1" name="$2" nonce
  [[ "$name" =~ ^[a-z][a-z-]{0,31}$ ]] || return 1
  # A capture that misses yields no output, so a wrong shape or a missing marker simply
  # leaves the nonce empty.
  nonce="$(printf '%s' "$prompt" | jq -Rrs --arg name "$name" '
    capture("\\A<task-notification>\\n<summary>[^<\\n]*</summary>\\n</task-notification>\\n<system-reminder>\\n(?<body>[\\s\\S]*)\\n</system-reminder>\\s*\\z").body
    | select((contains("<system-reminder>") or contains("</system-reminder>")) | not)
    | capture("\\[" + $name + ":(?<nonce>[0-9a-f]{64})\\]").nonce
  ' 2>/dev/null)" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$nonce"
}
