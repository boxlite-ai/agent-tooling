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

_design_doc_content_json() { # canonical provider URL -> JSON string, preserving trailing newlines
  local url="$1" response endpoint identifier page
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]*)$ ]]; then
    endpoint="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/issues/${BASH_REMATCH[3]}"
    response="$(perl -e 'alarm 15; exec @ARGV' gh api --hostname github.com "$endpoint" \
      2>/dev/null | head -c 65537)" || return 1
    (( ${#response} <= 65536 )) || return 1
    jq -ec --arg url "$url" \
      'select(.html_url == $url and (.pull_request == null)) | .body | strings' <<<"$response"
  elif [[ "$url" =~ ^https://linear\.app/[A-Za-z0-9_-]+/issue/([A-Za-z0-9]+-[1-9][0-9]*)(/[A-Za-z0-9_-]+)?$ ]]; then
    identifier="${BASH_REMATCH[1]}"
    [[ -n "${LINEAR_API_KEY:-}" ]] || { _design_doc_error 'LINEAR_API_KEY is required'; return 1; }
    response="$(_design_doc_http "$LINEAR_API_KEY" https://api.linear.app/graphql \
      -H 'Content-Type: application/json' --data-binary \
      "$(jq -nc --arg id "$identifier" '{query:"query($id: String!) { issue(id: $id) { url description archivedAt } }",variables:{id:$id}}')")" || return 1
    jq -ec --arg url "$url" 'select((.errors // []) | length == 0) | .data.issue |
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
    jq -ec 'select(.object == "list" and .has_more == false and
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

_design_doc_content() { # canonical URL -> provider rendering
  _design_doc_content_json "$1" | jq -er .
}

_design_doc_snapshot() { # root, URL -> exact payload and both content identities
  local body record status=0 rendered
  body="$(_design_doc_content_json "$2")" || return 1
  jq -e 'type == "string" and length > 0 and length <= 32000 and index("\u0000") == null' \
    <<<"$body" >/dev/null || return 1
  rendered="$(jq -jr . <<<"$body")" || return 1
  concise_writing_check_summary "$rendered" first 39 >&2 || return 1
  record="$(_design_doc_log_record "$1" "$2")" || status=$?
  [[ "$status" == 0 || "$status" == 2 ]] || return 1
  [[ "$status" == 0 ]] || record='{"log":""}'
  jq -nc --argjson body "$body" --argjson record "$record" --argjson present "$((status == 0))" \
    '{body:$body,log:$record.log,log_present:($present == 1)}' |
    python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/scripts/design-worker.py" snapshot
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
  printf '%s' "$body" | verdict_audit_sha256
}

# A design's identity apart from its URL spelling: a Notion title slug, a `www` host, or a
# dashed page ID names the same page, so they share one research log.
_design_doc_id() { # canonical provider URL -> design ID
  if [[ "$1" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([1-9][0-9]*)$ ]]; then
    printf 'github:%s#%s' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')" \
      "${BASH_REMATCH[2]}"
  elif [[ "$1" =~ ^https://linear\.app/[A-Za-z0-9_-]+/issue/([A-Za-z0-9]+-[1-9][0-9]*)(/[A-Za-z0-9_-]+)?$ ]]; then
    printf 'linear:%s' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$1" =~ ^https://(www\.)?notion\.so/([A-Za-z0-9_-]+/)?([A-Za-z0-9_-]*-)?([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$ ]]; then
    printf 'notion:%s' "$(printf '%s' "${BASH_REMATCH[4]//-/}" | tr '[:upper:]' '[:lower:]')"
  else
    _design_doc_error 'use a canonical GitHub issue, notion.so page, or Linear issue URL'
  fi
}

# Logs live in the clone's common directory, so every worktree of the clone sees one store
# and removing a worktree keeps them; one file per design ID.
_design_doc_log_dir() { # repository root -> research log directory
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" || return 1
  printf '%s/agent-tooling-design-log' "$common"
}

_design_doc_log_path() { # repository root, URL -> that design's log record path
  local directory id
  directory="$(_design_doc_log_dir "$1")" || return 1
  id="$(_design_doc_id "$2")" || return 1
  printf '%s/%s.json' "$directory" "$(printf '%s' "$id" | verdict_audit_sha256)"
}

# Prints the validated {id, log} record; status 2 means no log was ever stored. A record
# for another design, or anything but a bounded regular file, fails closed.
_design_doc_log_record() { # repository root, URL -> record JSON
  local path snapshot id
  path="$(_design_doc_log_path "$1" "$2")" || return 1
  id="$(_design_doc_id "$2")" || return 1
  [[ -e "$path" || -L "$path" ]] || return 2
  if snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" &&
     jq -ce --arg id "$id" 'select(type == "object" and keys == ["id","log"]
       and .id == $id and (.log | type == "string"))' <<<"${snapshot#*$'\n'}" 2>/dev/null; then
    return 0
  fi
  _design_doc_error "research log record is unreadable or malformed: $path"
  return 1
}

# The hash every verdict, advice, and deadline record binds. A design that never stored a
# log keeps its plain hash; a stored log, even the empty tombstone of a deleted one, is
# bound under a version label, so the result never equals a plain hash.
_design_doc_digest() { # repository root, URL -> content SHA-256
  _design_doc_snapshot "$1" "$2" | jq -er .content_sha256
}

# Human rendering uses the same verified capture that supplies its content identity.
_design_doc_render_snapshot() { # snapshot JSON -> design and optional research log
  local body note=''
  body="$(jq -jr .body <<<"$1")" || return 1
  if ! jq -e .log_present <<<"$1" >/dev/null; then printf '%s\n' "$body"; return; fi
  [[ -n "$(jq -jr .log <<<"$1")" ]] || note=' (deleted)'
  printf '%s\n\n## Research log (local)\n\nsha256: %s%s\n\n' "$body" \
    "$(jq -j .log <<<"$1" | verdict_audit_sha256)" "$note"
  jq -j .log <<<"$1"
}

_design_doc_jq() { # jq arguments -> jq with this library's modules on its path
  jq -L "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" "$@"
}

# The loop state for this root and branch (design-audit.jq). A missing file starts
# fresh; an unreadable or malformed one fails closed, so it cannot reset the count.
# A research-named verdict file or a record without the loop fields fails, naming the file
# to remove; removing it starts a fresh design audit.
_design_doc_audit_state() { # verdict path, root, branch
  local path="$1" snapshot record=null old="${1%/*}/agent-tooling-design-research.json"
  if [[ -e "$old" || -L "$old" ]]; then
    _design_doc_error "unsupported design verdict file; remove $old, then rerun the design audit"
    return 1
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" || return 1
    record="${snapshot#*$'\n'}"
  fi
  if _design_doc_jq -e 'include "design-audit"; da_pre_loop' <<<"$record" >/dev/null 2>&1; then
    _design_doc_error "unsupported design-audit record; remove $path, then rerun the design audit"
    return 1
  fi
  _design_doc_jq -c --arg root "$2" --arg branch "$3" \
    'include "design-audit"; da_state($root; $branch)' <<<"$record" 2>/dev/null
}

_design_doc_history_hash() { # state JSON -> SHA-256 that a reflection must bind
  jq -cS 'del(.reflection)' <<<"$1" | verdict_audit_sha256
}

_design_doc_file_hash() { # path -> SHA-256 of its bytes, or nothing when it is missing
  [[ ! -f "$1" ]] || verdict_audit_sha256 <"$1"
}

_design_doc_worker_record() { # pending path -> bounded, typed assignment record
  verdict_audit_read_regular_state "$1" 1048576 record | jq -ce '
    select(type=="object" and keys==["expires","review_deadline","role","snapshot","status","task_id","task_sha256","worker_sha256"]
      and (.role | IN("auditor","advisor")) and (.status | IN("pending","consumed","aborted"))
      and (.task_id | type=="string" and test("^[0-9a-f]{32}$"))
      and all(.task_sha256,.worker_sha256; type=="string" and test("^[0-9a-f]{64}$"))
      and all(.expires,.review_deadline; type=="number" and .>0 and .==floor)
      and .expires==.review_deadline+30 and (.snapshot | type=="object"))'
}

# Prints nothing and succeeds when an overrule, or a PASS with its advice,
# matches the live content. Otherwise prints the gate's request: the auditor's task input,
# the prior findings, the loop state and the advice status; a missing, unreadable, or
# mismatched verdict never counts.
_design_doc_audit_passed() { # verdict path, root, branch, URL, content SHA-256, exact snapshot hash
  local state request pending
  state="$(_design_doc_audit_state "$1" "$2" "$3")" || {
    _design_doc_error 'design-audit state is unreadable or malformed; inspect it before retrying'; return 1;
  }
  if [[ "${7:-}" == edit ]] && [[ "$(jq -r .verdict <<<"$state")" != OVERRIDDEN ]] \
      && [[ -e "${1%/*}/agent-tooling-design-worker.json" || -L "${1%/*}/agent-tooling-design-worker.json" ]]; then
    pending="$(_design_doc_worker_record "${1%/*}/agent-tooling-design-worker.json")" || return 1
    if jq -e --arg root "$2" --arg url "$4" '.status=="pending" and .expires>=now
        and .snapshot.root==$root and .snapshot.url==$url' <<<"$pending" >/dev/null; then
      jq -nc --arg root "$2" '{repo_root:$root,running:true}'
      return 1
    fi
  fi
  if _design_doc_jq -e 'include "design-audit";
      (.verdict | IN("PASS","FAIL")) and (da_worker_provenance("auditor") | not)' \
      <<<"$state" >/dev/null; then
    state="$(_design_doc_jq -c --arg root "$2" --arg branch "$3" 'include "design-audit";
      . as $old | da_empty($root; $branch) | .overruled=$old.overruled' <<<"$state")" || return 1
  fi
  if ! _design_doc_jq -e --arg exact "${6:-}" 'include "design-audit";
      .verdict != "PASS" or (.worker_provenance.snapshot_sha256 == $exact)' <<<"$state" >/dev/null; then
    state="$(_design_doc_jq -c --arg root "$2" --arg branch "$3" 'include "design-audit";
      . as $old | da_empty($root; $branch) | .overruled=$old.overruled' <<<"$state")" || return 1
  fi
  request="$(_design_doc_jq -c --arg root "$2" --arg url "$4" --arg digest "$5" \
    --arg history "$(_design_doc_history_hash "$state")" \
    'include "design-audit"; da_request($root; $url; $digest; $history)' <<<"$state")" || return 1
  request="$(_design_doc_advice_status "${1%/*}/agent-tooling-design-advice.json" "$2" "$3" \
    "$request")" || {
    _design_doc_error 'design advice record is unreadable or malformed; inspect it before retrying'; return 1;
  }
  if _design_doc_jq -e --arg url "$4" --arg digest "$5" \
       'include "design-audit"; da_passed($url; $digest)' <<<"$state" >/dev/null \
     && [[ "$(jq -r .advice_due <<<"$request")" != true ]]; then
    return 0
  fi
  printf '%s\n' "$request"
  return 1
}

# Adds advice_due and the recorded advice to a gate request. A PASS or FAIL for the live
# content needs one advice record bound to that verdict; a new verdict needs new advice.
_design_doc_advice_status() { # advice path, root, branch, request JSON -> request JSON
  local record=null snapshot
  if [[ -e "$1" || -L "$1" ]]; then
    snapshot="$(verdict_audit_read_json_snapshot "$1" 2>/dev/null)" || return 1
    record="${snapshot#*$'\n'}"
  fi
  _design_doc_jq -ce --arg root "$2" --arg branch "$3" --argjson record "$record" '
    include "design-audit"; . as $request
    | ($record | type == "object" and .root == $root and .branch == $branch
        and .url == $request.design_url and .content_sha256 == $request.content_sha256
        and $request.verdict_id != "" and .verdict_id == $request.verdict_id
        and (.advice | type == "array") and da_worker_provenance("advisor")
        and .worker_provenance.verdict_task_id == $request.worker_task_id) as $advised
    | . + {advice_due: ((.verdict | IN("PASS", "FAIL")) and ($advised | not)),
           advice: (if $advised then $record.advice else [] end)}' <<<"$4" 2>/dev/null
}

# Keeps an advice item only when its Why resolves: each quote without a URL appears in the
# design (whitespace-normalized), each "finding N" exists, and each file:line names a tracked
# file with that line. Skill rules and outside quotes stay unchecked.
_design_doc_advice_anchor() { # repo root, design body, findings count, advice JSON -> kept JSON
  local files kept='[]' item reason
  files="$(git -C "$1" ls-files 2>/dev/null)" || files=''
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    reason="$(DESIGN_BODY="$2" TRACKED_FILES="$files" perl -e '
      my ($item, $count, $root) = @ARGV;
      my $why = $item =~ /\bWhy:\s*(.*?)(?:\bTry:|\z)/s ? $1 : "";
      (my $body = $ENV{DESIGN_BODY}) =~ s/\s+/ /g;
      if ($why !~ m{https?://}i) {
        while ($why =~ /"([^"]+)"/g) {
          (my $quote = $1) =~ s/\s+/ /g;
          print("its quote is not in the design"), exit 0 if index($body, $quote) < 0;
        }
      }
      while ($why =~ /\bfinding\s+(\d+)/gi) {
        print("finding $1 does not exist"), exit 0 if $1 < 1 || $1 > $count;
      }
      my @files = split /\n/, $ENV{TRACKED_FILES};
      while ($why =~ m{([\w./-]+\.[A-Za-z]+):(\d+)}g) {
        my ($name, $line) = ($1, $2);
        my $found = 0;
        for my $file (grep { $_ eq $name || substr($_, -length($name) - 1) eq "/$name" } @files) {
          open(my $fh, "<", "$root/$file") or next;
          my $lines = 0; $lines++ while <$fh>; close $fh;
          if ($lines >= $line) { $found = 1; last }
        }
        print("$name:$line does not resolve"), exit 0 unless $found;
      }
    ' "$item" "$3" "$1")" || return 1
    if [[ -n "$reason" ]]; then
      printf 'design-doc: dropped advice, %s: %s\n' "$reason" "${item:0:120}" >&2
    else
      kept="$(jq -c --arg item "$item" '. + [$item]' <<<"$kept")" || return 1
    fi
  done < <(jq -r '.advice[]' <<<"$4")
  printf '%s\n' "$kept"
}

# Stores advice for the verdict that matches the live content. It never writes the verdict
# state, so advice cannot change a verdict; later audits never receive it.
_design_doc_advice_write() { # verdict path, root, branch, URL, live SHA-256, advice JSON
  local state verdict_id body kept
  jq -e --arg digest "$5" '.content_sha256 == $digest' <<<"$6" >/dev/null || {
    _design_doc_error 'the design changed after this review; advise on the current design'; return 1;
  }
  state="$(_design_doc_audit_state "$1" "$2" "$3")" || {
    _design_doc_error 'design-audit state is unreadable or malformed; inspect it before retrying'; return 1;
  }
  verdict_id="$(_design_doc_jq -r --arg url "$4" --arg digest "$5" 'include "design-audit";
    select(.url == $url and .content_sha256 == $digest) | da_verdict_id' <<<"$state")"
  [[ -n "$verdict_id" ]] || {
    _design_doc_error 'no PASS or FAIL matches the live design; advice follows a recorded verdict'; return 1;
  }
  # Advice may quote the stored log too, since the advisor reads both.
  body="$(_design_doc_render_snapshot "$design_worker_snapshot")" || {
    _design_doc_error 'cannot read the design to check advice anchors'; return 1;
  }
  kept="$(_design_doc_advice_anchor "$2" "$body" "$(jq '.findings | length' <<<"$state")" "$6")" \
    || return 1
  jq -nc --arg root "$2" --arg branch "$3" --arg url "$4" --arg digest "$5" --arg id "$verdict_id" \
    --argjson advice "$kept" --argjson proof "${design_worker_proof:-null}" \
    '{root:$root, branch:$branch, url:$url, content_sha256:$digest, verdict_id:$id, advice:$advice}
      | if $proof==null then . else .worker_provenance=$proof end' \
    | verdict_audit_write_atomic "${1%/*}/agent-tooling-design-advice.json"
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
  if [[ -n "${design_worker_proof:-}" ]]; then
    output="$(jq -c --argjson proof "$design_worker_proof" '.worker_provenance=$proof' <<<"$output")" || return 1
  fi
  printf '%s\n' "$output" | verdict_audit_write_atomic "$1"
}

_design_doc_audit_write() { # verdict path, root, branch, URL, live SHA-256, verdict JSON
  local verdict="$6"
  jq -e --arg digest "$5" '.content_sha256 == $digest' <<<"$verdict" >/dev/null || {
    _design_doc_error 'the design changed after this review; review the current design'; return 1;
  }
  if [[ "${design_worker_deadline:-}" =~ ^[1-9][0-9]*$ ]]; then
    verdict="$(jq -c --argjson deadline "$design_worker_deadline" 'if now >= $deadline
      then .deadline_review={deadline:$deadline,recorded_at:(now|floor)} else . end' <<<"$verdict")" || return 1
  fi
  _design_doc_audit_update "$1" "$2" "$3" "$4" "$5" \
    'da_record($argument | fromjson; $url; $digest)' "$verdict"
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

# Records a design advisor's advice for the verdict on the live content.
# stdin: one {content_sha256, advice} object; at most 5 one-line items of at most 500
# characters, none with a severity.
design_doc_advice_record() { # working directory -> verified URL
  local input advice
  input="$(head -c 65537)"
  (( ${#input} <= 65536 )) || { _design_doc_error 'advice is too large'; return 1; }
  advice="$(jq -cse 'if length == 1 then .[0] else empty end |
    select(type == "object" and keys == ["advice","content_sha256"]
      and (.content_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
      and (.advice | type == "array" and length <= 5 and all(.[]; type == "string"
        and length >= 1 and length <= 500 and (test("[[:cntrl:]]") | not)
        and (test("\\A\\s*(critical|high|low|nit)\\s*:"; "i") | not))))' <<<"$input" 2>/dev/null)" || {
    _design_doc_error 'advice must be one {content_sha256, advice} object: at most 5 one-line items of at most 500 characters, none starting with a severity'
    return 1
  }
  design_doc_binding advise "$1" "$advice"
}

# Stores the reflection that each audit after a converging FAIL, or after Reflect again, waits for.
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

# edit also requires an audit PASS, with its advice, for the live content; its exit 3 prints
# the gate's request instead of the URL. decide applies a human choice that a hook already
# accepted, carrying its binding through the fresh provider read; advise stores advice.
_design_doc_binding() { # caller holds the design transaction for mutations
  local operation="$1" root branch git_dir state_path audit_path snapshot url record digest design_worker_snapshot
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
    check|edit|verdict|reflect|decide|advise|show)
      snapshot="$(verdict_audit_read_json_snapshot "$state_path")" || {
        _design_doc_error 'no readable binding; register the design doc before writing code'; return 1;
      }
      record="${snapshot#*$'\n'}"
      url="$(jq -er --arg root "$root" --arg branch "$branch" \
        'select(keys == ["branch","root","url"] and .root == $root and .branch == $branch) |
         .url | strings' <<<"$record")" || {
        _design_doc_error 'document binding does not match this worktree and branch'; return 1;
      }
      snapshot="$(_design_doc_snapshot "$root" "$url")" || return 1
      digest="$(jq -er .content_sha256 <<<"$snapshot")" || return 1
      design_worker_snapshot="$snapshot"
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      case "$operation" in
        show) _design_doc_render_snapshot "$snapshot"; return ;;
        edit) _design_doc_audit_passed "$audit_path" "$root" "$branch" "$url" "$digest" \
          "$(jq -r .snapshot_sha256 <<<"$snapshot")" edit || return 3 ;;
        verdict) _design_doc_audit_write "$audit_path" "$root" "$branch" "$url" "$digest" "$3" || return 1 ;;
        reflect) _design_doc_audit_update "$audit_path" "$root" "$branch" "$url" "$digest" \
          'da_reflect($argument | fromjson; $history)' "$3" || return 1 ;;
        decide)
          jq -e --arg root "$root" --arg branch "$(git -C "$root" branch --show-current)" \
            --arg head "$(git -C "$root" rev-parse HEAD)" --arg url "$url" --arg digest "$digest" \
            '.binding | .root == $root and .branch == $branch and .head == $head
              and .url == $url and .content_sha256 == $digest' <<<"$3" >/dev/null || {
            _design_doc_error 'the design decision no longer matches this checkout and content'; return 1;
          }
          _design_doc_audit_update "$audit_path" "$root" "$branch" "$url" "$digest" \
            '($argument | fromjson) as $decision |
             if $decision.binding.history_hash != $history then error("the design decision history changed")
             else da_decide($decision.choice; $url; $digest) end' "$3" || return 1 ;;
        advise) _design_doc_advice_write "$audit_path" "$root" "$branch" "$url" "$digest" "$3" \
          || return 1 ;;
      esac
      ;;
    *) _design_doc_error 'expected bind, check, edit, verdict, reflect, decide or advise'; return 1 ;;
  esac
  printf '%s\n' "$url"
}

design_doc_binding() { design_doc_transaction "$2" binding "$@"; }

design_doc_transaction() { # root, private state operation, arguments
  local common directory script
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" || return 1
  directory="$common/agent-tooling-design-transaction"
  [[ ! -L "$directory" ]] && mkdir -p "$directory" || return 1
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd -P)/design-worker-state.sh"
  shift
  # A dedicated directory vnode avoids recursive locking of the atomic writer's anchor.
  perl -MFcntl=:DEFAULT,:flock -e '
    my $path=shift; my @before=lstat($path); exit 1 unless @before && -d _ && !-l _;
    sysopen(my $lock,$path,O_RDONLY) or exit 1;
    my @opened=stat($lock); exit 1 unless "$before[0]:$before[1]" eq "$opened[0]:$opened[1]";
    $SIG{ALRM}=sub { exit 1 }; alarm 30; flock($lock,LOCK_EX) or exit 1; alarm 0;
    fcntl($lock,F_SETFD,0) or exit 1; exec @ARGV; exit 1;
  ' "$directory" bash "$script" "$@"
}

design_doc_show() { design_doc_binding show "$1"; }

# Stores the bound design's research log from stdin. Empty input is the
# tombstone of a deleted log; the record is replaced atomically and never removed.
_design_doc_log_store() { # working directory -> verified URL; caller holds transaction
  local input url directory id
  input="$(head -c 128001; printf x)" || return 1
  input="${input%x}"
  (( ${#input} <= 32000 )) || { _design_doc_error 'research log exceeds 32,000 characters'; return 1; }
  url="$(design_doc_binding check "$1")" || return 1
  directory="$(_design_doc_log_dir "$1")" || return 1
  id="$(_design_doc_id "$url")" || return 1
  [[ -L "$directory" ]] && { _design_doc_error "research log directory is a symlink: $directory"; return 1; }
  mkdir -p "$directory" || return 1
  jq -nc --arg id "$id" --arg log "$input" '{id:$id, log:$log}' |
    verdict_audit_write_atomic "$(_design_doc_log_path "$1" "$url")" || {
    _design_doc_error "cannot store the research log under $directory; the stored log is unchanged"
    return 1
  }
  printf '%s\n' "$url"
}

design_doc_log_store() { design_doc_transaction "$1" log "$1"; }
