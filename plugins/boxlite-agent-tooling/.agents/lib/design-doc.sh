#!/usr/bin/env bash
# Design-doc verification, worktree binding, and the research verdict recorded for the
# bound content. Requires jq, perl, git, curl, verdict-audit-state.sh, reply-summary.sh
# and concise-writing.sh. Source only.

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
  concise_writing_check_summary "$body" first 39 >&2 || return 1
  printf '%s' "$body" | perl -MDigest::SHA=sha256_hex -0777 -e 'print sha256_hex(scalar(<STDIN>) // "")'
}

# Prints nothing and succeeds when a PASS matches the live content. Otherwise prints
# the research auditor's task input, with the findings of a FAIL for this same content,
# and fails: a missing, unreadable, or mismatched verdict never counts.
_design_doc_research_passed() { # verdict path, root, branch, URL, content SHA-256
  local snapshot record='{}' state
  if snapshot="$(verdict_audit_read_json_snapshot "$1" 2>/dev/null)"; then
    record="${snapshot#*$'\n'}"
  fi
  state="$(jq -c --arg root "$2" --arg branch "$3" --arg url "$4" --arg digest "$5" '
    if type == "object" and keys == ["branch","content_sha256","findings","root","url","verdict"]
       and .root == $root and .branch == $branch and .url == $url and .content_sha256 == $digest
    then {verdict, findings:[.findings[]? | strings]} else {verdict:"NONE", findings:[]} end' \
    <<<"$record" 2>/dev/null)" || state='{"verdict":"NONE","findings":[]}'
  [[ "$(jq -r '.verdict' <<<"$state")" != PASS ]] || return 0
  jq -c --arg root "$2" --arg url "$4" --arg digest "$5" \
    '{repo_root:$root, design_url:$url, content_sha256:$digest,
      findings:(if .verdict == "FAIL" then .findings else [] end)}' <<<"$state"
  return 1
}

_design_doc_research_write() { # verdict path, root, branch, URL, live SHA-256, verdict JSON
  jq -e --arg digest "$5" '.content_sha256 == $digest' <<<"$6" >/dev/null || {
    _design_doc_error 'the design changed after this review; review the current design'; return 1;
  }
  jq -c --arg root "$2" --arg branch "$3" --arg url "$4" '{root:$root, branch:$branch, url:$url} + .' \
    <<<"$6" | verdict_audit_write_atomic "$1"
}

# Records an independent auditor's research verdict for the live content it reviewed.
# stdin: one {content_sha256, verdict, findings} object; PASS has no findings and FAIL
# has one-line findings.
design_doc_research_record() { # working directory -> verified URL
  local input verdict
  input="$(head -c 65537)"
  (( ${#input} <= 65536 )) || { _design_doc_error 'research verdict is too large'; return 1; }
  verdict="$(jq -cse 'if length == 1 then .[0] else empty end |
    select(type == "object" and keys == ["content_sha256","findings","verdict"]
      and (.content_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
      and (.findings | type == "array" and length <= 50 and all(.[]; type == "string"
        and length >= 1 and length <= 500 and (test("[[:cntrl:]]") | not)))
      and ((.verdict == "PASS" and (.findings | length) == 0)
        or (.verdict == "FAIL" and (.findings | length) > 0)))' <<<"$input" 2>/dev/null)" || {
    _design_doc_error 'research verdict must be one {content_sha256, verdict, findings} object: PASS without findings, FAIL with one-line findings'
    return 1
  }
  design_doc_binding research "$1" "$verdict"
}

_design_doc_context() { # repo root -> branch identity
  local branch
  branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)" ||
    branch="detached:$(git -C "$1" rev-parse HEAD)" || return 1
  printf '%s' "$branch"
}

# edit also requires a research PASS for the live content; its exit 3 prints the
# research auditor's task input instead of the URL.
design_doc_binding() { # bind|check|edit|research, working directory, URL to bind or verdict to record -> verified URL
  local operation="$1" root branch git_dir state_path research_path snapshot url record digest
  root="$(git -C "$2" rev-parse --show-toplevel)" || return 1
  root="$(cd "$root" && pwd -P)" || return 1
  branch="$(_design_doc_context "$root")" || return 1
  git_dir="$(git -C "$root" rev-parse --absolute-git-dir)" || return 1
  state_path="$git_dir/agent-tooling-design-doc.json"
  research_path="$git_dir/agent-tooling-design-research.json"
  case "$operation" in
    bind)
      url="${3:-}"
      design_doc_verify "$url" >/dev/null || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      jq -nc --arg root "$root" --arg branch "$branch" --arg url "$url" \
        '{root:$root,branch:$branch,url:$url}' |
        verdict_audit_write_atomic "$state_path" || return 1
      ;;
    check|edit|research)
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
        edit) _design_doc_research_passed "$research_path" "$root" "$branch" "$url" "$digest" || return 3 ;;
        research) _design_doc_research_write "$research_path" "$root" "$branch" "$url" "$digest" "$3" || return 1 ;;
      esac
      ;;
    *) _design_doc_error 'expected bind, check, edit or research'; return 1 ;;
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
