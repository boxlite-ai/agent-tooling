#!/usr/bin/env bash
# Shared prompt renderer for Stop and GitHub writing checks. Requires subagent.sh.
# Source only; callers own dependency checks, host delivery and failure policy.

concise_writing_prompt() { # tooling-root
  local prompt
  prompt="$(subagent_prompt concise-writing "$1" max_words=60)" || return $?
  if [[ "$prompt" != *[![:space:]]* ]]; then
    printf 'concise-writing: empty prompt: %s/.agents/prompts/concise-writing.md\n' "$1" >&2
    return 1
  fi
  printf '%s' "$prompt"
}
