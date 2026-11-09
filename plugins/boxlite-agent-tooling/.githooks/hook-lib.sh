#!/usr/bin/env bash
# Shared by the Git hooks in this directory. Source it; it performs no work on load.
# Git runs only hooks with Git's own names, so this file is never invoked as a hook.

# Run the PreToolUse commit gate as the Git-level gate and apply its answer.
# Returns 0 to allow (advisories go to stderr), 1 to block with the reason on stderr.
githook_run_delegated_gate() { # gate-script payload-json deny-preamble [NAME=value...]
  local gate="$1" payload="$2" preamble="$3" out decision advisory
  shift 3
  # GITHOOK_DELEGATED tells the gate this call IS the Git-level gate; without it the
  # gate would defer back here and both layers would stand down.
  if ! out="$(printf '%s' "$payload" | env GITHOOK_DELEGATED=1 "$@" bash "$gate" 2>&1)"; then
    printf 'commit-push-auditor delegated preflight failed\n%s\n' "$out" >&2
    return 1
  fi
  [[ -n "$out" ]] || return 0
  if ! decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"; then
    printf 'commit-push-auditor delegated preflight returned invalid output\n%s\n' "$out" >&2
    return 1
  fi
  if [[ "$decision" == deny ]]; then
    printf '%s' "$preamble" >&2
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' >&2
    return 1
  fi
  # Output without a deny is the gate reporting NON-BLOCKING advisories on a passing
  # audit; see validate_audit in preflight-commit-push.sh for the two channels.
  advisory="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  if [[ -z "$advisory" ]]; then
    printf 'commit-push-auditor delegated preflight returned invalid output\n%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$advisory" >&2
}

# Synchronize the installation (best effort), then run the hook of the same name that
# a framework installed beneath the common Git directory. The chained hook's status is
# returned. --git-common-dir, not --git-path: --git-path honors core.hooksPath and
# would resolve to the calling hook itself.
githook_sync_then_chain() { # tooling-root hook-name stdin-file|"" [hook arguments...]
  local tooling_root="$1" name="$2" input="$3" chained
  shift 3
  "$tooling_root/scripts/sync-installation.sh" || true
  chained="$(git rev-parse --git-common-dir)/hooks/$name"
  [[ -x "$chained" && "$(realpath "$chained" 2>/dev/null)" != "$(realpath "$0" 2>/dev/null)" ]] \
    || return 0
  if [[ -n "$input" ]]; then
    "$chained" "$@" < "$input"
  else
    "$chained" "$@"
  fi
}
