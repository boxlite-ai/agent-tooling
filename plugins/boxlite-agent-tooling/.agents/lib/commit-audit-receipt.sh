#!/usr/bin/env bash
# Shared receipt state for the commit gate and its push sibling. Source this file;
# it performs no work on load. Requires verdict-audit-state.sh to be sourced first,
# and jq and date on PATH; callers own those checks and all reporting.
#
# .githooks/commit-msg publishes a receipt the moment a commit is proven to have
# passed its own audit, and .githooks/pre-push spends it to skip a push audit that
# would review that identical commit a second time.
#
# A receipt names the commit by IDENTITY — parent plus tree — never by a diff hash.
# Nothing then depends on `git diff --cached` at commit time and `git diff <parent>
# <commit>` at push time producing identical bytes. The subject hash rides along
# because `--amend --no-verify` can put an unaudited message over an unchanged
# parent and tree.
#
# ONE fixed slot, the same convention as last-audit.json beside it, rather than a
# keyed cache: a push can only ever claim the receipt for its own single new commit,
# so at most one is claimable at a time and a newer commit's receipt may simply
# replace an older one. Interleaving commits across branches before pushing either
# therefore loses a receipt — which costs that push an audit, exactly the behavior
# that existed before receipts, and keeps this file free of the key derivation,
# eviction ceiling, and directory sweep a cache would need.
#
# Every failure is silent and non-zero: no receipt simply means the push audits.

# A PASS names an immutable commit object, so it stays true whoever pushes it and
# whenever — the ceiling exists only so a commit audited under a since-changed
# AGENTS.md cannot authorize a push indefinitely.
commit_audit_receipt_max_age_seconds=86400

commit_audit_receipt_is_object_id() {
  [[ "${1-}" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}

commit_audit_receipt_path() {  # repo-root
  [[ -n "${1-}" ]] || return 1
  printf '%s/.agents/state/commit-audit-receipt.json' "$1"
}

commit_audit_receipt_write() {  # repo-root parent tree subject-hash
  local repo="${1-}" parent="${2-}" tree="${3-}" subject_hash="${4-}" path
  commit_audit_receipt_is_object_id "$parent" || return 1
  commit_audit_receipt_is_object_id "$tree" || return 1
  [[ "$subject_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  path="$(commit_audit_receipt_path "$repo")" || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  jq -nc --arg parent "$parent" --arg tree "$tree" \
    --arg subject_hash "$subject_hash" --argjson created_at "$(date +%s)" \
    '{schema:1, parent:$parent, tree:$tree, subject_hash:$subject_hash,
      created_at:$created_at}' \
    | verdict_audit_write_atomic "$path"
}

# One-shot by construction: a receipt that authorizes a push is removed in the same
# call, so a second push of the same commit audits again. The stored parent, tree,
# and subject are checked against the caller's own values, so the receipt left by one
# commit can never authorize a different one.
commit_audit_receipt_claim() {  # repo-root parent tree subject-hash
  local repo="${1-}" parent="${2-}" tree="${3-}" subject_hash="${4-}"
  local path identity snapshot created_at now
  [[ "$subject_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  path="$(commit_audit_receipt_path "$repo")" || return 1
  identity="$(verdict_audit_path_identity "$path" 2>/dev/null)" || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" || return 1
  [[ "$snapshot" == *$'\n'* ]] || return 1
  # One jq pass. The receipt must name THIS commit, and its timestamp is the only
  # field bash still needs, so nothing else is emitted; a receipt naming another
  # commit yields no output and fails the bound check below.
  created_at="$(printf '%s' "${snapshot#*$'\n'}" \
    | jq -r --arg parent "$parent" --arg tree "$tree" \
        --arg subject_hash "$subject_hash" '
          if type == "object" and .schema == 1
             and .parent == $parent and .tree == $tree
             and .subject_hash == $subject_hash
             and (.created_at | type == "number")
          then .created_at | tostring else empty end' 2>/dev/null)" || return 1
  verdict_audit_epoch_is_bounded "$created_at" || return 1
  now="$(date +%s)"
  (( created_at <= now \
     && now <= created_at + commit_audit_receipt_max_age_seconds )) || return 1
  verdict_audit_unlink_if_identity "$path" "$identity" >/dev/null 2>&1
}
