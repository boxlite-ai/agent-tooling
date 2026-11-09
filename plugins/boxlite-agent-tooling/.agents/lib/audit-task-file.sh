#!/usr/bin/env bash
# Claim check for commit/push audit text: the gate stores the task, or a
# FAIL's findings, in a file named by its SHA-256 and puts only the path, hash, and size
# in its deny reason, so the reason stays far below the 8,192-byte cap.
# Requires perl and verdict-audit-state.sh. Source only.

# Files older than this many minutes go on each write; audit reports expire at 5 hours.
audit_task_file_max_age_minutes=300

# Writes text under <state dir>/audit-tasks/<sha256>.md and prints {path, sha256, bytes}.
# It rewrites the file on every call, so pruning by age never removes a file a fresh
# deny reason still names.
audit_task_file_write() { # state directory, text -> pointer JSON
  local directory="$1/audit-tasks" text="$2" digest bytes path
  [[ ! -L "$1" && ! -L "$directory" ]] || {
    printf 'audit-task-file: refusing a symlinked state directory: %s\n' "$directory" >&2
    return 1
  }
  mkdir -p "$directory" && chmod 700 "$directory" || return 1
  digest="$(printf '%s' "$text" | verdict_audit_sha256)" || return 1
  bytes="$(LC_ALL=C printf '%s' "$text" | wc -c | tr -d ' ')"
  path="$directory/$digest.md"
  printf '%s' "$text" | verdict_audit_write_atomic "$path" || return 1
  chmod 600 "$path" || return 1
  find "$directory" -maxdepth 1 -type f -name '*.md' ! -name "$digest.md" \
    -mmin "+$audit_task_file_max_age_minutes" -delete 2>/dev/null || true
  jq -nc --arg path "$path" --arg sha "$digest" --argjson bytes "$bytes" \
    '{path:$path, sha256:$sha, bytes:$bytes}'
}
