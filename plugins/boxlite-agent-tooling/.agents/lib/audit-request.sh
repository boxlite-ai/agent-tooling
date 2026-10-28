#!/usr/bin/env bash
# Retain execution by request and Git binding; never grant authority to a new turn.
# Requires verdict-audit-state.sh. No effects until a function is called.
audit_request_tree() { # repository
  local index tree status=0
  index="$(mktemp)" || return 1
  GIT_INDEX_FILE="$index" git -C "$1" read-tree HEAD >/dev/null 2>&1 \
    && GIT_INDEX_FILE="$index" git -C "$1" add -A >/dev/null 2>&1 \
    && tree="$(GIT_INDEX_FILE="$index" git -C "$1" write-tree 2>/dev/null)" || status=$?
  rm -f "$index"
  (( status == 0 )) && [[ "$tree" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s\n' "$tree"
}

audit_request_context_write() { # repository scope exact-request origin-epoch
  local root="$1" scope="$2" request="$3" epoch="$4" branch head tree
  branch="$(git -C "$root" branch --show-current)" \
    && head="$(git -C "$root" rev-parse HEAD)" && tree="$(audit_request_tree "$root")" || return 1
  jq -nc --arg request "$request" --arg epoch "$epoch" --arg branch "$branch" \
    --arg head "$head" --arg tree "$tree" \
    '{request:$request,origin_epoch:$epoch,branch:$branch,head:$head,tree_hash:$tree}' \
    | verdict_audit_write_atomic "$root/.agents/state/verdict-request-context.json.$scope"
}

audit_request_context_read() { # repository scope [identity]; default also validates Git state
  local root="$1" scope="$2" context request generation deadline message extra now branch head tree
  [[ "$scope" =~ ^git-[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  context="$(verdict_audit_read_single_record "$root/.agents/state/verdict-request-context.json.$scope")" \
    && request="$(verdict_audit_read_single_record "$root/.agents/state/verdict-request.$scope")" || return 1
  read -r generation deadline message extra <<< "$request"
  [[ "$generation" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ && "$message" =~ ^cksum-[0-9]+-[0-9]+$ && -z "$extra" ]] || return 1
  verdict_audit_epoch_is_bounded "$deadline" || return 1
  now="$(date +%s)"
  # shellcheck disable=SC2154 # Defined by verdict-audit-state.sh.
  (( now <= deadline && deadline <= now + verdict_audit_lock_max_seconds )) || return 1
  context="$(jq -ce --arg request "$request" '
    select(type == "object" and .request == $request and (.origin_epoch | type == "string") and
      (.origin_epoch | test("^(-|[1-9][0-9]*-[1-9][0-9]*-[0-9]+)$")) and
      (.branch | type == "string") and (.head | test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
      (.tree_hash | test("^[0-9a-f]{40}([0-9a-f]{24})?$")))
  ' <<< "$context")" || return 1
  if [[ "${3:-}" == identity ]]; then printf '%s\n' "$context"; return 0; fi
  ! verdict_audit_cancellation_exists "$(verdict_audit_cancellation_path "$root/.agents/state" "$scope" "$generation")" || return 1
  branch="$(git -C "$root" branch --show-current)" \
    && head="$(git -C "$root" rev-parse HEAD)" && tree="$(audit_request_tree "$root")" || return 1
  jq -ce --arg request "$request" --arg branch "$branch" --arg head "$head" --arg tree "$tree" '
    select(.request == $request and .branch == $branch and .head == $head and .tree_hash == $tree)
  ' <<< "$context"
}

audit_request_context_remove() { # repository scope exact-request
  local path="$1/.agents/state/verdict-request-context.json.$2" body
  body="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || return 0
  jq -e --arg request "$3" '.request == $request' <<< "$body" >/dev/null 2>&1 || return 0
  verdict_audit_remove_record_if_matches "$path" "$body"
}
