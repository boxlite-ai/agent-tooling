#!/usr/bin/env bash
# Local compatibility audit and user-prompt approval receiver.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
operation="${1:-check}"
root="$(git -C "${2:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
spec=':(top,glob)**/*openapi*.yaml'
explicit_base="${3:-}"
revision=''
prompt=''
if [[ "$operation" == record ]]; then
  prompt="$(jq -er 'select(.hook_event_name == "UserPromptSubmit" and (.session_id | type == "string") and (.session_id | length > 0)) | .prompt | strings')" || exit 0
  [[ "$prompt" == 'api compatibility: skip' ]] || exit 0
fi
if [[ "$operation" == push-ref ]]; then
  local_sha="${3:-}"; remote_sha="${4:-}"
  [[ "$local_sha" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ && "$remote_sha" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]] || exit 1
  [[ ! "$local_sha" =~ ^0+$ ]] || exit 0
  explicit_base=''
  revision="$local_sha"
  operation=push
fi
if [[ -z "$revision" && ( "$operation" == push || "$operation" == inspect-push ) ]]; then
  revision="$(git -C "$root" rev-parse --verify HEAD)" || exit 1
fi
# Git discovery keeps unrelated repositories independent of Python and oasdiff.
matching=''
untracked=''
if [[ -z "$revision" ]]; then
  matching="$(git -C "$root" ls-files --cached --others --exclude-standard -- "$spec")" || exit 1
  untracked="$(git -C "$root" ls-files --others --exclude-standard -- "$spec")" || exit 1
fi
if [[ -z "$matching" ]]; then
  for ref in "${revision:-HEAD}" "${explicit_base:-origin/main}" main "${remote_sha:-HEAD}"; do
    if git -C "$root" ls-files --error-unmatch --with-tree="$ref" -- "$spec" >/dev/null 2>&1; then
      matching=present; break
    fi
  done
fi
[[ -n "$matching" ]] || exit 0
if [[ "${1:-}" == push-ref ]]; then
  if [[ ! "$remote_sha" =~ ^0+$ ]]; then
    if git -C "$root" diff --quiet "$remote_sha" "$revision" -- "$spec"; then exit 0; fi
    git -C "$root" merge-base --is-ancestor "$remote_sha" "$revision" || {
      printf 'api-compatibility: audit a non-fast-forward API update separately\n' >&2; exit 1;
    }
  fi
  [[ "$revision" == "$(git -C "$root" rev-parse HEAD)" ]] || {
    printf 'api-compatibility: check out and audit the API ref being pushed\n' >&2; exit 1;
  }
fi
base_ref="$explicit_base"
if [[ -z "$base_ref" ]]; then
  for ref in origin/main main; do
    if git -C "$root" rev-parse --verify "$ref" >/dev/null 2>&1; then base_ref="$ref"; break; fi
  done
fi
if [[ -n "$base_ref" && "$base_ref" != -* ]] \
   && base="$(git -C "$root" merge-base "${revision:-HEAD}" "$base_ref" 2>/dev/null)"; then
  if [[ -n "$revision" ]]; then
    if git -C "$root" diff --quiet "$base" "$revision" -- "$spec"; then exit 0; fi
  elif [[ -z "$untracked" ]] && git -C "$root" diff --quiet "$base" -- "$spec" \
       && git -C "$root" diff --cached --quiet "$base" -- "$spec"; then exit 0; fi
fi
for dependency in python3 jq; do
  command -v "$dependency" >/dev/null || { printf 'api-compatibility: missing %s\n' "$dependency" >&2; exit 1; }
done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin_root/.agents/lib/verdict-audit-state.sh" || exit 1
state="$(git -C "$root" rev-parse --absolute-git-dir)/api-compatibility"
read_record() {
  local snapshot
  if [[ ! -e "$1" && ! -L "$1" ]]; then printf '{}'; return; fi
  snapshot="$(verdict_audit_read_json_snapshot "$1")" || return 1
  printf '%s' "${snapshot#*$'\n'}"
}
approval="$(read_record "$state.approval.json")" || { printf 'api-compatibility: unreadable approval\n' >&2; exit 1; }
action="$operation"
[[ "$operation" != inspect-push ]] || action=inspect
if [[ "$operation" == record ]]; then
  action=inspect
fi
evidence="$(jq -nc --argjson approval "$approval" '{approval:$approval}')" || exit 1
args=("$action" "$root")
[[ -z "$explicit_base" ]] || args+=(--base "$explicit_base")
[[ -z "$revision" ]] || args+=(--revision "$revision")
report="$(printf '%s' "$evidence" | python3 "$plugin_root/scripts/api-compatibility.py" "${args[@]}")"
status=$?
if [[ "$operation" == record ]]; then
  approved_digest="$(jq -r 'select(.requires_confirmation == true) | .fingerprint // ""' <<<"$report")"
  [[ -n "$approved_digest" ]] || {
    jq -r '.errors[]? | "api-compatibility: " + .' <<<"$report" >&2
    printf 'api-compatibility: no classified breaking/default change to confirm\n' >&2; exit 1;
  }
  jq -nc --arg fingerprint "$approved_digest" --arg prompt "$prompt" \
    '{fingerprint:$fingerprint,confirmation:$prompt,source:"UserPromptSubmit"}' |
    verdict_audit_write_atomic "$state.approval.json" || exit 1
  printf 'api-compatibility: human confirmation recorded; skip breaking/default gate for this change\n' >&2
  exit 0
fi
if (( status != 0 )); then
  jq -r '.errors[] | "api-compatibility: " + .' <<<"$report" >&2 || printf 'api-compatibility: checker failed\n' >&2
fi
case "$operation" in check|commit|push) ;; *) printf '%s\n' "$report" ;; esac
exit "$status"
