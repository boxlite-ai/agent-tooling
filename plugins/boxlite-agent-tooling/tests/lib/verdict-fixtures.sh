# shellcheck shell=bash
# Shared fixture helpers for the verdict-audit suites. Source it; loading defines
# functions only. The scope and tree oracles are independent reimplementations, so
# the suites never grade the production path helpers with themselves.

session_scope_of() {  # repo session
  printf 'git-%s' "$(printf '%s' "$2" | git -C "$1" hash-object --stdin)"
}

session_state_path() {  # repo basename session
  printf '%s/.agents/state/%s.%s' "$1" "$2" "$(session_scope_of "$1" "$3")"
}

# The content-addressed tree of the working tree, as the verdict gate binds it.
tree_hash_of() {  # repo
  local repo="$1" idx
  idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree 2>/dev/null
  rm -f "$idx"
}

kill_test_pids() {  # signal pid...
  local signal="$1" pid
  shift
  for pid in "$@"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill "-$signal" "$pid" 2>/dev/null || true
  done
}

process_state() {  # pid -> gone | alive | invalid
  local pid="$1" state
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid'; return; }
  state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$state" || "$state" == Z* ]] && printf 'gone' || printf 'alive'
}
