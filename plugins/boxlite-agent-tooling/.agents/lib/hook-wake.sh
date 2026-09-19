#!/usr/bin/env bash
# Recognise the prompt Claude Code submits when an asyncRewake hook exits 2.
# Source this file; it performs no work on load. Requires jq.
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
# prompt. A wake is internal only once its owner spends the nonce, so a typed copy of
# this shape is still a real prompt. Text after the reminder, or a second reminder,
# means a person's words rode along, and that is a real prompt too.

# Print the 64-hex nonce of the first `[<name>:<nonce>]` marker in a wake's reminder.
hook_wake_marker() {  # prompt marker-name -> nonce on stdout; status 1 when absent
  local prompt="$1" name="$2" nonce
  [[ "$name" =~ ^[a-z][a-z-]{0,31}$ ]] || return 1
  nonce="$(printf '%s' "$prompt" | jq -Rrs --arg name "$name" '
    (try capture("\\A<task-notification>\\n<summary>[^<\\n]*</summary>\\n</task-notification>\\n<system-reminder>\\n(?<body>[\\s\\S]*)\\n</system-reminder>\\s*\\z").body
     catch null) as $body
    | if $body == null or ($body | contains("<system-reminder>") or contains("</system-reminder>"))
      then empty
      else ($body | capture("\\[" + $name + ":(?<nonce>[0-9a-f]{64})\\]").nonce? // empty)
      end
  ' 2>/dev/null)" || return 1
  [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$nonce"
}
