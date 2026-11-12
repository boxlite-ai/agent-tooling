#!/usr/bin/env bash
# Private design transaction dispatcher. The public CLI never accepts worker results.
# jq programs deliberately retain their own dollar-prefixed variables.
# shellcheck disable=SC2016
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for library in verdict-audit-state reply-summary concise-writing design-doc; do
  # shellcheck source=/dev/null
  source "$plugin_root/.agents/lib/$library.sh" || exit 2
done
# The dispatcher is entered with the clone-wide transaction already held.
design_doc_binding() { _design_doc_binding "$@"; }

worker_reconcile() { # directory, pending record -> complete interrupted cleanup only
  local pending="$2" snapshot record path
  [[ "$(jq -r .status <<<"$pending")" == pending ]] || return 1
  path="$1/agent-tooling-design-audit.json"
  [[ "$(jq -r .role <<<"$pending")" != advisor ]] || path="$1/agent-tooling-design-advice.json"
  snapshot="$(verdict_audit_read_json_snapshot "$path")" || return 1
  record="${snapshot#*$'\n'}"
  _design_doc_jq -e --argjson pending "$pending" 'include "design-audit";
    da_worker_provenance($pending.role) and .root==$pending.snapshot.root
    and .branch==$pending.snapshot.branch and .url==$pending.snapshot.url
    and .worker_provenance.task_id==$pending.task_id
    and .worker_provenance.task_sha256==$pending.task_sha256
    and .worker_provenance.worker_sha256==$pending.worker_sha256
    and .worker_provenance.snapshot_sha256==$pending.snapshot.snapshot.snapshot_sha256' \
    <<<"$record" >/dev/null || return 1
  jq -c '.status="consumed"' <<<"$pending" |
    verdict_audit_write_atomic "$1/agent-tooling-design-worker.json"
}

worker_snapshot() {
  local root branch directory binding url snapshot state request pending status=0
  root="$(cd "$1" && pwd -P)" || return 1
  branch="$(_design_doc_context "$root")" || return 1
  directory="$(git -C "$root" rev-parse --absolute-git-dir)" || return 1
  if [[ -e "$directory/agent-tooling-design-worker.json" || -L "$directory/agent-tooling-design-worker.json" ]]; then
    pending="$(_design_doc_worker_record "$directory/agent-tooling-design-worker.json")" || return 1
    worker_reconcile "$directory" "$pending" || :
  fi
  binding="$(verdict_audit_read_single_record "$directory/agent-tooling-design-doc.json")" || return 1
  url="$(jq -er --arg root "$root" --arg branch "$branch" \
    'select(keys==["branch","root","url"] and .root==$root and .branch==$branch) | .url' <<<"$binding")" || return 1
  snapshot="$(_design_doc_snapshot "$root" "$url")" || return 1
  state="$(_design_doc_audit_state "$directory/agent-tooling-design-audit.json" "$root" "$branch")" || return 1
  request="$(_design_doc_audit_passed "$directory/agent-tooling-design-audit.json" "$root" "$branch" "$url" \
    "$(jq -r .content_sha256 <<<"$snapshot")" "$(jq -r .snapshot_sha256 <<<"$snapshot")")" || status=$?
  [[ "$status" == 0 || "$status" == 1 ]] || return 1
  [[ -n "$request" ]] || request='{"granted":true}'
  jq -nc --arg root "$root" --arg branch "$branch" --arg url "$url" --arg directory "$directory" \
    --arg head "$(git -C "$root" rev-parse HEAD)" --argjson snapshot "$snapshot" \
    --argjson request "$request" --argjson state "$state" \
    --arg state_hash "$(_design_doc_file_hash "$directory/agent-tooling-design-audit.json")" \
    --arg advice_hash "$(_design_doc_file_hash "$directory/agent-tooling-design-advice.json")" \
    '{root:$root,branch:$branch,url:$url,git_dir:$directory,head:$head,snapshot:$snapshot,
      state:$state,request:$request,state_hash:$state_hash,advice_hash:$advice_hash}'
}

worker_human_decision() { # live capture -> an accepted decision for this exact revision
  local live="$1" path record
  path="$(jq -r .root <<<"$live")/.agents/state/design-decision-request.json"
  [[ -e "$path" || -L "$path" ]] || return 1
  record="$(verdict_audit_read_regular_state "$path" 1048576 record)" || return 2
  jq -e --argjson live "$live" --arg history "$(_design_doc_history_hash "$(jq -c .state <<<"$live")")" '
    .status=="accepted" and .spec.prefix=="design-decision:" and (.spec.binding |
      .root==$live.root and .branch==$live.branch and .head==$live.head
      and .url==$live.url and .content_sha256==$live.snapshot.content_sha256
      and .history_hash==$history)' <<<"$record" >/dev/null
}

worker_transition() {
  # The design library consumes these two dynamically scoped publication inputs.
  # shellcheck disable=SC2034
  local action="$1" root="$2" input live pending directory old path result decision_status=0 design_worker_proof design_worker_deadline
  input="$(head -c 1048577)" || return 1
  (( ${#input} <= 1048576 )) || return 1
  live="$(worker_snapshot "$root")" || return 1
  directory="$(jq -r .git_dir <<<"$live")"
  path="$directory/agent-tooling-design-worker.json"
  worker_human_decision "$live" || decision_status=$?
  if (( decision_status == 0 )); then
    _design_doc_error 'a human design decision takes precedence'; return 1
  fi
  (( decision_status == 1 )) || return 1
  if [[ "$action" == claim ]]; then
    jq -e --argjson live "$live" '.snapshot == $live' <<<"$input" >/dev/null || {
      _design_doc_error 'assignment snapshot changed'; return 1;
    }
    if [[ -e "$path" || -L "$path" ]]; then
      pending="$(_design_doc_worker_record "$path")" || return 1
      jq -e '.expires < now or (.status | IN("consumed","aborted"))' <<<"$pending" >/dev/null || {
        _design_doc_error 'a design worker already owns this assignment'; return 1;
      }
    fi
    jq -e '.request | (.blocked // false | not)
      and (.reflection_due // false | not) and (.redesign // false | not)' <<<"$live" >/dev/null || return 1
    # Retain pre-upgrade outcomes separately; they cannot authorize a new worker.
    if jq -e --argjson input "$input" '.state | ((.verdict=="PASS" or .verdict=="FAIL") and .worker_provenance==null)
        or (.verdict=="PASS" and $input.role=="auditor")' <<<"$live" >/dev/null; then
      old="$(jq -c .state <<<"$live")"
      printf '%s\n' "$old" | verdict_audit_write_atomic "$directory/agent-tooling-design-history-$(jq -r .state_hash <<<"$live").json" || return 1
      _design_doc_jq -c --arg root "$root" --arg branch "$(jq -r .branch <<<"$live")" \
        'include "design-audit"; .state as $old | da_empty($root;$branch) | .overruled=$old.overruled' <<<"$live" |
        verdict_audit_write_atomic "$directory/agent-tooling-design-audit.json" || return 1
      live="$(worker_snapshot "$root")" || return 1
    fi
    jq -c --argjson live "$live" '. + {snapshot:$live,status:"pending"}' <<<"$input" |
      verdict_audit_write_atomic "$path" || return 1
    cat "$path"
    return
  fi
  pending="$(_design_doc_worker_record "$path")" || return 1
  if jq -e --argjson input "$input" '.status=="consumed" and .task_id==$input.task_id' <<<"$pending" >/dev/null; then
    return 0
  fi
  jq -e --argjson live "$live" --argjson input "$input" '
    .status=="pending" and .task_id==$input.task_id and .expires>=now
    and .snapshot==$live and .task_sha256==$input.proof.task_sha256
    and .snapshot.snapshot.snapshot_sha256==$input.proof.snapshot_sha256
    and .worker_sha256==$input.proof.worker_sha256 and .role==$input.proof.role' <<<"$pending" >/dev/null || {
      _design_doc_error 'worker assignment or live content changed'; return 1;
    }
  # shellcheck disable=SC2034
  design_worker_proof="$(jq -c .proof <<<"$input")"
  # shellcheck disable=SC2034
  design_worker_deadline="$(jq -r .review_deadline <<<"$pending")"
  result="$(jq -c .result <<<"$input")"
  # All nested operations share the transaction already held by this dispatcher.
  if [[ "$(jq -r .role <<<"$pending")" == auditor ]]; then
    printf '%s' "$result" | design_doc_audit_record "$root" >/dev/null || return 1
  else
    printf '%s' "$result" | design_doc_advice_record "$root" >/dev/null || return 1
  fi
  jq -c '.status="consumed"' <<<"$pending" | verdict_audit_write_atomic "$path"
}

case "${1:-}" in
  execution)
    directory="$(git -C "$2" rev-parse --absolute-git-dir)" || exit 2
    head -c 65536 | verdict_audit_write_atomic "$directory/agent-tooling-design-worker-execution.json" ;;
  human-reply)
    # shellcheck source=../lib/user-question.sh
    source "$plugin_root/.agents/lib/user-question.sh" || exit 1
    # shellcheck source=../lib/timed-user-prompt.sh
    source "$plugin_root/.agents/lib/timed-user-prompt.sh" || exit 1
    input="$(head -c 1048577)"
    (( ${#input} <= 1048576 )) || exit 1
    state="$2/.agents/state/design-decision-request.json"
    request="$(timed_user_prompt_read "$state")" || exit 1
    directory="$(git -C "$2" rev-parse --absolute-git-dir)" || exit 1
    current="$(_design_doc_audit_state "$directory/agent-tooling-design-audit.json" "$2" "$(_design_doc_context "$2")")" || exit 1
    jq -e --argjson input "$input" --arg root "$2" --arg branch "$(git -C "$2" branch --show-current)" \
      --arg head "$(git -C "$2" rev-parse HEAD)" --arg history "$(_design_doc_history_hash "$current")" '
      .id==$input.id and .spec.prefix=="design-decision:" and (.spec.binding | .root==$root
        and .branch==$branch and .head==$head and .history_hash==$history
        and .session==($input.payload.session_id // ""))' <<<"$request" >/dev/null || {
      printf 'the reply does not match the pending request, session, branch, or HEAD'; exit 1;
    }
    timed_user_prompt prompt-reply "$state" "$(jq -r .id <<<"$input")" "$(jq -r .line <<<"$input")" >/dev/null || exit 1
    printf 'recorded "%s"; the next edit attempt applies it\n' "$(jq -r .line <<<"$input")" ;;
  diagnostics)
    directory="$(git -C "$2" rev-parse --absolute-git-dir)" || exit 2
    head -c 65536 | verdict_audit_write_atomic "$directory/agent-tooling-design-worker-diagnostics.json" ;;
  abort)
    directory="$(git -C "$2" rev-parse --absolute-git-dir)" || exit 2
    input="$(head -c 4096)"
    path="$directory/agent-tooling-design-worker.json"
    pending="$(_design_doc_worker_record "$path")" || exit 2
    jq -ce --argjson input "$input" 'select(.task_id==$input.task_id)
      | if .status=="pending" then .status="aborted" else . end' <<<"$pending" |
      verdict_audit_write_atomic "$path" ;;
  public)
    directory="$(git -C "$2" rev-parse --absolute-git-dir)" || exit 2
    binding="$(verdict_audit_read_single_record "$directory/agent-tooling-design-doc.json")" || exit 2
    jq -ce --arg root "$(cd "$2" && pwd -P)" --arg branch "$(_design_doc_context "$2")" \
      'select(keys==["branch","root","url"] and .root==$root and .branch==$branch) | {url}' <<<"$binding" ;;
  binding) shift; _design_doc_binding "$@" ;;
  log) _design_doc_log_store "$2" ;;
  snapshot) worker_snapshot "$2" ;;
  claim|publish) worker_transition "$1" "$2" ;;
  *) exit 2 ;;
esac
