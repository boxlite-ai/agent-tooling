#!/usr/bin/env bash
# Local compatibility audit and user-prompt approval receiver.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
operation="${1:-check}"
if [[ "$operation" == verify-evidence ]]; then
  [[ "$#" == 3 ]] || exit 1
  exec python3 "$plugin_root/scripts/api-compatibility.py" "$@"
fi
export GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL='' GIT_NO_REPLACE_OBJECTS=1
root="$(git -C "${2:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
spec=':(top,glob)**/*openapi*.yaml'
explicit_base="${3:-}"
revision=''
source_head=HEAD
audit_source=''
prompt=''
api_diff_unchanged() {
  local status=0
  git -C "$root" diff --quiet --ignore-submodules=all "$@" -- "$spec" || status=$?
  if (( status > 1 )); then
    printf 'api-compatibility: cannot compare OpenAPI snapshots\n' >&2
    exit 1
  fi
  return "$status"
}
if [[ "$operation" == audit-push-base ]]; then
  # The pre-push hook emits these ref updates outside patch hunks and binds the file by hash.
  # shellcheck source=../.agents/lib/verdict-audit-state.sh
  source "$plugin_root/.agents/lib/verdict-audit-state.sh" || exit 1
  push_snapshot="$(mktemp -d)" || exit 1
  trap 'rm -f -- "$push_snapshot/context.diff"; rmdir "$push_snapshot"' EXIT
  verdict_audit_copy_regular_state "${4:-}" "$push_snapshot/context.diff" 16777216 || exit 1
  [[ "${5:-}" =~ ^[a-f0-9]{64}$ \
     && "$(verdict_audit_sha256 < "$push_snapshot/context.diff")" == "$5" ]] || exit 1
  while IFS= read -r line; do
    [[ "$line" == '## ref-update '* ]] || continue
    read -r local_ref local_oid remote_ref remote_oid extra <<<"${line#'## ref-update '}"
    [[ "$local_oid" == "$explicit_base" ]] || continue
    [[ -n "$local_ref" && -n "$remote_ref" && -z "$extra" && "$remote_oid" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]] || exit 1
    selected_base="$(bash "$0" audit-base "$root" push "$local_oid" "$remote_oid")" || exit 1
    if [[ -n "$selected_base" ]]; then
      printf '%s\n' "$selected_base"
      exit 0
    fi
  done < "$push_snapshot/context.diff"
  exit 0
fi
if [[ "$operation" == audit-base ]]; then
  audit_kind="${3:-}"
  source_head="${4:-}"
  explicit_base=''
  [[ "$source_head" =~ ^[a-f0-9]{40}([0-9a-f]{24})?$ ]] || exit 1
  case "$audit_kind" in
    commit) ;;
    push)
      revision="$source_head"
      remote_sha="${5:-}"
      [[ -z "$remote_sha" || "$remote_sha" =~ ^[a-f0-9]{40}([a-f0-9]{24})?$ ]] || exit 1
      ;;
    *) exit 1 ;;
  esac
elif [[ "$operation" == audit-evidence ]]; then
  audit_source="${3:-}"
  [[ -n "$audit_source" && -d "${4:-}" ]] || exit 1
  explicit_base=''
fi
if [[ "$operation" == record ]]; then
  # shellcheck source=../.agents/lib/user-question.sh
  source "$plugin_root/.agents/lib/user-question.sh" || exit 1
  payload="$(cat)"
  prompt="$(user_question api-match "$plugin_root" "$payload")" || exit 0
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
if [[ -n "$explicit_base" ]]; then
  if ! explicit_base="$(git -C "$root" rev-parse --verify --quiet --end-of-options "$explicit_base^{commit}")"; then
    printf 'api-compatibility: OpenAPI comparison base must identify a commit\n' >&2
    exit 1
  fi
fi
# Git discovery keeps unrelated repositories independent of Python and oasdiff.
matching_contracts() {
  local entry path found=''
  while IFS= read -r -d '' entry; do
    path="${entry#*$'\t'}"
    if [[ "$entry" != '160000 '* && "${path##*/}" == *openapi*.yaml ]]; then found=present; fi
  done
  printf '%s' "$found"
}
matching=''
untracked=''
if [[ -n "$audit_source" ]]; then
  matching=present
elif [[ -z "$revision" ]]; then
  matching="$(git -C "$root" ls-files --stage -z -- "$spec" | matching_contracts)" || exit 1
  untracked="$(git -C "$root" ls-files --others --exclude-standard -- "$spec")" || exit 1
  [[ -z "$untracked" ]] || matching=present
fi
if [[ -z "$matching" ]]; then
  for ref in "${revision:-$source_head}" "${explicit_base:-origin/main}" main "${remote_sha:-$source_head}"; do
    if ! oid="$(git -C "$root" rev-parse --verify --quiet --end-of-options "$ref")"; then
      if [[ -n "$explicit_base" && "$ref" == "$explicit_base" ]]; then
        printf 'api-compatibility: unreadable OpenAPI snapshot %s\n' "$ref" >&2
        exit 1
      fi
      continue
    fi
    if [[ "$ref" == "${remote_sha:-}" && "$ref" != "$revision" ]] \
       && ! git -C "$root" cat-file -e "$oid^{commit}" 2>/dev/null; then
      continue
    fi
    snapshot_match="$(git -C "$root" ls-tree -r -z "$oid" | matching_contracts)" || {
      printf 'api-compatibility: unreadable OpenAPI snapshot %s\n' "$ref" >&2
      exit 1
    }
    [[ -z "$snapshot_match" ]] || matching=present
  done
fi
[[ -n "$matching" ]] || exit 0
base_ref="$explicit_base"
if [[ -z "$base_ref" ]]; then
  for ref in origin/main main; do
    if git -C "$root" rev-parse --verify "$ref" >/dev/null 2>&1; then base_ref="$ref"; break; fi
  done
fi
base=''
if [[ -n "$base_ref" && "$base_ref" != -* && -z "$audit_source" ]]; then
  base="$(git -C "$root" merge-base "${revision:-$source_head}" "$base_ref" 2>/dev/null)" || base=''
fi
if [[ "${1:-}" == push-ref || ( "$operation" == audit-base && -n "${remote_sha:-}" ) ]]; then
  if [[ "$remote_sha" =~ ^0+$ ]]; then
    if [[ -n "$base" ]] && api_diff_unchanged "$base" "$revision"; then exit 0; fi
  else
    if api_diff_unchanged "$remote_sha" "$revision"; then exit 0; fi
    git -C "$root" merge-base --is-ancestor "$remote_sha" "$revision" || {
      printf 'api-compatibility: audit a non-fast-forward API update separately\n' >&2; exit 1;
    }
  fi
  [[ "$revision" == "$(git -C "$root" rev-parse HEAD)" ]] || {
    printf 'api-compatibility: check out and audit the API ref being pushed\n' >&2; exit 1;
  }
fi
if [[ -n "$base" ]]; then
  if [[ -n "$revision" ]]; then
    if api_diff_unchanged "$base" "$revision"; then exit 0; fi
  elif [[ -z "$untracked" ]] && api_diff_unchanged "$base" \
       && api_diff_unchanged --cached "$base"; then exit 0; fi
  if [[ "$operation" == audit-base ]]; then
    printf '%s\n' "$base"
    exit 0
  fi
  explicit_base="$base"
fi
if [[ "$operation" == audit-base ]]; then
  printf 'api-compatibility: cannot determine the OpenAPI comparison base\n' >&2
  exit 1
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
[[ "$operation" != inspect-push && "$operation" != audit-evidence ]] || action=inspect
if [[ "$operation" == record ]]; then
  action=inspect
fi
# shellcheck source=../.agents/lib/user-question.sh
declare -F user_question >/dev/null || source "$plugin_root/.agents/lib/user-question.sh" || exit 1
directive="$(user_question api-directive "$plugin_root")" || exit 1
question="$(user_question render "$plugin_root" questions/api-compatibility "directive=$directive")" || exit 1
question="$(user_question ask "$plugin_root" "$question" "")" || exit 1
evidence="$(jq -nc --argjson approval "$approval" --arg question "$question" \
  '{approval:$approval, question:$question}')" || exit 1
args=("$action" "$root")
[[ -z "$explicit_base" ]] || args+=(--base "$explicit_base")
[[ -z "$revision" ]] || args+=(--revision "$revision")
[[ -z "$audit_source" ]] || args+=(--audit-source "$audit_source" --scratch "$4")
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
