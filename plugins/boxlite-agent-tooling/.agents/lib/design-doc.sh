#!/usr/bin/env bash
# Design-doc verification, worktree binding, and the audit verdict recorded for the
# bound content. Requires jq, perl, git, curl, verdict-audit-state.sh, reply-summary.sh
# and concise-writing.sh; design_doc_audit_task also needs subagent.sh. Source only.
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
  concise_writing_check_summary "$body" first 39 >&2 || return 1
  printf '%s' "$body" | perl -MDigest::SHA=sha256_hex -0777 -e 'print sha256_hex(scalar(<STDIN>) // "")'
}

_design_doc_sha256() { # stdin -> SHA-256 hex of its exact bytes
  perl -MDigest::SHA=sha256_hex -0777 -e 'print sha256_hex(scalar(<STDIN>) // "")'
}

# Research logs live beside the bindings, one file per design URL, so registering another
# design never reads or replaces this one (design #388).
_design_doc_log_path() { # Git directory, URL -> that design's log record path
  printf '%s/agent-tooling-design-log/%s.json' "$1" "$(printf '%s' "$2" | _design_doc_sha256)"
}

# Prints the validated {url, log} record; status 2 means no log was ever stored. A record
# for another URL, or anything but a bounded regular file, fails closed.
_design_doc_log_record() { # Git directory, URL -> record JSON
  local path snapshot
  path="$(_design_doc_log_path "$1" "$2")" || return 1
  [[ -e "$path" || -L "$path" ]] || return 2
  if snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" &&
     jq -ce --arg url "$2" 'select(type == "object" and keys == ["log","url"]
       and .url == $url and (.log | type == "string"))' <<<"${snapshot#*$'\n'}" 2>/dev/null; then
    return 0
  fi
  _design_doc_error "research log record is unreadable or malformed: $path"
  return 1
}

# The hash every verdict, advice, and deadline record binds. A design that never stored a
# log keeps its plain hash; a stored log, even the empty tombstone of a deleted one, is
# bound under a version label, so the result never equals a plain hash.
_design_doc_digest() { # Git directory, URL -> content SHA-256
  local digest record status=0
  digest="$(design_doc_verify "$2")" || return 1
  record="$(_design_doc_log_record "$1" "$2")" || status=$?
  case "$status" in
    0) printf 'agent-tooling-design-log-v1\n%s\n%s\n' "$digest" \
         "$(jq -j .log <<<"$record" | _design_doc_sha256)" | _design_doc_sha256 ;;
    2) printf '%s' "$digest" ;;
    *) return 1 ;;
  esac
}

# What the auditor and advisor read: the design, then its stored log and that log's hash.
_design_doc_show_text() { # Git directory, URL -> text
  local body record status=0 note=''
  body="$(_design_doc_content "$2")" || return 1
  record="$(_design_doc_log_record "$1" "$2")" || status=$?
  case "$status" in
    2) printf '%s\n' "$body"; return 0 ;;
    0) ;;
    *) return 1 ;;
  esac
  [[ -n "$(jq -r .log <<<"$record")" ]] || note=' (deleted)'
  printf '%s\n\n## Research log (local)\n\nsha256: %s%s\n\n' "$body" \
    "$(jq -j .log <<<"$record" | _design_doc_sha256)" "$note"
  jq -j .log <<<"$record"
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

# The deadline a design agent works to: DESIGN_AUDITOR_TIMEOUT (default 900 s).
# Repeated edit attempts reuse the deadline until content or the recorded result changes.
# The task file also records the hash of the agent's record, so a stop can tell whether it landed.
_design_doc_timed_task() { # repo root, URL, content SHA-256, task file, record file -> deadline
  local timeout git_dir path now snapshot
  timeout="$(subagent_timed_timeout DESIGN_AUDITOR_TIMEOUT "${DESIGN_AUDITOR_TIMEOUT:-900}" 9999)" \
    || return 1
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)" || return 1
  path="$git_dir/$4"
  now="$(date +%s)" || return 1
  if [[ -e "$path" ]] && snapshot="$(verdict_audit_read_json_snapshot "$path" 2>/dev/null)" \
     && jq -er --arg url "$2" --arg digest "$3" --arg state "$(_design_doc_file_hash "$git_dir/$5")" \
       'select(.url == $url and .content_sha256 == $digest and .state_hash == $state
         and (.deadline | type == "number" and . > 0 and . == floor)) | .deadline' \
       <<<"${snapshot#*$'\n'}" 2>/dev/null; then
    return 0
  fi
  jq -nc --arg url "$2" --arg digest "$3" --argjson deadline "$(( now + timeout ))" \
    --arg state "$(_design_doc_file_hash "$git_dir/$5")" \
    '{url:$url, content_sha256:$digest, deadline:$deadline, state_hash:$state}' \
    | verdict_audit_write_atomic "$path" || return 1
  printf '%s\n' "$(( now + timeout ))"
}

design_doc_audit_task() { # repo root, URL, content SHA-256 -> deadline (Unix seconds)
  _design_doc_timed_task "$1" "$2" "$3" agent-tooling-design-audit-task.json \
    agent-tooling-design-audit.json
}

# The advisor works to the same timeout; its record is the advice file (design #335).
design_doc_advice_task() { # repo root, URL, content SHA-256 -> deadline (Unix seconds)
  _design_doc_timed_task "$1" "$2" "$3" agent-tooling-design-advice-task.json \
    agent-tooling-design-advice.json
}

# Prints nothing and succeeds when an overrule, or a PASS with its advice (design #335),
# matches the live content. Otherwise prints the gate's request: the auditor's task input,
# the prior findings, the loop state and the advice status; a missing, unreadable, or
# mismatched verdict never counts.
_design_doc_audit_passed() { # verdict path, root, branch, URL, content SHA-256
  local state request
  state="$(_design_doc_audit_state "$1" "$2" "$3")" || {
    _design_doc_error 'design-audit state is unreadable or malformed; inspect it before retrying'; return 1;
  }
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
  jq -ce --arg root "$2" --arg branch "$3" --argjson record "$record" '. as $request
    | ($record | type == "object" and .root == $root and .branch == $branch
        and .url == $request.design_url and .content_sha256 == $request.content_sha256
        and $request.verdict_id != "" and .verdict_id == $request.verdict_id
        and (.advice | type == "array")) as $advised
    | . + {advice_due: ((.verdict | IN("PASS", "FAIL")) and ($advised | not)),
           advice: (if $advised then $record.advice else [] end)}' <<<"$4" 2>/dev/null
}

# Keeps an advice item only when its Why resolves: each quote without a URL appears in the
# design (whitespace-normalized), each "finding N" exists, and each file:line names a tracked
# file with that line. Skill rules and outside quotes stay unchecked (design #335, after CAPRA).
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
  # Advice may quote the stored log too, since the advisor reads both (design #388).
  body="$(_design_doc_show_text "$(git -C "$2" rev-parse --absolute-git-dir)" "$4")" || {
    _design_doc_error 'cannot read the design to check advice anchors'; return 1;
  }
  kept="$(_design_doc_advice_anchor "$2" "$body" "$(jq '.findings | length' <<<"$state")" "$6")" \
    || return 1
  jq -nc --arg root "$2" --arg branch "$3" --arg url "$4" --arg digest "$5" --arg id "$verdict_id" \
    --argjson advice "$kept" \
    '{root:$root, branch:$branch, url:$url, content_sha256:$digest, verdict_id:$id, advice:$advice}' \
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
  printf '%s\n' "$output" | verdict_audit_write_atomic "$1"
}

_design_doc_audit_write() { # verdict path, root, branch, URL, live SHA-256, verdict JSON
  local verdict="$6" task previous marker
  jq -e --arg digest "$5" '.content_sha256 == $digest' <<<"$6" >/dev/null || {
    _design_doc_error 'the design changed after this review; review the current design'; return 1;
  }
  task="$(verdict_audit_read_single_record "${1%/*}/agent-tooling-design-audit-task.json" 2>/dev/null)" || task=null
  previous="$(_design_doc_audit_state "$1" "$2" "$3")" || return 1
  marker="$(printf '%s\n' "$previous" | _design_doc_jq -c --argjson task "$task" \
    --argjson verdict "$verdict" --arg url "$4" --arg digest "$5" \
    --arg state "$(_design_doc_file_hash "$1")" 'include "audit-reconciliation"; . as $previous |
    (now | floor) as $now |
    if $task.url == $url and $task.content_sha256 == $digest and $task.state_hash == $state
      and ($task.deadline | ar_timestamp) and $now >= $task.deadline
    then {deadline:$task.deadline,recorded_at:$now}
    elif $previous.url == $url and $previous.content_sha256 == $digest
      and ($previous | {content_sha256,verdict,findings,advisories}) == $verdict
    then $previous.deadline_review else null end')" || return 1
  verdict="$(jq -c --argjson marker "$marker" \
    'if $marker == null then . else . + {deadline_review:$marker} end' <<<"$verdict")" || return 1
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

# Records a design advisor's advice for the verdict on the live content (design #335).
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

# edit also requires an audit PASS, with its advice, for the live content; its exit 3 prints
# the gate's request instead of the URL. decide applies a human choice that a hook already
# accepted, carrying its binding through the fresh provider read; advise stores advice.
design_doc_binding() { # bind|check|edit|verdict|reflect|decide|advise, working directory, URL, verdict, reflection, choice or advice -> verified URL
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
    check|edit|verdict|reflect|decide|advise)
      snapshot="$(verdict_audit_read_json_snapshot "$state_path")" || {
        _design_doc_error 'no readable binding; register the design doc before writing code'; return 1;
      }
      record="${snapshot#*$'\n'}"
      url="$(jq -er --arg root "$root" --arg branch "$branch" \
        'select(keys == ["branch","root","url"] and .root == $root and .branch == $branch) |
         .url | strings' <<<"$record")" || {
        _design_doc_error 'document binding does not match this worktree and branch'; return 1;
      }
      digest="$(_design_doc_digest "$git_dir" "$url")" || return 1
      [[ "$branch" == "$(_design_doc_context "$root")" ]] || return 1
      case "$operation" in
        edit) _design_doc_audit_passed "$audit_path" "$root" "$branch" "$url" "$digest" || return 3 ;;
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

design_doc_show() { # working directory -> content of the verified binding and its log
  local url git_dir
  # Auditors read through the binder's authenticated reader; provider pages need a login.
  url="$(design_doc_binding check "$1")" || return 1
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)" || return 1
  _design_doc_show_text "$git_dir" "$url" || {
    _design_doc_error 'cannot read document (check URL, provider access, and credentials)'; return 1;
  }
}

# Stores the bound design's research log from stdin (design #388). Empty input is the
# tombstone of a deleted log; the record is replaced atomically and never removed.
design_doc_log_store() { # working directory -> verified URL
  local input url git_dir directory
  input="$(head -c 128001; printf x)" || return 1
  input="${input%x}"
  (( ${#input} <= 32000 )) || { _design_doc_error 'research log exceeds 32,000 characters'; return 1; }
  url="$(design_doc_binding check "$1")" || return 1
  git_dir="$(git -C "$1" rev-parse --absolute-git-dir)" || return 1
  directory="$git_dir/agent-tooling-design-log"
  [[ -L "$directory" ]] && { _design_doc_error "research log directory is a symlink: $directory"; return 1; }
  mkdir -p "$directory" || return 1
  jq -nc --arg url "$url" --arg log "$input" '{url:$url, log:$log}' |
    verdict_audit_write_atomic "$(_design_doc_log_path "$git_dir" "$url")" || return 1
  printf '%s\n' "$url"
}
