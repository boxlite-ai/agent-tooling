#!/usr/bin/env bash
# Design-doc verification, worktree binding, and the audit verdict recorded for the
# bound content. Requires jq, perl, git, curl, verdict-audit-state.sh, reply-summary.sh
# and concise-writing.sh. Source only.
# _design_doc_jq takes single-quoted jq programs, as jq itself does.
# shellcheck disable=SC2016

_design_doc_error() {
  printf 'design-doc: %s\n' "$1" >&2
  return 1
}

_design_doc_http() { # credential header, URL, optional curl arguments
  local credential="$1" endpoint="$2"
  shift 2
  [[ "$credential" != *[$'\r\n'\"\\]* ]] || return 1
  # Keep credentials off argv; fixed provider endpoints never follow redirects.
  printf 'header = "Authorization: %s"\n' "$credential" |
    curl --config - --silent --show-error --fail --connect-timeout 5 \
      --max-time 15 --max-filesize 65536 "$@" "$endpoint" 2>/dev/null |
    perl -e '
      binmode STDIN; binmode STDOUT;
      my $body = "";
      while (length($body) <= 65536) {
        my $count = read(STDIN, my $chunk, 65537 - length($body));
        defined($count) or exit 1;
        last unless $count;
        $body .= $chunk;
      }
      length($body) <= 65536 or exit 1;
      print $body;
    '
}

_design_doc_content() { # canonical provider URL -> Markdown/text
  local url="$1" response endpoint identifier page
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]*)$ ]]; then
    endpoint="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/issues/${BASH_REMATCH[3]}"
    response="$(perl -e 'alarm 15; exec @ARGV' gh api --hostname github.com "$endpoint" \
      2>/dev/null | head -c 65537)" || return 1
    (( ${#response} <= 65536 )) || return 1
    jq -er --arg url "$url" \
      'select(.html_url == $url and (.pull_request == null)) | .body | strings' <<<"$response"
  elif [[ "$url" =~ ^https://linear\.app/[A-Za-z0-9_-]+/issue/([A-Za-z0-9]+-[1-9][0-9]*)(/[A-Za-z0-9_-]+)?$ ]]; then
    identifier="${BASH_REMATCH[1]}"
    [[ -n "${LINEAR_API_KEY:-}" ]] || { _design_doc_error 'LINEAR_API_KEY is required'; return 1; }
    response="$(_design_doc_http "$LINEAR_API_KEY" https://api.linear.app/graphql \
      -H 'Content-Type: application/json' --data-binary \
      "$(jq -nc --arg id "$identifier" '{query:"query($id: String!) { issue(id: $id) { url description archivedAt } }",variables:{id:$id}}')")" || return 1
    jq -er --arg url "$url" 'select((.errors // []) | length == 0) | .data.issue |
      select(.url == $url and .archivedAt == null) | .description | strings' <<<"$response"
  elif [[ "$url" =~ ^https://(www\.)?notion\.so/([A-Za-z0-9_-]+/)?([A-Za-z0-9_-]*-)?([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$ ]]; then
    identifier="${BASH_REMATCH[4]}"
    [[ -n "${NOTION_TOKEN:-}" ]] || { _design_doc_error 'NOTION_TOKEN is required'; return 1; }
    endpoint="https://api.notion.com/v1"
    page="$(_design_doc_http "Bearer $NOTION_TOKEN" "$endpoint/pages/$identifier" \
      -H 'Notion-Version: 2025-09-03')" || return 1
    jq -e --arg id "${identifier//-/}" 'select(.object == "page" and
      .archived == false and .in_trash != true and (.id | gsub("-";"")) == $id)' \
      <<<"$page" >/dev/null || return 1
    response="$(_design_doc_http "Bearer $NOTION_TOKEN" "$endpoint/blocks/$identifier/children?page_size=100" \
      -H 'Notion-Version: 2025-09-03')" || return 1
    # Reject unread children; block types, not literal Markdown, define structure.
    jq -er 'select(.object == "list" and .has_more == false and
      all(.results[]; .has_children != true)) |
      [.results[] | .type as $type | .[$type].rich_text // [] |
        map(.plain_text) | join("") | select(test("[^[:space:]]")) |
        if $type == "bulleted_list_item" or $type == "numbered_list_item" or $type == "to_do"
        then "- \\" + gsub("[\r\n]+"; " ") elif $type == "code" then
          ("`" * (([2] + [scan("`+") | length] | max) + 1)) as $fence |
          $fence + "\n" + . + "\n" + $fence
        elif ($type | test("^heading_[123]$")) then
          ("#" * ($type[-1:] | tonumber)) + " " + gsub("[\r\n]+"; " ")
        else "\\" + gsub("[\r\n]+"; " ") end] | join("\n\n")' <<<"$response"
  else
    _design_doc_error 'use a canonical GitHub issue, notion.so page, or Linear issue URL'
  fi
}

# A leading TL;DR gives readers the short version, so the details may be dense.
design_doc_verify() { # URL -> SHA-256 of the verified content, only after a live provider read
  local url="${1:-}" body
  (( ${#url} <= 2048 )) || { _design_doc_error 'document URL is too long'; return 1; }
  body="$(_design_doc_content "$url")" || {
    _design_doc_error 'cannot verify document (check URL, provider access, and credentials)'; return 1;
  }
  [[ "$body" == *[![:space:]]* ]] || { _design_doc_error 'document is empty'; return 1; }
  (( ${#body} <= 32000 )) || { _design_doc_error 'document exceeds the bounded content check'; return 1; }
  concise_writing_check_summary "$body" first policy >&2 || return 1
  printf '%s' "$body" | perl -MDigest::SHA=sha256_hex -0777 -e 'print sha256_hex(scalar(<STDIN>) // "")'
}

_design_doc_jq() { # jq arguments -> jq with this library's modules on its path
  jq -L "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" "$@"
}

# The loop state for this root and branch (design-audit.jq). A missing file starts
# fresh; an unreadable or malformed one fails closed, so it cannot reset the count.
_design_doc_audit_state() { # verdict path, root, branch
  local path="$1" snapshot record=null
  # Verdicts recorded before the rename stay readable until the next one is written.
  [[ -e "$path" || -L "$path" ]] || path="${path%/*}/agent-tooling-design-research.json"
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" || return 1
    record="${snapshot#*$'\n'}"
  fi
  _design_doc_jq -c --arg root "$2" --arg branch "$3" \
    'include "design-audit"; da_state($root; $branch)' <<<"$record" 2>/dev/null
}

_design_doc_history_hash() { # state JSON -> SHA-256 that a reflection must bind
  jq -cS 'del(.reflection)' <<<"$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
}

_design_doc_file_hash() { # path -> SHA-256 of its bytes, or nothing when it is missing
  [[ ! -f "$1" ]] || perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$1"
}

# The deadline the design auditor works to: DESIGN_AUDITOR_TIMEOUT (default 900 s, as for
# the other audits). Repeated edit attempts reuse an unexpired deadline for the same content.
# The task file also records the audit state's hash, so a stop can tell whether a verdict landed.
design_doc_audit_task() { # repo root, URL, content SHA-256 -> deadline (Unix seconds)
  local timeout="${DESIGN_AUDITOR_TIMEOUT:-900}" git_dir path now snapshot
  [[ "$timeout" =~ ^[1-9][0-9]{0,3}$ ]] || {
    _design_doc_error 'DESIGN_AUDITOR_TIMEOUT must be 1 to 9999 seconds'; return 1;
  }
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)" || return 1
  path="$git_dir/agent-tooling-design-audit-task.json"
  now="$(date +%s)" || return 1
  if [[ -e "$path" ]] && snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" \
     && jq -er --arg url "$2" --arg digest "$3" --argjson now "$now" \
       'select(.url == $url and .content_sha256 == $digest and .deadline > $now) | .deadline' \
       <<<"${snapshot#*$'\n'}" 2>/dev/null; then
    return 0
  fi
  jq -nc --arg url "$2" --arg digest "$3" --argjson deadline "$(( now + timeout ))" \
    --arg state "$(_design_doc_file_hash "$git_dir/agent-tooling-design-audit.json")" \
    '{url:$url, content_sha256:$digest, deadline:$deadline, state_hash:$state}' \
    | verdict_audit_write_atomic "$path" || return 1
  printf '%s\n' "$(( now + timeout ))"
}

# Prints nothing and succeeds when a PASS or an overrule matches the live content.
# Otherwise prints the gate's request: the auditor's task input, the prior findings, and
# the loop state; a missing, unreadable, or mismatched verdict never counts.
_design_doc_audit_passed() { # verdict path, root, branch, URL, content SHA-256
  local state
  state="$(_design_doc_audit_state "$1" "$2" "$3")" || {
    _design_doc_error 'design-audit state is unreadable or malformed; inspect it before retrying'; return 1;
  }
  _design_doc_jq -e --arg url "$4" --arg digest "$5" \
    'include "design-audit"; da_passed($url; $digest)' <<<"$state" >/dev/null && return 0
  _design_doc_jq -c --arg root "$2" --arg url "$4" --arg digest "$5" \
    --arg history "$(_design_doc_history_hash "$state")" \
    'include "design-audit"; da_request($root; $url; $digest; $history)' <<<"$state"
  return 1
}

# Applies one loop transition (design-audit.jq) and stores the result atomically.
_design_doc_audit_update() { # verdict path, root, branch, URL, live SHA-256, filter, argument
  local state output
  state="$(_design_doc_audit_state "$1" "$2" "$3")" || {
    _design_doc_error 'design-audit state is unreadable or malformed; inspect it before retrying'; return 1;
  }
  output="$(_design_doc_jq -c --arg url "$4" --arg digest "$5" --arg argument "$7" \
    --arg history "$(_design_doc_history_hash "$state")" "include \"design-audit\"; $6" \
    <<<"$state" 2>&1)" || { _design_doc_error "${output#*): }"; return 1; }
  printf '%s\n' "$output" | verdict_audit_write_atomic "$1"
}

_design_doc_audit_write() { # verdict path, root, branch, URL, live SHA-256, verdict JSON
  jq -e --arg digest "$5" '.content_sha256 == $digest' <<<"$6" >/dev/null || {
    _design_doc_error 'the design changed after this review; review the current design'; return 1;
  }
  _design_doc_audit_update "$1" "$2" "$3" "$4" "$5" \
    'da_record($argument | fromjson; $url; $digest)' "$6"
}

# Records an independent design auditor's verdict for the live content it reviewed.
# stdin: one {content_sha256, verdict, findings, advisories} object. Critical and high
# gaps are findings and FAIL; advisories (low, nit) never do. advisories may be omitted.
design_doc_audit_record() { # working directory -> verified URL
  local input verdict
  input="$(head -c 65537)"
  (( ${#input} <= 65536 )) || { _design_doc_error 'audit verdict is too large'; return 1; }
  verdict="$(jq -cse 'def lines: type == "array" and length <= 50 and all(.[]; type == "string"
      and length >= 1 and length <= 500 and (test("[[:cntrl:]]") | not));
    if length == 1 then .[0] else empty end |
    select(type == "object" and (keys - ["advisories"]) == ["content_sha256","findings","verdict"]
      and (.content_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
      and (.findings | lines) and ((.advisories // []) | lines)
      and all((.advisories // [])[]; test("\\A\\s*(critical|high)\\s*:"; "i") | not)
      and ((.verdict == "PASS" and (.findings | length) == 0)
        or (.verdict == "FAIL" and (.findings | length) > 0)))
    | .advisories //= []' <<<"$input" 2>/dev/null)" || {
    _design_doc_error 'audit verdict must be one {content_sha256, verdict, findings, advisories} object: PASS without findings, FAIL with one-line findings, and no critical or high advisories'
    return 1
  }
  design_doc_binding verdict "$1" "$verdict"
}

# Stores the reflection that audit 3, or an audit after Reflect again, waits for.
design_doc_audit_reflect() { # working directory -> verified URL
  local input
  input="$(head -c 65537)"
  (( ${#input} <= 65536 )) || { _design_doc_error 'reflection is too large'; return 1; }
  jq -e . <<<"$input" >/dev/null 2>&1 || { _design_doc_error 'reflection must be one JSON object'; return 1; }
  design_doc_binding reflect "$1" "$input"
}

_design_doc_context() { # repo root -> branch identity
  local branch
  branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)" ||
    branch="detached:$(git -C "$1" rev-parse HEAD)" || return 1
  printf '%s' "$branch"
}

# edit also requires an audit PASS for the live content; its exit 3 prints the gate's
# request instead of the URL. decide applies a human choice that a hook already accepted.
design_doc_binding() { # bind|check|edit|verdict|reflect|decide, working directory, URL, verdict, reflection or choice -> verified URL
  local operation="$1" root branch git_dir state_path audit_path snapshot url record digest
  root="$(git -C "$2" rev-parse --show-toplevel)" || return 1
  root="$(cd "$root" && pwd -P)" || return 1
  branch="$(_design_doc_context "$root")" || return 1
  git_dir="$(git -C "$root" rev-parse --absolute-git-dir)" || return 1
  state_path="$git_dir/agent-tooling-design-doc.json"
  audit_path="$git_dir/agent-tooling-design-audit.json"
  case "$operation" in
    bind)
      url="${3:-}"
      design_doc_verify "$url" >/dev/null || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      jq -nc --arg root "$root" --arg branch "$branch" --arg url "$url" \
        '{root:$root,branch:$branch,url:$url}' |
        verdict_audit_write_atomic "$state_path" || return 1
      ;;
    check|edit|verdict|reflect|decide)
      snapshot="$(verdict_audit_read_json_snapshot "$state_path")" || {
        _design_doc_error 'no readable binding; register the design doc before writing code'; return 1;
      }
      record="${snapshot#*$'\n'}"
      url="$(jq -er --arg root "$root" --arg branch "$branch" \
        'select(keys == ["branch","root","url"] and .root == $root and .branch == $branch) |
         .url | strings' <<<"$record")" || {
        _design_doc_error 'document binding does not match this worktree and branch'; return 1;
      }
      digest="$(design_doc_verify "$url")" || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      case "$operation" in
        edit) _design_doc_audit_passed "$audit_path" "$root" "$branch" "$url" "$digest" || return 3 ;;
        verdict) _design_doc_audit_write "$audit_path" "$root" "$branch" "$url" "$digest" "$3" || return 1 ;;
        reflect) _design_doc_audit_update "$audit_path" "$root" "$branch" "$url" "$digest" \
          'da_reflect($argument | fromjson; $history)' "$3" || return 1 ;;
        decide) _design_doc_audit_update "$audit_path" "$root" "$branch" "$url" "$digest" \
          'da_decide($argument; $url; $digest)' "$3" || return 1 ;;
      esac
      ;;
    *) _design_doc_error 'expected bind, check, edit, verdict, reflect or decide'; return 1 ;;
  esac
  printf '%s\n' "$url"
}

design_doc_show() { # working directory -> content of the verified binding
  local url
  # Auditors read through the binder's authenticated reader; provider pages need a login.
  url="$(design_doc_binding check "$1")" || return 1
  _design_doc_content "$url" || {
    _design_doc_error 'cannot read document (check URL, provider access, and credentials)'; return 1;
  }
}
