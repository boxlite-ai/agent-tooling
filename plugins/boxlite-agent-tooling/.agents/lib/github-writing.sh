#!/usr/bin/env bash
# GitHub text policy over literal argv supplied by the hook's shell scanner.
# Requires reply-summary.sh, concise-writing.sh, perl and jq. No file reads or writes.
# Public checks print a bounded diagnostic on rejection and return 1; success is
# silent. The caller appends the shared writing reminder and renders the host response.
# github_writing_check returns 2 instead when gh itself would reject the options, which
# is no writing problem, so that diagnostic goes out without the reminder.
# shellcheck disable=SC2154 # Policy constants are owned by sourced reply-summary.sh.

github_writing_check_privacy() { # literal published text; no transcript access
  local status=0
  # Scan the raw text, including quotes, fences and comments: GitHub stores all of
  # them. These indicators catch accidental context copies, not arbitrary secrets
  # or paraphrases. Never include a match or the input in the diagnostic.
  printf '%s' "$1" | perl -CSD -0777 -e '
    use utf8;
    my $text = <STDIN> // "";
    # Possessive whitespace runs cannot trade characters, so "<" before a long run
    # stays linear; a match must consume every space before "/" or the tag anyway.
    my $private = qr{
      (?:<|&lt;)\s*+/?\s*+(?:oai-mem-citation|hook_prompt|environment_context|user_instructions)\b
      | \b(?:as\s+you\s+(?:told|asked|said)|(?:the\s+)?user\s+(?:asked|told)\s+me)\b
      | \b(?:per|from|in|according\s+to|as\s+discussed\s+in)\s+
        (?:(?:our|your|the|a)\s+)?(?:private|internal|confidential)\s+
        (?:chat|conversation|message|email|DM|discussion)s?\b
      | \b(?:private|internal|confidential)\s+(?:chat|conversation|message|email|DM)s?\s*:
      | \b(?:user|customer|client)\s+(?:privately|confidentially)\s+(?:asked|told|said|requested)\b
      | (?:根据|按照|来自)(?:我们(?:的)?|你(?:的)?)?(?:私聊|私人(?:聊天|消息|对话)|内部(?:聊天|消息|对话))
      | (?:/Users/|/home/|[A-Z]:[\\/]Users[\\/])[^/\\\s]+[\\/]
      | \.(?:codex|claude)[\\/](?:memories|sessions|projects)[\\/]
    }ix;
    exit($text =~ $private ? 10 : 0);
  ' 2>/dev/null || status=$?
  case "$status" in
    0) return 0 ;;
    10) printf 'GitHub text contains private context indicators. Remove conversation attribution, memory citations, and local context paths; rewrite from public evidence.' ;;
    *) printf 'GitHub private context check failed; nothing was authorized.' ;;
  esac
  return 1
}

github_writing_check_body() { # body [comment]
  local body="$1" kind="${2-}" density=0
  if [[ "$body" != *[![:space:]]* ]]; then
    printf 'GitHub text is empty.'
    return 1
  fi
  # No length limit: GitHub enforces its own, and these checks stay linear (#310).
  github_writing_check_privacy "$body" || return 1
  # Complete artifacts need room for evidence, so no total word cap applies. A leading
  # TL;DR already gives readers the short version, so its details may also be dense.
  concise_writing_check_summary "$body" first 39 no-hint >/dev/null && return 0
  reply_summary_is_dense "$body" || density=$?
  # shellcheck disable=SC2016 # Render literal Markdown headings, never shell expansion.
  case "$density" in
    # The PR gate appends the shared skill reminder to every writing denial. A comment
    # within one paragraph's budget reads whole; documents keep their summary.
    1) [[ "$kind" == comment ]] && reply_summary_is_short "$body" && return 0
       concise_writing_check_summary "$body" anywhere 39 no-hint; return $? ;;
    0) printf 'GitHub text has a paragraph over %s words or a list item over %s words: shorten them, or start with `## TL;DR` and one short sentence.' \
         "$reply_summary_paragraph_max_words" "$reply_summary_item_max_words" ;;
    *) printf 'GitHub text could not be counted.' ;;
  esac
  return 1
}

_github_writing_opaque() {
  printf 'GitHub text must be inspectable before posting. Use literal --body/--notes or API body= text; prepare generated text first.'
  return 1
}

_github_writing_graphql_nonwriting() { # literal query
  # Ignore comments and string tokens before matching field calls. GraphQL also
  # permits commas and BOMs between tokens; hashes inside strings are not comments.
  # https://spec.graphql.org/September2025/#sec-Language.Source-Text.Ignored-Tokens
  printf '%s' "$1" | perl -CS -0777 -e '
    my $query = <STDIN> // "";
    $query =~ s{
      \#[^\r\n]*
      | """ (?: \\""" | (?! """) [\s\S] )* """
      | " (?: \\[\s\S] | [^"\\] )* "
    }{ }gx;
    exit($query =~ /\b(?:addComment|updateIssueComment|createIssue|updateIssue|updatePullRequest|addPullRequestReview|addPullRequestReviewComment|addPullRequestReviewThread|updatePullRequestReview|updatePullRequestReviewComment|submitPullRequestReview|createDiscussion|updateDiscussion|addDiscussionComment|updateDiscussionComment)[\s,\x{FEFF}]*\(/ ? 1 : 0);
  '
}

# gh 2.92.0 options per covered command, as `gh help <command>` lists them: `long` is a
# boolean, `long=` takes a value, and `s/` adds its shorthand. Every command inherits
# the boolean --help; none defines -h, which pflag then reads as a help request.
# When gh adds options, regenerate these lines from `gh help` (#308).
_github_writing_spec() { # group:operation -> spec
  case "$1" in
    api:*) printf '%s' 'F/field= H/header= X/method= cache= f/raw-field= help hostname= i/include input= p/preview= paginate q/jq= silent slurp t/template= verbose' ;;
    issue:create) printf '%s' 'F/body-file= R/repo= T/template= a/assignee= b/body= e/editor help l/label= m/milestone= p/project= recover= t/title= w/web' ;;
    issue:comment|pr:comment) printf '%s' 'F/body-file= R/repo= b/body= create-if-none delete-last e/editor edit-last help w/web yes' ;;
    issue:edit) printf '%s' 'F/body-file= R/repo= add-assignee= add-label= add-project= b/body= help m/milestone= remove-assignee= remove-label= remove-milestone remove-project= t/title=' ;;
    issue:close) printf '%s' 'R/repo= c/comment= duplicate-of= help r/reason=' ;;
    issue:reopen|pr:reopen) printf '%s' 'R/repo= c/comment= help' ;;
    pr:create) printf '%s' 'B/base= F/body-file= H/head= R/repo= T/template= a/assignee= b/body= d/draft dry-run e/editor f/fill fill-first fill-verbose help l/label= m/milestone= no-maintainer-edit p/project= r/reviewer= recover= t/title= w/web' ;;
    pr:review) printf '%s' 'F/body-file= R/repo= a/approve b/body= c/comment help r/request-changes' ;;
    pr:close) printf '%s' 'R/repo= c/comment= d/delete-branch help' ;;
    release:create) printf '%s' 'F/notes-file= R/repo= d/draft discussion-category= fail-on-no-commits generate-notes help latest n/notes= notes-from-tag notes-start-tag= p/prerelease t/title= target= verify-tag' ;;
    release:edit) printf '%s' 'F/notes-file= R/repo= discussion-category= draft help latest n/notes= prerelease t/title= tag= target= verify-tag' ;;
    # gh 2.92.0 has no discussion command; keep the options this check accepted before.
    discussion:*) printf '%s' 'B/base= F/body-file= H/head= R/repo= T/template= a/assignee= add-assignee= add-label= add-project= add-reviewer= approve b/body= c/comment= category= create-if-none d/draft delete-branch delete-last discussion-category= discussion-id= dry-run e/editor edit-last f/fill fail-on-no-commits fill-first fill-verbose generate-notes help hostname= l/label= latest m/milestone= n/notes= no-maintainer-edit notes-file= notes-from-tag notes-start-tag= p/prerelease project= r/reviewer= reason= recover= remove-assignee= remove-label= remove-milestone remove-project= remove-reviewer= request-changes t/title= target= verify-tag w/web yes' ;;
  esac
}

_github_writing_bool() { # value -> true or false, as Go's strconv.ParseBool reads it
  case "$1" in
    1|t|T|true|TRUE|True) printf true ;;
    0|f|F|false|FALSE|False) printf false ;;
    *) return 1 ;;
  esac
}

_github_writing_option_error() { # command label, option shown (may be empty), problem (empty: unknown)
  local subject="$1 option"
  [[ -z "$2" ]] || subject+=" \`$2\`"
  if [[ -n "$3" ]]; then printf '%s %s' "$subject" "$3"; else printf 'Unrecognized %s' "$subject"; fi
  # shellcheck disable=SC2016 # Literal Markdown code span, never shell expansion.
  printf '; nothing was authorized. Check `gh help %s`.' "${1#gh }"
}

# Read argv as pflag v1.0.10 does (flag.go:980-1160): --name, --name=value, -x value,
# -xvalue, -x=value and grouped shorthands such as -iq; `--` ends options; other words
# are operands. Options go to _github_writing_options as name=value, in order, and
# operands to _github_writing_operands. Returns 2 when gh would print help instead
# of running: a reached -h, or a final --help that is true.
_github_writing_parse() { # command label, spec, argv...
  local label="$1" spec=" $2 " token name value has_value shorts letter entry help=false
  shift 2
  _github_writing_options=()
  _github_writing_operands=()
  while (( $# )); do
    token="$1"; shift
    case "$token" in
      --) _github_writing_operands+=("$@"); break ;;
      --*)
        name="${token#--}"; value=""; has_value=0
        if [[ "$name" == *=* ]]; then value="${name#*=}"; name="${name%%=*}"; has_value=1; fi
        # Name only spellings gh could define, so the diagnostic never echoes data.
        if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,39}$ ]]; then
          _github_writing_option_error "$label" '' ''; return 1
        elif [[ "$spec" == *" $name "* || "$spec" == *"/$name "* ]]; then
          (( has_value )) || value=true
          value="$(_github_writing_bool "$value")" || {
            _github_writing_option_error "$label" "--$name" 'takes true or false'; return 1; }
        elif [[ "$spec" == *" $name= "* || "$spec" == *"/$name= "* ]]; then
          if (( !has_value )); then
            (( $# )) || { _github_writing_option_error "$label" "--$name" 'needs a value'; return 1; }
            value="$1"; shift
          fi
        else
          _github_writing_option_error "$label" "--$name" ''; return 1
        fi
        [[ "$name" != help ]] || help="$value"
        _github_writing_options+=("$name=$value") ;;
      -?*)
        shorts="${token#-}"
        while [[ -n "$shorts" ]]; do
          # pflag skips the rest of a cluster that starts like a Go test flag (-test.v).
          [[ "$shorts" != test.* ]] || break
          letter="${shorts:0:1}"; shorts="${shorts:1}"
          if [[ "$letter" != [A-Za-z0-9] ]]; then
            _github_writing_option_error "$label" '' ''; return 1
          elif [[ "$spec" != *" $letter/"* ]]; then
            [[ "$letter" != h ]] || return 2
            _github_writing_option_error "$label" "-$letter" ''; return 1
          fi
          entry="${spec#* "$letter"/}"; entry="${entry%% *}"; name="${entry%=}"
          if [[ "$shorts" == =?* ]]; then
            value="${shorts#=}"; shorts=""
          elif [[ "$entry" != *= ]]; then
            value=true
          elif [[ -n "$shorts" ]]; then
            value="$shorts"; shorts=""
          elif (( $# )); then
            value="$1"; shift
          else
            _github_writing_option_error "$label" "-$letter" 'needs a value'; return 1
          fi
          if [[ "$entry" != *= ]]; then
            value="$(_github_writing_bool "$value")" || {
              _github_writing_option_error "$label" "-$letter" 'takes true or false'; return 1; }
          fi
          [[ "$name" != help ]] || help="$value"
          _github_writing_options+=("$name=$value")
        done ;;
      *) _github_writing_operands+=("$token") ;;
    esac
  done
  [[ "$help" != true ]] || return 2
}

_github_writing_api() { # literal-argv(0|1), api argv
  local literal="$1" option name value key method="" endpoint="" query="" input=0 has_fields=0 kind=""
  local bodies=() titles=() body_count=0 title_count=0
  shift
  _github_writing_parse 'gh api' "$(_github_writing_spec api:)" "$@"
  case $? in
    1) return 2 ;;
    # gh prints help and sends nothing, but a dynamic word could consume the flag.
    2) (( !literal )) || return 0
       _github_writing_opaque; return 1 ;;
  esac
  for option in ${_github_writing_options[@]+"${_github_writing_options[@]}"}; do
    name="${option%%=*}"; value="${option#*=}"
    case "$name" in
      method) method="$value" ;;
      input) input=1 ;;
      field|raw-field)
        has_fields=1
        key="${value%%=*}"; value="${value#*=}"
        case "$key" in
          query) query="$value" ;;
          title|*'[title]')
            if [[ "$name" == field && "$value" == @* ]]; then
              input=1
            else
              titles[title_count]="$value"; title_count=$((title_count + 1))
            fi ;;
          body|bodyText|description|notes|*'[body]'|*'[bodyText]'|*'[description]')
            if [[ "$name" == field && "$value" == @* ]]; then
              input=1
            else
              bodies[body_count]="$value"; body_count=$((body_count + 1))
            fi ;;
        esac ;;
    esac
  done
  for value in ${_github_writing_operands[@]+"${_github_writing_operands[@]}"}; do
    endpoint="$value"
  done
  case "$method" in GET|HEAD|OPTIONS|DELETE) return 0 ;; esac
  # Without fields/input gh defaults to GET, even with a dynamic endpoint.
  if [[ -z "$method" ]] && (( !has_fields && !input )); then return 0; fi
  (( literal )) || { _github_writing_opaque; return 1; }
  if [[ "$endpoint" == graphql ]]; then
    # GraphQL can bury published text in a query or arbitrary variable names.
    # Only text-publishing mutations need the REST/CLI form; resolving a review
    # thread, for example, does not publish prose and stays outside this policy.
    if (( input )) || ! _github_writing_graphql_nonwriting "$query"; then
      _github_writing_opaque; return 1
    fi
    return 0
  fi
  # API fields imply POST unless --method says otherwise. Restrict opaque-input
  # rejection to endpoints which can publish writing, not arbitrary API work.
  if (( input )) && [[ "$endpoint" =~ (^|/)(issues|pulls|comments|releases|discussions)(/|$|\?) ]]; then
    _github_writing_opaque; return 1
  fi
  (( has_fields )) || return 0
  # Only the path after repos/OWNER/REPO names the resource; owners and repos may be
  # called comments too.
  [[ "$endpoint" =~ (^|/)repos/[^/]+/[^/]+/(.+)$ ]] \
    && [[ "${BASH_REMATCH[2]}" =~ (^|/)(comments|replies|reviews)(/|$|\?) ]] \
    && kind=comment
  for value in ${bodies[@]+"${bodies[@]}"}; do
    github_writing_check_body "$value" "$kind" || return 1
  done
  for value in ${titles[@]+"${titles[@]}"}; do
    github_writing_check_privacy "$value" || return 1
  done
}

github_writing_check() { # literal-argv(0|1), gh arguments after global options
  local literal="$1" group="${2-}" operation="${3-}" option name value kind=""
  local required=0 has_body=0 has_option=0 deleting=0
  shift
  # gh persistent flags can occur between its noun and verb as well as before it.
  if [[ "$group" != api ]]; then
    shift
    while (( $# )); do
      case "$1" in
        --repo|-R|--hostname) (( $# >= 2 )) || return 0; shift 2 ;;
        --repo=*|-R?*|--hostname=*) shift ;;
        *) break ;;
      esac
    done
    operation="${1-}"
    set -- "$group" "$@"
  fi
  case "$group:$operation" in
    pr:create)
      # Non-draft create/edit already have a stricter parser in the review gate;
      # that path calls check_body too. Drafts need writing checks without an ack.
      case "${3-}" in --draft|-d|--draft=true|-d=true) ;; *) return 0 ;; esac
      required=1 ;;
    pr:edit|pr:ready) return 0 ;;
    issue:create|discussion:create|release:create) required=1 ;;
    pr:comment|issue:comment|discussion:comment) required=1; kind=comment ;;
    issue:edit|discussion:edit|release:edit) ;;
    pr:review) kind=comment ;;
    pr:close|issue:close|pr:reopen|issue:reopen) has_option=1; kind=comment ;;
    api:*)
      shift
      _github_writing_api "$literal" "$@"
      return $? ;;
    *) return 0 ;;
  esac
  (( literal )) || { _github_writing_opaque; return 1; }
  shift 2
  _github_writing_parse "gh $group $operation" "$(_github_writing_spec "$group:$operation")" "$@"
  case $? in
    1) return 2 ;;
    2) return 0 ;; # gh prints help and runs nothing.
  esac
  for option in ${_github_writing_options[@]+"${_github_writing_options[@]}"}; do
    name="${option%%=*}"; value="${option#*=}"
    has_option=1
    case "$name" in
      title) github_writing_check_privacy "$value" || return 1 ;;
      body|notes|comment)
        # --comment is a boolean on pr review and text on close/reopen.
        if [[ "$group:$operation" == pr:review && "$name" == comment ]]; then
          [[ "$value" != true ]] || required=1
          continue
        fi
        github_writing_check_body "$value" "$kind" || return 1
        has_body=1 ;;
      body-file|notes-file|template|recover) _github_writing_opaque; return 1 ;;
      editor|web|fill|fill-first|fill-verbose|generate-notes|notes-from-tag)
        [[ "$value" != true ]] || { _github_writing_opaque; return 1; } ;;
      delete-last) [[ "$value" != true ]] || deleting=1 ;;
    esac
  done
  if (( (required && !has_body && !deleting) || !has_option )); then
    _github_writing_opaque; return 1
  fi
  return 0
}
