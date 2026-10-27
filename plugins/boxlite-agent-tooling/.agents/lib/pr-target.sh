#!/usr/bin/env bash
# Source-only target resolution. Requires git, gh, jq, perl; no publication.

_pr_target_gh() {
  perl -e '$SIG{ALRM}=sub{exit 124}; alarm 20; exec @ARGV; exit 2' gh "$@"
}

pr_target_binding() { # resolved target -> stable publication identity
  jq -cS 'del(.body,.undo)' <<<"$1"
}

pr_target_resolve() { # create|edit|ready, literal argv -> resolved target JSON
  local operation="$1" branch head repo_option="" base_ref="" head_option="" selector=""
  local token value key repository host metadata response base head_ref owner number=0 body="" head_repo="" undo=false
  local -a repo_args=() selector_args=()
  shift
  branch="$(git branch --show-current)" && [[ -n "$branch" ]] || return 2
  head="$(git rev-parse HEAD)" && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 2
  while (( $# )); do
    token="$1"; shift; key=""
    case "$token" in
      --repo|-R|--base|-B|--head|-H)
        (( $# )) || return 2
        value="$1"; shift; key="$token" ;;
      --repo=*|-R=*) key=--repo; value="${token#*=}" ;;
      -R?*) key=--repo; value="${token#-R}" ;;
      --base=*|-B=*) key=--base; value="${token#*=}" ;;
      -B?*) key=--base; value="${token#-B}" ;;
      --head=*|-H=*) key=--head; value="${token#*=}" ;;
      -H?*) key=--head; value="${token#-H}" ;;
      --title|-t|--body|-b|--body-file|-F|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer)
        (( $# )) || return 2; shift ;;
      --draft|-d|--draft=true|-d=true|--fill|--fill-first|--fill-verbose|--dry-run|--no-maintainer-edit|--remove-milestone) ;;
      --undo) [[ "$operation" == ready ]] || return 2; undo=true ;;
      --title=*|--body=*|--body-file=*|--assignee=*|--label=*|--milestone=*|--project=*|--reviewer=*|--add-*=*|--remove-*=*|-t?*|-b?*|-F?*|-a?*|-l?*|-m?*|-p?*|-r?*) ;;
      -*) return 2 ;;
      *) [[ "$operation" != create && -z "$selector" && "$token" != *://* ]] || return 2; selector="$token" ;;
    esac
    if [[ -n "$key" ]]; then
      [[ -n "$value" ]] || return 2
      case "$key" in
        --repo|-R) [[ -z "$repo_option" ]] || return 2; repo_option="$value" ;;
        --base|-B) [[ "$operation" == create && -z "$base_ref" ]] || return 2; base_ref="$value" ;;
        --head|-H) [[ "$operation" == create && -z "$head_option" ]] || return 2; head_option="$value" ;;
      esac
    fi
  done
  if [[ -n "$repo_option" ]]; then
    [[ "$repo_option" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*/)?[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || return 2
    [[ "${repo_option##*/}" != . && "${repo_option##*/}" != .. ]] || return 2
    repo_args=("$repo_option")
  fi
  metadata="$(_pr_target_gh repo view ${repo_args[@]+"${repo_args[@]}"} --json nameWithOwner,defaultBranchRef,url)" || return 2
  repository="$(jq -er '.nameWithOwner | strings | select(test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"))' <<<"$metadata")" || return 2
  [[ "${repository##*/}" != . && "${repository##*/}" != .. ]] || return 2
  host="$(jq -er --arg repo "$repository" '.url | strings
    | capture("^https://(?<host>[A-Za-z0-9][A-Za-z0-9.-]*)/(?<repo>[^?#]+)$")
    | select(.repo==$repo) | .host' <<<"$metadata")" || return 2
  if [[ "$repo_option" == */*/* ]]; then
    [[ "$host" == "${repo_option%%/*}" ]] || return 2
  fi
  if [[ "$operation" == create ]]; then
    head_ref="${head_option:-$branch}"
    owner="${repository%%/*}"
    if [[ "$head_ref" == *:* ]]; then
      owner="${head_ref%%:*}"; head_ref="${head_ref#*:}"
      [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 2
      value="$owner:refs/heads/$head_ref"
    else
      value="refs/heads/$head_ref"
    fi
    git check-ref-format "refs/heads/$head_ref" >/dev/null 2>&1 || return 2
    # gh uses the selected head branch's config, which can differ from the checkout.
    [[ -n "$base_ref" ]] || base_ref="$(git config --get "branch.$head_ref.gh-merge-base" || true)"
    [[ -n "$base_ref" ]] || base_ref="$(jq -er '.defaultBranchRef.name | strings | select(length>0)' <<<"$metadata")" || return 2
    git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 || return 2
    response="$(_pr_target_gh api --hostname "$host" "repos/$repository/git/ref/heads/$(jq -rn --arg ref "$base_ref" '$ref|@uri')")" || return 2
    base="$(jq -er 'select(.object.type=="commit") | .object.sha | strings | select(test("^[0-9a-f]{40}$"))' <<<"$response")" || return 2
    # GitHub resolves owner-qualified refs across its network, including renamed forks.
    response="$(_pr_target_gh api --hostname "$host" "repos/$repository/compare/$head...$(jq -rn --arg ref "$value" '$ref|@uri')")" || return 2
    jq -e --arg head "$head" 'select(.status=="identical" and .ahead_by==0 and .behind_by==0
      and .base_commit.sha==$head and .merge_base_commit.sha==$head)' <<<"$response" >/dev/null || return 2
    head_ref="$owner:$head_ref"
  else
    [[ "$operation" == edit || "$operation" == ready ]] || return 2
    [[ -z "$selector" ]] || selector_args=("$selector")
    response="$(_pr_target_gh pr view ${selector_args[@]+"${selector_args[@]}"} --repo "$host/$repository" \
      --json number,url,baseRefOid,baseRefName,headRefOid,headRefName,headRepositoryOwner,headRepository,body)" || return 2
    (( ${#response} <= 65536 )) || return 2
    # An omitted selector must stay omitted: gh uses branch tracking in that case.
    response="$(jq -ce --arg head "$head" --arg prefix "https://$host/$repository/pull/" '
      select(.headRefOid==$head and (.baseRefOid|type=="string" and test("^[0-9a-f]{40}$"))
        and (.number|type=="number" and .>0 and floor==.)
        and .url==($prefix+(.number|tostring)) and (.body|type=="string")
        and (.baseRefName|type=="string" and length>0)
        and (.headRefName|type=="string" and length>0)
        and (.headRepositoryOwner.login|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9-]*$"))
        and (.headRepository.name|type=="string" and test("^[A-Za-z0-9_.-]+$")))' <<<"$response")" || return 2
    base="$(jq -r .baseRefOid <<<"$response")"; base_ref="$(jq -r .baseRefName <<<"$response")"
    number="$(jq -r .number <<<"$response")"; body="$(jq -r .body <<<"$response")"
    head_ref="$(jq -r '.headRepositoryOwner.login+":"+.headRefName' <<<"$response")"
    head_repo="$(jq -r '.headRepositoryOwner.login+"/"+.headRepository.name' <<<"$response")"
    git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 || return 2
    git check-ref-format "refs/heads/${head_ref#*:}" >/dev/null 2>&1 || return 2
  fi
  jq -ncS --arg host "$host" --arg repo "$repository" --arg branch "$branch" --arg head "$head" \
    --arg base "$base" --arg base_ref "$base_ref" --arg head_ref "$head_ref" --arg head_repo "$head_repo" \
    --argjson number "$number" --arg body "$body" --argjson undo "$undo" \
    '{host:$host,repo:$repo,branch:$branch,head:$head,base:$base,base_ref:$base_ref,
      head_ref:$head_ref,head_repo:$head_repo,number:$number,body:$body,undo:$undo}'
}
