#!/usr/bin/env bash
# Requires Git. Call inside a child process after capturing the consumer root;
# the parent hook must retain its environment for chained hooks.
tooling_git_clear_repository_environment() {
  local names name
  if ! names="$(git rev-parse --local-env-vars)" || [[ -z "$names" ]]; then
    printf 'agent-tooling: cannot discover repository-local Git environment\n' >&2
    return 1
  fi
  while IFS= read -r name; do
    if [[ ! "$name" =~ ^GIT_[A-Z0-9_]+$ ]]; then
      printf 'agent-tooling: invalid repository-local Git environment variable\n' >&2
      return 1
    fi
    if ! unset "$name"; then
      printf 'agent-tooling: cannot clear repository-local Git environment: %s\n' "$name" >&2
      return 1
    fi
  done <<< "$names"
  # Git omits namespace from --local-env-vars; retain the bootstrap's protection.
  unset GIT_NAMESPACE || {
    printf 'agent-tooling: cannot clear repository-local Git environment: GIT_NAMESPACE\n' >&2
    return 1
  }
}
