#!/usr/bin/env bash
# Design-doc verification and worktree binding. Requires jq, perl, git, curl,
# verdict-audit-state.sh, reply-summary.sh and concise-writing.sh. Source only.

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
    # Reject unread children; block types, not literal Markdown, define density.
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

design_doc_verify() { # URL -> URL, only after a live provider read
  local url="${1:-}" body density=0
  (( ${#url} <= 2048 )) || { _design_doc_error 'document URL is too long'; return 1; }
  body="$(_design_doc_content "$url")" || {
    _design_doc_error 'cannot verify document (check URL, provider access, and credentials)'; return 1;
  }
  [[ "$body" == *[![:space:]]* ]] || { _design_doc_error 'document is empty'; return 1; }
  (( ${#body} <= 32000 )) || { _design_doc_error 'document exceeds the bounded content check'; return 1; }
  reply_summary_is_dense "$body" || density=$?
  [[ "$density" == 1 ]] || {
    _design_doc_error 'walls of text are forbidden: shorten paragraphs and list items'; return 1;
  }
  concise_writing_check_summary "$body" >&2 || return 1
  printf '%s\n' "$url"
}

_design_doc_context() { # repo root -> branch identity
  local branch
  branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)" ||
    branch="detached:$(git -C "$1" rev-parse HEAD)" || return 1
  printf '%s' "$branch"
}

design_doc_binding() { # bind|check, working directory, URL for bind -> verified URL
  local operation="$1" root branch state_path snapshot url="${3:-}" record
  root="$(git -C "$2" rev-parse --show-toplevel)" || return 1
  root="$(cd "$root" && pwd -P)" || return 1
  branch="$(_design_doc_context "$root")" || return 1
  state_path="$(git -C "$root" rev-parse --absolute-git-dir)/agent-tooling-design-doc.json"
  case "$operation" in
    bind)
      design_doc_verify "$url" >/dev/null || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      jq -nc --arg root "$root" --arg branch "$branch" --arg url "$url" \
        '{root:$root,branch:$branch,url:$url}' |
        verdict_audit_write_atomic "$state_path" || return 1
      ;;
    check)
      snapshot="$(verdict_audit_read_json_snapshot "$state_path")" || {
        _design_doc_error 'no readable binding; register the design doc before writing code'; return 1;
      }
      record="${snapshot#*$'\n'}"
      url="$(jq -er --arg root "$root" --arg branch "$branch" \
        'select(keys == ["branch","root","url"] and .root == $root and .branch == $branch) |
         .url | strings' <<<"$record")" || {
        _design_doc_error 'document binding does not match this worktree and branch'; return 1;
      }
      design_doc_verify "$url" >/dev/null || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      ;;
    *) _design_doc_error 'expected bind or check'; return 1 ;;
  esac
  printf '%s\n' "$url"
}
