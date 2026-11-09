#!/usr/bin/env bash
# PreToolUse hook: keep published GitHub writing as concise as reply summaries,
# then gate `gh pr create` / `edit` / `ready` on a typed review acknowledgment.
#
# Draft PRs skip acknowledgment but must pass the writing and size checks.
#
# Flow on a missing-review denial:
#   1. Hook denies the gh tool call.
#   2. The host prompt hook records the human's typed confirmation in the
#      request bound to this checkout, target, and head.
#   3. On retry, the gate rechecks the target and consumes the request once.
#
# Design notes
# ------------
# * Matcher scope: same reason as preflight-commit-push.sh — PreToolUse matchers
#   are tool-name-only. This script does the actual `gh pr <subcmd>` filtering
#   and exits 0 immediately on unrelated bash calls.
#
# * Draft detection is deliberately canonical: `--draft`, `-d`, or an explicit
#   true value must be the first create argument, with no later draft override.
#   This avoids mistaking a dash-prefixed value consumed by another flag for an
#   option, without reimplementing gh's pflag parser.
#
# * Two deterministic content checks run before the ack gate — a Conventional-
#   Commit `--title`, and an explicit, inspectable, concise PR body
#   (CONTRIBUTING.md #commit--pr-messages). No diagram is required. A non-draft
#   create without a body fails closed; neither check consumes the acknowledgment.
#
# * One-shot consumption: the request transition is locked, so each gh pr
#   command needs a fresh acknowledgment, even at the same HEAD.
#
# Tests: bash tests/pr/preflight-pr-review.test.sh
set -euo pipefail

publish_file=0
publish_body_sha256=""
if [[ "${1:-}" == --publish-body-file ]]; then
  publish_file=1
  shift
else
  payload="$(cat)"
  command="$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.cmd // ""')"
fi
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib_dir="$tooling_root/.agents/lib"
load_failure() {  # library file name
  printf 'preflight-pr-review: cannot load %s\n' "$lib_dir/$1" >&2
  exit 2
}
# shellcheck source=../lib/shell-scan.sh
source "$lib_dir/shell-scan.sh" || load_failure shell-scan.sh
# shellcheck source=../lib/hook-host.sh
source "$lib_dir/hook-host.sh" || load_failure hook-host.sh
writing_error=""
writing_error_reminds=1
writing_loaded=0
writing_inspected_count=0

load_writing_policy() {
  (( writing_loaded == 0 )) || return 0
  local dependency
  for dependency in perl jq; do
    command -v "$dependency" >/dev/null 2>&1 || {
      printf 'preflight-pr-review: %s is required for GitHub writing checks.\n' "$dependency" >&2
      exit 2
    }
  done
  [[ -r "$lib_dir/reply-summary.pl" ]] || load_failure reply-summary.pl
  # shellcheck source=../lib/reply-summary.sh
  source "$lib_dir/reply-summary.sh" || load_failure reply-summary.sh
  # shellcheck source=../lib/github-writing.sh
  source "$lib_dir/github-writing.sh" || load_failure github-writing.sh
  # shellcheck source=../lib/concise-writing.sh
  source "$lib_dir/concise-writing.sh" || load_failure concise-writing.sh
  writing_loaded=1
}

reject_pr() {
  if (( publish_file )); then
    printf 'error: %s\n' "$1" >&2
    exit 1
  fi
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

valid_pr_session() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]{1,200}$ ]]
}

prepare_file_publication() {
  local session operation="${1:-}" path index
  local usage='Use gh-pr.sh create [--draft] or edit [selector], followed by --title TITLE --body-file PATH.'
  case "${CODEX_THREAD_ID:+codex}:${CLAUDE_CODE_SESSION_ID:+claude}" in
    codex:) export BOXLITE_HOOK_HOST=codex; session="$CODEX_THREAD_ID" ;;
    :claude) export BOXLITE_HOOK_HOST=claude; session="$CLAUDE_CODE_SESSION_ID" ;;
    *) reject_pr 'A PR body file requires one active Claude Code or Codex session.' ;;
  esac
  valid_pr_session "$session" || reject_pr 'The host session ID is invalid.'
  case "$operation" in create|edit) ;; *) reject_pr "$usage" ;; esac
  shift
  publish_args=("$operation")
  case "$operation:${1:-}" in
    create:--draft|create:-d|create:--draft=true|create:-d=true|edit:[!-]*)
      publish_args+=("$1"); shift ;;
  esac
  case "${1:-}" in
    --title|-t) (( $# >= 2 )) || reject_pr "$usage"; publish_args+=("$1" "$2"); shift 2 ;;
    --title=*|-t?*) publish_args+=("$1"); shift ;;
    *) reject_pr "$usage" ;;
  esac
  case "${1:-}" in
    --body-file|-F) (( $# >= 2 )) || reject_pr "$usage"; path="$2"; shift 2 ;;
    --body-file=*|-F=*) path="${1#*=}"; shift ;;
    -F?*) path="${1#-F}"; shift ;;
    *) reject_pr "$usage" ;;
  esac
  # shellcheck source=../lib/verdict-audit-state.sh
  source "$lib_dir/verdict-audit-state.sh" || load_failure verdict-audit-state.sh
  # shellcheck source=../lib/github-body-file.sh
  source "$lib_dir/github-body-file.sh" || load_failure github-body-file.sh
  github_body_file_error="" github_body_file_text="" github_body_file_sha256=""
  github_body_file_read "$path" 'PR body file' || reject_pr "$github_body_file_error"
  publish_body="$github_body_file_text"
  publish_body_sha256="$github_body_file_sha256"

  # The launcher already has literal argv, so no shell source needs to be built.
  shell_words=(gh pr "${publish_args[@]}" "--body=$publish_body" "$@")
  publish_args+=(--body-file=- "$@")
  for (( index=0; index<${#shell_words[@]}; index++ )); do
    shell_word_quotes[index]=1
    shell_word_dynamics[index]=0
    shell_word_unquoted_dynamics[index]=0
    shell_word_unquoted_globs[index]=0
    shell_word_redirections[index]=0
    shell_word_escapes[index]=0
  done
  payload="$(jq -nc --arg session "$session" --arg cwd "$PWD" '{session_id:$session,cwd:$cwd}')"
}

publish_checked_pr() {
  (( publish_file )) || return 0
  local arg output url status=0 gh_status checkout
  for arg in "${publish_args[@]}"; do
    case "$arg" in
      --dry-run|--dry-run=*)
        printf '%s' "$publish_body" | exec gh pr "${publish_args[@]}"
        return $? ;;
    esac
  done
  output="$(
    gh_status=0
    printf '%s' "$publish_body" | exec gh pr "${publish_args[@]}" || gh_status=$?
    printf '.'
    exit "$gh_status"
  )" || status=$?
  output="${output%.}"
  printf '%s' "$output"
  url="${output%$'\n'}"
  if (( status == 0 )) && [[ "${BOXLITE_PR_WATCH:-1}" != 0 ]]; then
    # shellcheck source=../lib/pr-watch-state.sh
    if source "$lib_dir/pr-watch-state.sh" \
       && pr_watch_url_is_valid "$url" \
       && checkout="$(pr_watch_checkout_digest "$repo_root")"; then
      printf 'boxlite-pr-write %s %s\n' "$checkout" "$url" >&2
    fi
  fi
  return "$status"
}

# Bourne-Again, its POSIX mode, the Z shell and Debian Almquist build the same argv
# around these output redirections: an optional 1 or 2, then >, >> or >| with a
# fused or separate plain target, or 1>&2-style duplication and closing. Input
# redirections can feed gh text (`-F query=@-`), and other forms split the shells, so
# both keep the command non-literal.
agreed_redirection_width=0
match_agreed_redirection() { # argv index; sets agreed_redirection_width to 1 or 2
  local index="$1" word="${shell_words[$1]}" target
  agreed_redirection_width=0
  (( shell_word_quotes[index] == 0 && shell_word_escapes[index] == 0 \
     && shell_word_dynamics[index] == 0 && shell_word_unquoted_globs[index] == 0 )) || return 1
  case "$word" in
    [12]'>&'[0-9]|[12]'>&-') agreed_redirection_width=1; return 0 ;;
    [12]'>'*) word="${word:1}" ;;
  esac
  case "$word" in
    '>>'*|'>|'*) target="${word:2}" ;;
    '>'*) target="${word:1}" ;;
    *) return 1 ;;
  esac
  # A fused operator is another redirection or a Z shell form such as >! or >>|.
  case "$target" in
    *[\<\>\&\|]*|'!'*) return 1 ;;
    ?*) agreed_redirection_width=1; return 0 ;;
  esac
  index=$((index + 1))
  (( index < ${#shell_words[@]} && shell_word_redirections[index] == 0 \
     && shell_word_dynamics[index] == 0 && shell_word_unquoted_globs[index] == 0 )) || return 1
  agreed_redirection_width=2
}

inspect_github_writing() { # first gh argument index, literal context (default 1)
  local cursor="$1" literal="${2:-1}" reason status=0
  local -a writing_argv=()
  load_writing_policy
  writing_inspected_count=$((writing_inspected_count + 1))
  while (( cursor < ${#shell_words[@]} )); do
    # Agreed redirections never reach gh's argv; any other keeps the command opaque.
    if (( shell_word_redirections[cursor] )) && match_agreed_redirection "$cursor"; then
      cursor=$((cursor + agreed_redirection_width))
      continue
    fi
    if (( shell_word_dynamics[$cursor] || shell_word_unquoted_globs[$cursor] \
       || shell_word_redirections[$cursor] )); then
      literal=0
    fi
    writing_argv+=("${shell_words[$cursor]}")
    cursor=$((cursor + 1))
  done
  reason="$(github_writing_check "$literal" ${writing_argv[@]+"${writing_argv[@]}"})" || status=$?
  if (( status )) && [[ -z "$writing_error" ]]; then
    writing_error="$reason"
    # Status 2 is an option gh itself rejects, not a writing problem.
    writing_error_reminds=$(( status == 1 ))
  fi
}

# Parse simple commands without `eval`. Keeping quotes as lexical state makes a
# separator inside title/body data inert, while every real `&&`, `;`, newline,
# grouping boundary, or command substitution gets its own argv. Bash 3.2 has no
# associative arrays, so the small parallel arrays below are intentionally plain.
protected_count=0
protected_subcmds=()
protected_drafts=()
protected_size_args=()
protected_title_count=0
protected_titles=()
protected_title_dynamics=()
protected_body_count=0
protected_body_kinds=()
protected_body_values=()
unsafe_content_expansion_count=0
invalid_create_contract_count=0
invalid_edit_contract_count=0
invalid_ready_contract_count=0
unsafe_authorization_context_count=0
command_directory=""
command_directory_count=0
opaque_protected_count=0
parsed_simple_count=0
file_launcher_count=0
ambiguous_execution_context=0
recursive_scan_depth=0
literal_assignment_count=0
literal_assignment_names=()
literal_assignment_values=()
literal_assignment_dynamics=()
record_title() {
  protected_titles[$protected_title_count]="$1"
  protected_title_dynamics[$protected_title_count]="$2"
  protected_title_count=$((protected_title_count + 1))
}

record_body() {
  protected_body_kinds[$protected_body_count]="$1"
  protected_body_values[$protected_body_count]="$2"
  protected_body_count=$((protected_body_count + 1))
}

record_literal_assignment() {
  local assignment_word="$1" assignment_dynamic="$2"
  literal_assignment_names[$literal_assignment_count]="${assignment_word%%=*}"
  literal_assignment_values[$literal_assignment_count]="${assignment_word#*=}"
  literal_assignment_dynamics[$literal_assignment_count]="$assignment_dynamic"
  literal_assignment_count=$((literal_assignment_count + 1))
}

record_file_launcher() { # argv index
  local index="$1"
  case "${shell_words[index]:-}" in
    gh-pr.sh|*/gh-pr.sh) ;;
    preflight-pr-review.sh|*/preflight-pr-review.sh)
      [[ "${shell_words[index+1]:-}" == --publish-body-file ]] || return 1 ;;
    *) return 1 ;;
  esac
  file_launcher_count=$((file_launcher_count + 1))
}

redirection_skip_index=0
skip_shell_redirections() { # argv index
  local word_count="${#shell_words[@]}" scan_word_index="$1" token operator
  while (( scan_word_index < word_count \
        && shell_word_redirections[$scan_word_index] )); do
    ambiguous_execution_context=1
    token="${shell_words[$scan_word_index]}"
    operator="$token"
    if [[ "$operator" =~ ^[0-9]+(.*)$ ]]; then
      operator="${BASH_REMATCH[1]}"
    elif [[ "$operator" =~ ^\{[A-Za-z_][A-Za-z0-9_]*\}(.*)$ ]]; then
      operator="${BASH_REMATCH[1]}"
    fi
    scan_word_index=$((scan_word_index + 1))
    case "$operator" in
      '<'|'>'|'>>'|'<<'|'<<-'|'<<<'|'<>'|'>|'|'<&'|'>&'|'&>'|'&>>')
        # The redirection target is a separate shell word, not command argv.
        (( scan_word_index >= word_count )) \
          || scan_word_index=$((scan_word_index + 1))
        ;;
    esac
  done
  redirection_skip_index="$scan_word_index"
}

is_pr_help_request() { # first argv index after create, edit or ready
  local index="$1" count="${#shell_words[@]}"
  (( count - index == 1 )) \
    || { (( count - index == 2 )) && [[ "${shell_words[$index]}" != -* ]]; } || return 1
  while (( index < count )); do
    (( shell_word_dynamics[index] == 0 && shell_word_unquoted_globs[index] == 0 \
       && shell_word_redirections[index] == 0 )) || return 1
    index=$((index + 1))
  done
  [[ "${shell_words[$((count - 1))]}" == --help || "${shell_words[$((count - 1))]}" == -h ]]
}

# Resolve only an already-literal word or an exact $name/${name} reference to
# the latest literal assignment seen in this shell source. This intentionally
# does not evaluate parameter operators, arrays, indirect expansion, or Bash
# scope; any richer spelling remains opaque.
resolved_shell_word=""
resolve_shell_word() { # argv index
  local word_index="$1" token variable_name="" assignment_index
  resolved_shell_word=""
  if (( shell_word_dynamics[$word_index] == 0 )); then
    resolved_shell_word="${shell_words[$word_index]}"
    return 0
  fi
  token="${shell_words[$word_index]}"
  if [[ "$token" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
    variable_name="${BASH_REMATCH[1]}"
  elif [[ "$token" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
    variable_name="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  assignment_index=$((literal_assignment_count - 1))
  while (( assignment_index >= 0 )); do
    if [[ "${literal_assignment_names[$assignment_index]}" == "$variable_name" ]]; then
      (( literal_assignment_dynamics[$assignment_index] == 0 )) || return 1
      resolved_shell_word="${literal_assignment_values[$assignment_index]}"
      return 0
    fi
    assignment_index=$((assignment_index - 1))
  done
  return 1
}

resolved_protected_operation() { # argv start index
  local word_count="${#shell_words[@]}" word_index="$1" token
  (( word_index < word_count )) || return 1
  resolve_shell_word "$word_index" || return 1
  case "$resolved_shell_word" in
    gh|*/gh) ;;
    *) return 1 ;;
  esac
  word_index=$((word_index + 1))
  while (( word_index < word_count )); do
    resolve_shell_word "$word_index" || return 1
    token="$resolved_shell_word"
    case "$token" in
      --repo|--hostname|-R) word_index=$((word_index + 2)); continue ;;
      --repo=*|--hostname=*|-R?*) word_index=$((word_index + 1)); continue ;;
      --) word_index=$((word_index + 1)); break ;;
      *) break ;;
    esac
  done
  (( word_index + 1 < word_count )) || return 1
  resolve_shell_word "$word_index" || return 1
  [[ "$resolved_shell_word" == pr ]] || return 1
  resolve_shell_word "$((word_index + 1))" || return 1
  [[ "$resolved_shell_word" == create \
     || "$resolved_shell_word" == edit \
     || "$resolved_shell_word" == ready ]]
}

inspect_simple_command() {
  local word_count="${#shell_words[@]}" command_index=0 index token subcmd executable
  local subcmd_index=0 github_group_index=0
  local command_slot draft=0 first_arg="" next_value="" next_quoted=0 next_dynamic=0
  local next_unquoted_glob=0
  local create_prefix_valid=1 create_scan_start=0 content_record_end="$word_count"
  local edit_prefix_valid=1 edit_scan_start=0 edit_content_mode=0
  local draft_scan_index=0
  local payload="" payload_index=0 payload_dynamic=0 wrapper="" option_flags=""
  local option_index=0 option_char="" option_needs_value=0
  local target_index=0 target_width=0 target_flag=0
  local -a target_prefix=() target_remove=()
  (( word_count > 0 )) || return 0
  # Normalize target options locally; recursive/other command scans retain their tokens.
  local -a shell_words=("${shell_words[@]}") shell_word_quotes=("${shell_word_quotes[@]}")
  local -a shell_word_dynamics=("${shell_word_dynamics[@]}") shell_word_unquoted_dynamics=("${shell_word_unquoted_dynamics[@]}")
  local -a shell_word_unquoted_globs=("${shell_word_unquoted_globs[@]}") shell_word_redirections=("${shell_word_redirections[@]}")
  local -a shell_word_escapes=("${shell_word_escapes[@]}")
  parsed_simple_count=$((parsed_simple_count + 1))

  # This is deliberately a narrow recognizer, not a Bash interpreter. A single
  # literal command may contain assignment prefixes and command/exec/env. The
  # prefixes are scanned to find protected operations, but an authorizable PR
  # command cannot mutate its executable, host, or repository context. One
  # literal absolute env directory is bound to all checkout checks below.
  while (( command_index < word_count )); do
    if [[ "${shell_words[$command_index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      record_literal_assignment "${shell_words[$command_index]}" \
        "${shell_word_dynamics[$command_index]}"
      unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
      command_index=$((command_index + 1))
      continue
    fi
    if (( shell_word_quotes[$command_index] == 0 )); then
      case "${shell_words[$command_index]}" in
        if|then|elif|else|while|until|do|'!')
          ambiguous_execution_context=1
          command_index=$((command_index + 1))
          continue
          ;;
        for|select|case|function|done|fi|'esac')
          ambiguous_execution_context=1
          return 0
          ;;
        time)
          ambiguous_execution_context=1
          command_index=$((command_index + 1))
          while (( command_index < word_count )) \
             && [[ "${shell_words[$command_index]}" == -p ]]; do
            command_index=$((command_index + 1))
          done
          if (( command_index < word_count )) \
             && [[ "${shell_words[$command_index]}" == -- ]]; then
            command_index=$((command_index + 1))
          fi
          continue
          ;;
      esac
    fi
    break
  done

  (( command_index < word_count )) || return 0
  if (( shell_word_dynamics[$command_index] )); then
    if resolved_protected_operation "$command_index"; then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( recursive_scan_depth > 0 )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( command_index + 2 < word_count )) \
       && [[ "${shell_words[$((command_index + 1))]}" == pr ]] \
       && { [[ "${shell_words[$((command_index + 2))]}" == create \
              || "${shell_words[$((command_index + 2))]}" == edit \
              || "${shell_words[$((command_index + 2))]}" == ready ]] \
            || (( shell_word_dynamics[$((command_index + 2))] )); }; then
      opaque_protected_count=$((opaque_protected_count + 1))
    fi
    return 0
  fi

  # `builtin` can expose eval/exec/command without changing their literal argv
  # spelling. Inspect those targets, but never authorize the extra wrapper: it
  # stays an execution-ambiguous context even when the nested argv is literal.
  if [[ "${shell_words[$command_index]}" == builtin ]]; then
    ambiguous_execution_context=1
    wrapper="builtin"
    command_index=$((command_index + 1))
    (( command_index < word_count )) || return 0
    if (( shell_word_dynamics[$command_index] )); then
      opaque_protected_count=$((opaque_protected_count + 1))
      return 0
    fi
    case "${shell_words[$command_index]}" in
      eval|exec|command) ;;
      *) return 0 ;;
    esac
  fi

  # `alias name='...'` does not execute its payload at definition time, but a
  # later expansion can. Inspect literal definitions to discover the protected
  # site, then reject the compound alias context before selecting an ack.
  if [[ "${shell_words[$command_index]}" == alias ]]; then
    ambiguous_execution_context=1
    payload_index=$((command_index + 1))
    while (( payload_index < word_count )); do
      token="${shell_words[$payload_index]}"
      if [[ "$token" == *=* && ${shell_word_dynamics[$payload_index]} == 0 ]]; then
        payload="${token#*=}"
        recursive_scan_depth=$((recursive_scan_depth + 1))
        shell_scan_fragment "$payload"
        recursive_scan_depth=$((recursive_scan_depth - 1))
        if [[ "$payload" =~ (^|[[:space:]])([^[:space:]]*/)?gh([[:space:]]|$) ]]; then
          # An alias may define only `gh` or `gh pr` and receive the remaining
          # protected argv at invocation time, so a partial literal prefix is
          # already opaque at this static boundary.
          opaque_protected_count=$((opaque_protected_count + 1))
        fi
      elif (( shell_word_dynamics[$payload_index] )); then
        opaque_protected_count=$((opaque_protected_count + 1))
      fi
      payload_index=$((payload_index + 1))
    done
    return 0
  fi

  # Literal eval and shell -c payloads are recursively recognized so a hidden
  # protected operation cannot pass through. They remain outside the supported
  # one-simple-command boundary and are denied if such an operation is found.
  if [[ "${shell_words[$command_index]}" == eval ]]; then
    ambiguous_execution_context=1
    payload_index=$((command_index + 1))
    while (( payload_index < word_count )); do
      (( shell_word_dynamics[$payload_index] == 0 )) || payload_dynamic=1
      [[ -z "$payload" ]] || payload+=" "
      payload+="${shell_words[$payload_index]}"
      payload_index=$((payload_index + 1))
    done
    if (( payload_dynamic )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif [[ -n "$payload" ]]; then
      recursive_scan_depth=$((recursive_scan_depth + 1))
      shell_scan_fragment "$payload"
      recursive_scan_depth=$((recursive_scan_depth - 1))
    fi
    return 0
  fi

  # Normalize only the direct, literal wrappers whose argv cardinality is
  # knowable without evaluating shell source.
  if [[ "${shell_words[$command_index]}" == command ]]; then
    wrapper="command"
    command_index=$((command_index + 1))
    while (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == -p ]]; do
      unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
      command_index=$((command_index + 1))
    done
    if (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == -- ]]; then
      command_index=$((command_index + 1))
    fi
  fi

  if (( command_index < word_count )) \
     && [[ "${shell_words[$command_index]}" == exec ]]; then
    wrapper="exec"
    command_index=$((command_index + 1))
    while (( command_index < word_count )); do
      token="${shell_words[$command_index]}"
      case "$token" in
        --) command_index=$((command_index + 1)); break ;;
        -?*)
          option_flags="${token#-}"
          [[ "$option_flags" =~ ^[cla]+$ ]] || break
          option_needs_value=0
          option_index=0
          while (( option_index < ${#option_flags} )); do
            option_char="${option_flags:$option_index:1}"
            [[ "$option_char" != a ]] || option_needs_value=1
            option_index=$((option_index + 1))
          done
          # Separate one-letter flags are the direct wrapper contract. A
          # cluster is recognized to expose the protected argv, then rejected
          # as outside that narrow authorization boundary.
          (( ${#option_flags} == 1 )) || ambiguous_execution_context=1
          command_index=$((command_index + 1))
          if (( option_needs_value )); then
            (( command_index < word_count )) || return 0
            command_index=$((command_index + 1))
          fi
          ;;
        *) break ;;
      esac
    done
  elif (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == env ]]; then
    wrapper="env"
    command_index=$((command_index + 1))
    while (( command_index < word_count )); do
      token="${shell_words[$command_index]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        command_index=$((command_index + 1))
        continue
      fi
      case "$token" in
        --) command_index=$((command_index + 1)); break ;;
        -i|--ignore-environment)
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          command_index=$((command_index + 1))
          ;;
        -C|--chdir|--chdir=*)
          if [[ "$token" == --chdir=* ]]; then
            next_value="${token#*=}"
          else
            (( command_index + 1 < word_count )) || return 0
            command_index=$((command_index + 1))
            next_value="${shell_words[$command_index]}"
          fi
          command_directory_count=$((command_directory_count + 1))
          if [[ "$next_value" == /* ]] \
             && (( command_directory_count == 1 \
               && shell_word_dynamics[command_index] == 0 \
               && shell_word_unquoted_globs[command_index] == 0 \
               && shell_word_redirections[command_index] == 0 )); then
            command_directory="$next_value"
          else
            unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          fi
          command_index=$((command_index + 1))
          ;;
        -u|-P|--unset)
          (( command_index + 1 < word_count )) || return 0
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          command_index=$((command_index + 2))
          ;;
        --unset=*)
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          command_index=$((command_index + 1))
          ;;
        -S|--split-string|--split-string=*)
          opaque_protected_count=$((opaque_protected_count + 1))
          return 0
          ;;
        -*)
          # Unknown env options can change where argv begins. If the remaining
          # source names a protected command, fail closed instead of guessing.
          payload=""
          payload_index="$command_index"
          while (( payload_index < word_count )); do
            payload+=" ${shell_words[$payload_index]}"
            payload_index=$((payload_index + 1))
          done
          if [[ "$payload" == *" gh pr create"* \
             || "$payload" == *" gh pr edit"* \
             || "$payload" == *" gh pr ready"* ]]; then
            opaque_protected_count=$((opaque_protected_count + 1))
          fi
          return 0
          ;;
        *) break ;;
      esac
    done
  fi

  (( command_index < word_count )) || return 0
  if (( shell_word_dynamics[$command_index] )); then
    if resolved_protected_operation "$command_index"; then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif [[ -n "$wrapper" ]] || (( recursive_scan_depth > 0 )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( command_index + 2 < word_count )) \
       && [[ "${shell_words[$((command_index + 1))]}" == pr ]] \
       && { [[ "${shell_words[$((command_index + 2))]}" == create \
              || "${shell_words[$((command_index + 2))]}" == edit \
              || "${shell_words[$((command_index + 2))]}" == ready ]] \
            || (( shell_word_dynamics[$((command_index + 2))] )); }; then
      opaque_protected_count=$((opaque_protected_count + 1))
    fi
    return 0
  fi

  executable="${shell_words[$command_index]}"
  if record_file_launcher "$command_index"; then
    return 0
  fi
  case "${executable##*/}" in
    source|.)
      if record_file_launcher "$((command_index + 1))"; then
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
      fi
      return 0
      ;;
    bash|sh|dash|zsh)
      if [[ -n "$pending_heredoc_delimiter" ]]; then
        pending_heredoc_executes_body=1
        ambiguous_execution_context=1
      fi
      payload_index=$((command_index + 1))
      while (( payload_index < word_count )); do
        token="${shell_words[$payload_index]}"
        case "$token" in
          --)
            if record_file_launcher "$((payload_index + 1))" && (( payload_index != command_index + 1 )); then
              unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
            fi
            return 0 ;;
          --rcfile|--init-file)
            payload_index=$((payload_index + 2))
            ;;
          --*) payload_index=$((payload_index + 1)) ;;
          -O|-o)
            payload_index=$((payload_index + 2))
            ;;
          -?*)
            option_flags="${token#-}"
            if [[ "$option_flags" == *c* ]]; then
              ambiguous_execution_context=1
              payload_index=$((payload_index + 1))
              if (( payload_index >= word_count \
                 || shell_word_dynamics[$payload_index] )); then
                opaque_protected_count=$((opaque_protected_count + 1))
              else
                payload="${shell_words[$payload_index]}"
                recursive_scan_depth=$((recursive_scan_depth + 1))
                shell_scan_fragment "$payload"
                recursive_scan_depth=$((recursive_scan_depth - 1))
              fi
              return 0
            fi
            payload_index=$((payload_index + 1))
            ;;
          *)
            if record_file_launcher "$payload_index" && (( payload_index != command_index + 1 )); then
              unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
            fi
            return 0 ;;
        esac
      done
      return 0
      ;;
  esac

  # A literal path selects the same executable boundary by its exact basename.
  # Do not broaden this to prefixes/suffixes: gh-helper and gh/tool are distinct
  # commands, while dynamic path construction was rejected above.
  case "$executable" in
    gh|*/gh) ;;
    *) return 0 ;;
  esac
  index=$((command_index + 1))
  while (( index < word_count )); do
    skip_shell_redirections "$index"
    index="$redirection_skip_index"
    (( index < word_count )) || break
    token="${shell_words[$index]}"
    case "$token" in
      --repo|-R)
        if (( index + 1 >= word_count )); then
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        else
          target_prefix+=("$token" "${shell_words[$((index + 1))]}")
          if (( shell_word_dynamics[$index] || shell_word_unquoted_globs[$index]
            || shell_word_dynamics[$((index + 1))] || shell_word_unquoted_globs[$((index + 1))] )); then
            unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          fi
        fi
        index=$((index + 2)); continue ;;
      --repo=*|-R?*)
        target_prefix+=("$token")
        if (( shell_word_dynamics[$index] || shell_word_unquoted_globs[$index] )); then
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        fi
        index=$((index + 1)); continue ;;
      --hostname)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        index=$((index + 2))
        continue
        ;;
      --hostname=*)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        index=$((index + 1))
        continue
        ;;
      --) index=$((index + 1)); break ;;
      *) break ;;
    esac
  done
  (( index < word_count )) || return 0
  if (( shell_word_dynamics[$index] \
     || shell_word_unquoted_globs[$index] )); then
    opaque_protected_count=$((opaque_protected_count + 1))
    return 0
  fi
  github_group_index="$index"
  if [[ "${shell_words[$index]}" != pr ]]; then
    inspect_github_writing "$index"
    return 0
  fi
  subcmd_index=$((index + 1))
  while (( subcmd_index < word_count )); do
    skip_shell_redirections "$subcmd_index"
    subcmd_index="$redirection_skip_index"
    (( subcmd_index < word_count )) || break
    token="${shell_words[$subcmd_index]}"
    case "$token" in
      --repo|-R)
        if (( subcmd_index + 1 >= word_count )); then
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        else
          target_prefix+=("$token" "${shell_words[$((subcmd_index + 1))]}")
          if (( shell_word_dynamics[$subcmd_index] || shell_word_unquoted_globs[$subcmd_index]
            || shell_word_dynamics[$((subcmd_index + 1))] || shell_word_unquoted_globs[$((subcmd_index + 1))] )); then
            unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          fi
        fi
        subcmd_index=$((subcmd_index + 2)) ;;
      --repo=*|-R?*)
        target_prefix+=("$token")
        if (( shell_word_dynamics[$subcmd_index] || shell_word_unquoted_globs[$subcmd_index] )); then
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        fi
        subcmd_index=$((subcmd_index + 1)) ;;
      --hostname)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        subcmd_index=$((subcmd_index + 2))
        ;;
      --hostname=*)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        subcmd_index=$((subcmd_index + 1))
        ;;
      *) break ;;
    esac
  done
  (( subcmd_index < word_count )) || return 0
  if (( shell_word_dynamics[$subcmd_index] \
     || shell_word_unquoted_globs[$subcmd_index] )); then
    opaque_protected_count=$((opaque_protected_count + 1))
    return 0
  fi
  subcmd="${shell_words[$subcmd_index]}"
  if [[ "$subcmd" != create && "$subcmd" != edit && "$subcmd" != ready ]]; then
    inspect_github_writing "$github_group_index"
    return 0
  fi
  # gh prints help and runs nothing for help alone, so `[selector] --help|-h`
  # is no transition and is claimed like other pr commands; any other argument keeps
  # the full grammar below.
  if is_pr_help_request "$((subcmd_index + 1))"; then
    inspect_github_writing "$github_group_index"
    return 0
  fi

  protected_size_args=("$subcmd" ${target_prefix[@]+"${target_prefix[@]}"} "${shell_words[@]:$((subcmd_index + 1))}")
  # Target options may occur anywhere, but a metadata/body operand is never an option.
  target_index=$((subcmd_index + 1))
  while (( target_index < word_count )); do
    skip_shell_redirections "$target_index"
    target_index="$redirection_skip_index"
    (( target_index < word_count )) || break
    token="${shell_words[$target_index]}"; target_width=1; target_flag=0
    case "$token" in
      --repo|-R|--base|-B|--head|-H) target_width=2; target_flag=1 ;;
      --repo=*|-R?*|--base=*|-B?*|--head=*|-H?*) target_flag=1 ;;
      --title|-t|--body|-b|--body-file|-F|--assignee|-a|--label|-l|--milestone|-m|--project|-p|--reviewer|-r|--add-assignee|--add-label|--add-project|--add-reviewer|--remove-assignee|--remove-label|--remove-project|--remove-reviewer) target_width=2 ;;
    esac
    if (( target_flag )); then
      case "$token" in
        --base*|-B*|--head*|-H*) [[ "$subcmd" == create ]] || target_flag=0 ;;
      esac
    fi
    if (( target_flag )); then
      for (( index=target_index; index<target_index+target_width; index++ )); do
        if (( index >= word_count || shell_word_dynamics[$index] || shell_word_unquoted_globs[$index] )); then
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        fi
        target_remove+=("$index")
      done
    fi
    target_index=$((target_index + target_width))
  done
  for index in ${target_remove[@]+"${target_remove[@]}"}; do
    unset 'shell_words[index]' 'shell_word_quotes[index]' 'shell_word_dynamics[index]' \
      'shell_word_unquoted_dynamics[index]' 'shell_word_unquoted_globs[index]' 'shell_word_redirections[index]' \
      'shell_word_escapes[index]'
  done
  shell_words=("${shell_words[@]}"); shell_word_quotes=("${shell_word_quotes[@]}")
  shell_word_dynamics=("${shell_word_dynamics[@]}"); shell_word_unquoted_dynamics=("${shell_word_unquoted_dynamics[@]}")
  shell_word_unquoted_globs=("${shell_word_unquoted_globs[@]}"); shell_word_redirections=("${shell_word_redirections[@]}")
  shell_word_escapes=("${shell_word_escapes[@]}")
  word_count="${#shell_words[@]}"; content_record_end="$word_count"
  # Writing and review must see the same draft prefix after target normalization.
  inspect_github_writing "$github_group_index"
  command_slot="$protected_count"
  index=$((subcmd_index + 1))

  # A create is authorizable only through a small argv grammar. The title and
  # body flags come first, so no earlier value-taking pflag option can consume
  # them; the tail whitelist excludes every option that can replace, synthesize,
  # or interactively edit either value after inspection.
  if [[ "$subcmd" == create ]]; then
    (( index < word_count )) && first_arg="${shell_words[$index]}"
    case "$first_arg" in
      --draft|-d|--draft=true|-d=true) draft=1 ;;
    esac
    if (( draft )); then
      draft_scan_index=$((index + 1))
      while (( draft_scan_index < word_count )); do
        token="${shell_words[$draft_scan_index]}"
        if (( shell_word_dynamics[$draft_scan_index] \
           || shell_word_unquoted_globs[$draft_scan_index] )); then
          # Even a quoted expansion is a standalone argv word and can become a
          # later --draft=false assignment after this pre-execution scan.
          draft=0
          break
        fi
        case "$token" in
          --draft|--draft=*|-d|-d=*)
            # Repeated booleans are order-sensitive in pflag. Conservatively
            # gate any later draft spelling rather than guessing whether it is
            # an override or another option's dash-prefixed value.
            draft=0
            break
            ;;
          -?*)
            if [[ "$token" != --* && "$token" == *d=* ]]; then
              # A single-dash cluster can hide an explicit -d assignment
              # (for example, -fd=false). A value such as -draft and a long
              # option such as --body or --dry-run cannot.
              draft=0
              break
            fi
            ;;
        esac
        draft_scan_index=$((draft_scan_index + 1))
      done
    fi
    if (( draft )); then
      protected_subcmds[$command_slot]="$subcmd"
      protected_drafts[$command_slot]=1
      protected_count=$((protected_count + 1))
      return 0
    fi

    create_scan_start="$index"
    # Validate only prefix shape here; the shared option loop below records and
    # checks the values once. Direct long/short forms are deterministic, while
    # mixed shorthand clusters stay outside the supported boundary.
    if (( index >= word_count )); then
      create_prefix_valid=0
    else
      token="${shell_words[$index]}"
      case "$token" in
        --title|-t)
          if (( index + 1 >= word_count \
             || shell_word_unquoted_globs[$((index + 1))] )); then
            create_prefix_valid=0
          else
            index=$((index + 2))
          fi
          ;;
        --title=*|-t=*|-t?*)
          (( shell_word_unquoted_globs[$index] == 0 )) || create_prefix_valid=0
          index=$((index + 1))
          ;;
        *) create_prefix_valid=0 ;;
      esac
    fi

    # Canonical body prefix immediately follows the title. Value safety and body
    # file binding are handled by the shared recorder and the checks below.
    if (( create_prefix_valid )); then
      if (( index >= word_count )); then
        create_prefix_valid=0
      else
        token="${shell_words[$index]}"
        case "$token" in
          --body|-b|--body-file|-F)
            if (( index + 1 >= word_count \
               || shell_word_unquoted_globs[$((index + 1))] )); then
              create_prefix_valid=0
            else
              index=$((index + 2))
            fi
            ;;
          --body=*|-b=*|-b?*|--body-file=*|-F=*|-F?*)
            (( shell_word_unquoted_globs[$index] == 0 )) || create_prefix_valid=0
            index=$((index + 1))
            ;;
          *) create_prefix_valid=0 ;;
        esac
      fi
    fi
    (( create_prefix_valid == 0 )) || content_record_end="$index"

    # Metadata that cannot change title/body or the reviewed diff may follow.
    # Each value-taking spelling advances past its operand even when that value
    # starts with '-', matching pflag and preventing a false draft/title/body hit.
    while (( create_prefix_valid && index < word_count )); do
      token="${shell_words[$index]}"
      case "$token" in
        --assignee|--label|--milestone|--project|--reviewer|-a|-l|-m|-p|-r)
          if (( index + 1 >= word_count )); then
            create_prefix_valid=0
          elif (( shell_word_unquoted_globs[$((index + 1))] )); then
            create_prefix_valid=0
          elif (( shell_word_dynamics[$((index + 1))] )) \
            && { (( shell_word_quotes[$((index + 1))] == 0 \
                 || shell_word_unquoted_dynamics[$((index + 1))] )) \
              || [[ ! "${shell_words[$((index + 1))]}" =~ ^\$[A-Za-z_][A-Za-z0-9_]*$ \
                 && ! "${shell_words[$((index + 1))]}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; }; then
            # An unquoted expansion can split into new argv options. Only an
            # exact quoted variable is provably one metadata operand here.
            create_prefix_valid=0
          else
            index=$((index + 2))
          fi
          ;;
        --assignee=*|--label=*|--milestone=*|--project=*|--reviewer=*|-a?*|-l?*|-m?*|-p?*|-r?*)
          if (( shell_word_dynamics[$index] \
             || shell_word_unquoted_globs[$index] )); then
            # Quote state is word-wide, so a mixed quoted/unquoted attached
            # expansion cannot be proven single-argv. Use a separated value.
            create_prefix_valid=0
          else
            index=$((index + 1))
          fi
          ;;
        --dry-run|--no-maintainer-edit)
          index=$((index + 1))
          ;;
        *) create_prefix_valid=0 ;;
      esac
    done
    (( create_prefix_valid )) || invalid_create_contract_count=$((invalid_create_contract_count + 1))
    index="$create_scan_start"
  elif [[ "$subcmd" == edit ]]; then
    edit_scan_start="$index"

    # A literal selector may precede edit flags. A dynamic or globbed selector
    # cannot be bound to the inspected command.
    if (( index < word_count )) && [[ "${shell_words[$index]}" != -* ]]; then
      if [[ "${shell_words[$index]}" == *://* ]] \
         || (( shell_word_dynamics[$index] \
         || shell_word_unquoted_globs[$index] )); then
        edit_prefix_valid=0
      fi
      index=$((index + 1))
    fi
    # With no explicit mutation flag gh may open an editor, whose eventual
    # title/body bytes do not exist yet at this pre-execution boundary.
    (( index < word_count )) || edit_prefix_valid=0

    # Content-changing edits use the same canonical title/body pair as create.
    # Recording is bounded to this prefix so later metadata operands cannot be
    # reinterpreted as decoy content flags by the shared recorder below.
    if (( edit_prefix_valid && index < word_count )); then
      token="${shell_words[$index]}"
      case "$token" in
        --title|-t)
          edit_content_mode=1
          if (( index + 1 >= word_count \
             || shell_word_unquoted_globs[$((index + 1))] )); then
            edit_prefix_valid=0
          else
            index=$((index + 2))
          fi
          ;;
        --title=*|-t=*|-t?*)
          edit_content_mode=1
          (( shell_word_unquoted_globs[$index] == 0 )) || edit_prefix_valid=0
          index=$((index + 1))
          ;;
      esac
    fi

    if (( edit_prefix_valid && edit_content_mode )); then
      if (( index >= word_count )); then
        edit_prefix_valid=0
      else
        token="${shell_words[$index]}"
        case "$token" in
          --body|-b|--body-file|-F)
            if (( index + 1 >= word_count \
               || shell_word_unquoted_globs[$((index + 1))] )); then
              edit_prefix_valid=0
            else
              index=$((index + 2))
            fi
            ;;
          --body=*|-b=*|-b?*|--body-file=*|-F=*|-F?*)
            (( shell_word_unquoted_globs[$index] == 0 )) || edit_prefix_valid=0
            index=$((index + 1))
            ;;
          *) edit_prefix_valid=0 ;;
        esac
      fi
      (( edit_prefix_valid == 0 )) || content_record_end="$index"
    elif (( edit_prefix_valid )); then
      # No canonical title prefix means this must remain metadata-only.
      content_record_end="$edit_scan_start"
    fi

    while (( edit_prefix_valid && index < word_count )); do
      token="${shell_words[$index]}"
      case "$token" in
        --add-assignee|--add-label|--add-project|--add-reviewer|--milestone|-m|\
        --remove-assignee|--remove-label|--remove-project|--remove-reviewer)
          if (( index + 1 >= word_count \
             || shell_word_unquoted_globs[$((index + 1))] )); then
            edit_prefix_valid=0
          elif (( shell_word_dynamics[$((index + 1))] )) \
            && { (( shell_word_quotes[$((index + 1))] == 0 \
                 || shell_word_unquoted_dynamics[$((index + 1))] )) \
              || [[ ! "${shell_words[$((index + 1))]}" =~ ^\$[A-Za-z_][A-Za-z0-9_]*$ \
                 && ! "${shell_words[$((index + 1))]}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; }; then
            edit_prefix_valid=0
          else
            index=$((index + 2))
          fi
          ;;
        --add-assignee=*|--add-label=*|--add-project=*|--add-reviewer=*|\
        --milestone=*|-m?*|--remove-assignee=*|--remove-label=*|\
        --remove-project=*|--remove-reviewer=*)
          if (( shell_word_dynamics[$index] \
             || shell_word_unquoted_globs[$index] )); then
            edit_prefix_valid=0
          else
            index=$((index + 1))
          fi
          ;;
        --remove-milestone)
          index=$((index + 1))
          ;;
        *) edit_prefix_valid=0 ;;
      esac
    done
    (( edit_prefix_valid )) || invalid_edit_contract_count=$((invalid_edit_contract_count + 1))
    index="$edit_scan_start"
  elif [[ "$subcmd" == ready ]]; then
    # Target options are normalized above. Ready retains one literal selector and boolean.
    if (( index < word_count )) && [[ "${shell_words[$index]}" != --undo ]]; then
      if [[ "${shell_words[$index]}" == -* \
         || "${shell_words[$index]}" == *://* ]] \
         || (( shell_word_dynamics[$index] \
            || shell_word_unquoted_globs[$index] )); then
        invalid_ready_contract_count=$((invalid_ready_contract_count + 1))
      fi
      index=$((index + 1))
    fi
    if (( index < word_count )) && [[ "${shell_words[$index]}" == --undo ]] \
       && (( shell_word_dynamics[$index] == 0 \
          && shell_word_unquoted_globs[$index] == 0 )); then
      index=$((index + 1))
    fi
    (( index == word_count )) \
      || invalid_ready_contract_count=$((invalid_ready_contract_count + 1))
    index=$((subcmd_index + 1))
  fi

  protected_subcmds[$command_slot]="$subcmd"
  protected_drafts[$command_slot]=0
  protected_count=$((protected_count + 1))
  while (( index < word_count && index < content_record_end )); do
    token="${shell_words[$index]}"
    next_value=""
    next_quoted=0
    next_dynamic=0
    next_unquoted_glob=0
    if (( index + 1 < word_count )); then
      next_value="${shell_words[$((index + 1))]}"
      next_quoted="${shell_word_quotes[$((index + 1))]}"
      next_dynamic="${shell_word_dynamics[$((index + 1))]}"
      next_unquoted_glob="${shell_word_unquoted_globs[$((index + 1))]}"
    fi
    case "$token" in
      --)
        break
        ;;
      --title|-t)
        # Body rules depend on whether this is a fix, so every argv spelling of
        # a supplied title must reach the same classifier. Dynamic values are
        # recorded too and fail closed in the deterministic check below.
        (( next_unquoted_glob == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "$next_value" "$next_dynamic"
        index=$((index + 2))
        continue
        ;;
      --title=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "${token#--title=}" \
          "${shell_word_dynamics[$index]}"
        ;;
      -t=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "${token#-t=}" \
          "${shell_word_dynamics[$index]}"
        ;;
      -t?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "${token#-t}" \
          "${shell_word_dynamics[$index]}"
        ;;
      --body-file|-F)
        (( next_unquoted_glob == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( next_dynamic )); then
          record_body opaque ""
        else
          record_body file "$next_value"
        fi
        index=$((index + 2))
        continue
        ;;
      --body-file=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body opaque ""
        else
          record_body file "${token#--body-file=}"
        fi
        ;;
      -F=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body opaque ""
        else
          record_body file "${token#-F=}"
        fi
        ;;
      -F?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body opaque ""
        else
          record_body file "${token#-F}"
        fi
        ;;
      --body|-b)
        (( next_unquoted_glob == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( next_quoted && next_dynamic == 0 )); then
          record_body text "$next_value"
        else
          record_body opaque ""
        fi
        index=$((index + 2))
        continue
        ;;
      --body=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body text "${token#--body=}"
        else
          record_body opaque ""
        fi
        ;;
      -b=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body text "${token#-b=}"
        else
          record_body opaque ""
        fi
        ;;
      -b?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body text "${token#-b}"
        else
          record_body opaque ""
        fi
        ;;
      --fill|--fill-first|--fill-verbose|-f)
        record_body opaque ""
        ;;
    esac
    index=$((index + 1))
  done
}

# If the direct-command recognizer did not claim this simple command, look for a
# still-visible protected argv sequence later in it. That sequence may be behind
# a launcher, leading redirection, or an executable glob. We cannot authorize
# such source, but we must not let it bypass the gate either. This is deliberately
# conservative: data that spells three separate command words should be quoted as
# one value if it is not intended for execution.
detect_visible_protected_sequence() {
  local word_count="${#shell_words[@]}" candidate_index=0 noun_index verb_index
  local executable_index=0 launcher_payload_index=-1 file_launcher_context=0 launcher_action_index
  local token launcher_basename=""
  while (( executable_index < word_count )) \
     && [[ "${shell_words[$executable_index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    executable_index=$((executable_index + 1))
  done
  skip_shell_redirections "$executable_index"
  executable_index="$redirection_skip_index"
  if (( executable_index < word_count )); then
    launcher_basename="${shell_words[$executable_index]##*/}"
  fi
  case "$launcher_basename" in
    nohup|sudo|doas|nice|stdbuf|setsid|env|xargs)
      launcher_payload_index=$((executable_index + 1))
      ;;
    timeout)
      launcher_payload_index=$((executable_index + 2))
      ;;
    source|.|bash|sh|dash|zsh|builtin|command|exec|time)
      file_launcher_context=1
      ;;
  esac
  if (( launcher_payload_index >= 0 && launcher_payload_index < word_count )) \
     && [[ "${shell_words[$launcher_payload_index]}" == -- ]]; then
    launcher_payload_index=$((launcher_payload_index + 1))
  fi
  while (( candidate_index < word_count )); do
    launcher_action_index=$((candidate_index + 1))
    if (( launcher_action_index < word_count \
          && (launcher_payload_index >= 0 || file_launcher_context || candidate_index == executable_index) )) \
       && { [[ "${shell_words[launcher_action_index]}" =~ ^(create|edit|--publish-body-file)$ ]] \
         || (( shell_word_dynamics[launcher_action_index] || shell_word_unquoted_globs[launcher_action_index] )); } \
       && record_file_launcher "$candidate_index"; then
      unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
      return 0
    fi
    token="${shell_words[$candidate_index]}"
    if [[ "${token##*/}" != gh ]]; then
      if (( candidate_index != executable_index )) \
         && (( candidate_index != launcher_payload_index )); then
        candidate_index=$((candidate_index + 1))
        continue
      fi
      if (( shell_word_dynamics[$candidate_index] == 0 \
         && shell_word_unquoted_globs[$candidate_index] == 0 )); then
        candidate_index=$((candidate_index + 1))
        continue
      fi
    fi

    # An unquoted executable-position expansion can split into the entire
    # `gh pr <verb>` prefix, so no later cue is needed to classify it as opaque.
    if (( shell_word_unquoted_dynamics[$candidate_index] \
       || shell_word_unquoted_globs[$candidate_index] )); then
      opaque_protected_count=$((opaque_protected_count + 1))
      return 0
    fi

    noun_index=$((candidate_index + 1))
    while (( noun_index < word_count )); do
      skip_shell_redirections "$noun_index"
      noun_index="$redirection_skip_index"
      (( noun_index < word_count )) || break
      token="${shell_words[$noun_index]}"
      case "$token" in
        --repo|--hostname|-R) noun_index=$((noun_index + 2)); continue ;;
        --repo=*|--hostname=*|-R?*) noun_index=$((noun_index + 1)); continue ;;
      esac
      if (( shell_word_unquoted_dynamics[$noun_index] \
         || shell_word_unquoted_globs[$noun_index] )); then
        # One expanding word can provide a global flag, its operand, and `pr`.
        opaque_protected_count=$((opaque_protected_count + 1))
        return 0
      fi
      if (( shell_word_dynamics[$noun_index] )); then
        # A quoted expansion remains one argv word, but it may be `pr` or a
        # global flag. Only classify it when a protected verb remains visible.
        verb_index=$((noun_index + 1))
        while (( verb_index < word_count )); do
          token="${shell_words[$verb_index]}"
          if [[ "$token" == create || "$token" == edit || "$token" == ready ]] \
             || (( shell_word_dynamics[$verb_index] \
                || shell_word_unquoted_globs[$verb_index] )); then
            opaque_protected_count=$((opaque_protected_count + 1))
            return 0
          fi
          verb_index=$((verb_index + 1))
        done
        break
      fi
      # An unsupported launcher may transform even literal-looking arguments.
      # Apply the same writing policy, but never authorize its published bytes.
      inspect_github_writing "$noun_index" 0
      [[ "$token" == pr ]] || break

      verb_index=$((noun_index + 1))
      while (( verb_index < word_count )); do
        skip_shell_redirections "$verb_index"
        verb_index="$redirection_skip_index"
        (( verb_index < word_count )) || break
        token="${shell_words[$verb_index]}"
        case "$token" in
          --repo|--hostname|-R) verb_index=$((verb_index + 2)); continue ;;
          --repo=*|--hostname=*|-R?*) verb_index=$((verb_index + 1)); continue ;;
        esac
        if [[ "$token" == create || "$token" == edit || "$token" == ready ]] \
           || (( shell_word_dynamics[$verb_index] \
              || shell_word_unquoted_globs[$verb_index] )); then
          opaque_protected_count=$((opaque_protected_count + 1))
          return 0
        fi
        break
      done
      break
    done
    candidate_index=$((candidate_index + 1))
  done
}

finish_simple_command() {
  local protected_before="$protected_count" opaque_before="$opaque_protected_count"
  local writing_before="$writing_inspected_count" file_launchers_before="$file_launcher_count"
  shell_scan_finish_word
  inspect_simple_command
  if (( protected_count == protected_before \
     && opaque_protected_count == opaque_before \
     && file_launcher_count == file_launchers_before \
     && writing_inspected_count == writing_before )); then
    detect_visible_protected_sequence
  fi
  shell_words=()
  shell_word_quotes=()
  shell_word_dynamics=()
  shell_word_unquoted_dynamics=()
  shell_word_unquoted_globs=()
  shell_word_redirections=()
  shell_word_escapes=()
}

if (( publish_file )); then
  prepare_file_publication "$@"
  inspect_simple_command
  (( protected_count == 1 )) || reject_pr 'The PR file launcher requires one checked create or edit.'
else
  shell_scan_fragment "$command"
fi

if (( file_launcher_count > 0 )); then
  launch_session="$(jq -er '.session_id | strings' <<<"$payload")" \
    || reject_pr 'The PR body-file launcher requires a host session.'
  inherited_session="${CODEX_THREAD_ID:-${CLAUDE_CODE_SESSION_ID:-$launch_session}}"
  if (( file_launcher_count != 1 || parsed_simple_count != 1 || ambiguous_execution_context
    || unsafe_authorization_context_count || command_directory_count || opaque_protected_count )) \
    || ! valid_pr_session "$launch_session" || [[ "$inherited_session" != "$launch_session" ]]; then
    reject_pr 'Run the PR body-file launcher directly in the current session, with no context changes or compound commands.'
  fi
  exit 0
fi

# Writing denials never request or consume a human review acknowledgment. An option
# gh would reject gets its diagnostic alone, without the writing reminder.
if [[ -n "$writing_error" ]]; then
  (( writing_error_reminds )) || reject_pr "$writing_error"
  writing_guidance="$(concise_writing_reminder)" || exit 2
  reject_pr "$writing_error

$writing_guidance"
fi

(( protected_count > 0 || opaque_protected_count > 0 )) || exit 0
subcmd=""
protected_ack_count=0
protected_index=0
while (( protected_index < protected_count )); do
  if (( protected_drafts[$protected_index] == 0 )); then
    [[ -n "$subcmd" ]] || subcmd="${protected_subcmds[$protected_index]}"
    protected_ack_count=$((protected_ack_count + 1))
  fi
  protected_index=$((protected_index + 1))
done
# A draft exemption belongs only to one direct simple create. Do not fast-exit
# before execution-shape checks: a compound command or substitution can change
# the argv after the literal draft prefix was recognized.
if [[ -z "$subcmd" ]]; then
  if (( opaque_protected_count == 0 \
     && ambiguous_execution_context == 0 \
     && parsed_simple_count == 1 )); then
    subcmd="create"
  else
    subcmd="operation"
  fi
fi

# Hosts may run hooks in the chat directory while the command targets another
# checkout. Resolve once so GitHub lookup, design, and review state agree.
working_directory="$(hook_payload_workdir "$payload" "$PWD")" \
  || reject_pr 'The shell working directory is invalid.'
cd -- "$working_directory" 2>/dev/null \
  || reject_pr 'The shell working directory is unavailable.'
if [[ -n "$command_directory" ]]; then
  cd -- "$command_directory" 2>/dev/null \
    || reject_pr 'The explicit env working directory is unavailable.'
fi
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || reject_pr 'The shell working directory is not a Git checkout.'
project_dir="${CLAUDE_PROJECT_DIR:-$repo_root}"
if [[ -n "$command_directory" ]] \
    || jq -e '[.tool_input.workdir, .tool_input.cwd, .cwd] | any(. != null)' \
    <<<"$payload" >/dev/null; then
  project_dir="$repo_root"
fi
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
request_file="$project_dir/.agents/state/pr-review-request.json"
# shellcheck source=../lib/verdict-audit-state.sh
source "$lib_dir/verdict-audit-state.sh" || load_failure verdict-audit-state.sh
# shellcheck source=../lib/subagent.sh
source "$lib_dir/subagent.sh" || load_failure subagent.sh
# shellcheck source=../lib/user-question.sh
source "$lib_dir/user-question.sh" || load_failure user-question.sh
# shellcheck source=../lib/timed-user-prompt.sh
source "$lib_dir/timed-user-prompt.sh" || load_failure timed-user-prompt.sh
# shellcheck source=../lib/pr-target.sh
source "$lib_dir/pr-target.sh" || load_failure pr-target.sh
# shellcheck source=../lib/pr-size.sh
source "$lib_dir/pr-size.sh" || load_failure pr-size.sh

# Render before selecting or consuming the acknowledgment. The same document handles
# normal denials and long-ref recovery, so the review question cannot drift out of one.
review_question="$(user_question render "$tooling_root" pr/pr-review-question)" || exit 2
if (( publish_file )); then
  review_question+=" Review body SHA-256 $publish_body_sha256."
fi
load_writing_policy
description_guidance="$(subagent_prompt pr/pr-description-guidance "$tooling_root")" || exit 2
ack_instruction="$(user_question render "$tooling_root" pr/pr-review-ack \
  "review_question=$review_question" "context= for gh pr $subcmd; bind $branch@$head")" || exit 2
bounded_ack_recovery="$(user_question render "$tooling_root" pr/pr-review-ack \
  "review_question=$review_question" "context=; the detailed diagnostic exceeded 1200 bytes")" || exit 2
if (( $(LC_ALL=C printf '%s' "$bounded_ack_recovery" | wc -c) > 1200 )); then
  printf 'preflight-pr-review: rendered pr-review-ack.md recovery exceeds 1200 bytes\n' >&2
  exit 2
fi

deny() {
  local reason="$1" reason_bytes
  reason_bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( reason_bytes > 1200 )); then
    # Fail closed without feeding an unbounded command, branch or path
    # value back into the model context.
    reason="${timer_instruction:-}
$bounded_ack_recovery"
  fi
  if (( $(LC_ALL=C printf '%s' "$reason" | wc -c) > 1200 )); then
    printf 'preflight-pr-review: combined timed recovery exceeds 1200 bytes\n' >&2
    exit 2
  fi
  reject_pr "$reason"
}

# The acknowledgment binds the current checkout's branch and HEAD. Inline
# assignments, env mutations, dynamic target flags, and inherited explicit selectors
# can make the eventual executable or remote differ from that reviewed state.
if (( unsafe_authorization_context_count > 0 )) \
   || [[ -n "${GH_REPO:-}" || -n "${GH_HOST:-}" \
      || -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" ]]; then
  deny "A protected gh pr command changes or inherits execution/target context that is not bound to the review acknowledgment.
Run it from the reviewed checkout with no inline assignments, unsupported env options,
dynamic target/--hostname flags, or inherited GH_REPO, GH_HOST, GIT_DIR, or GIT_WORK_TREE."
fi

# An expansion in the executable, `pr`, or protected-subcommand position can
# change the operation after static inspection. Never spend an acknowledgment
# on source whose runtime argv cannot be bound to the reviewed operation.
if (( opaque_protected_count > 0 )); then
  deny "A possible gh pr create/edit/ready operation is built dynamically in an executable position.
Use literal gh, pr, and subcommand words so the review gate can inspect and bind the exact operation."
fi

if (( unsafe_content_expansion_count > 0 )); then
  deny "A PR title or body contains unquoted pathname-expansion syntax.
Quote the complete value so Bash cannot replace the inspected argv before gh runs."
fi

# A bounded create grammar is safer than a partial pflag implementation. It
# binds the exact title/body values before metadata and excludes every flag that
# can synthesize, prompt for, or override either value after inspection.
if (( invalid_create_contract_count > 0 )); then
  deny "A non-draft gh pr create must start with an inspectable title and body.
Use: gh pr create --title \"type(scope): summary\" --body '<concise description>'
Safe metadata flags may follow that prefix.
Put --draft, -d, --draft=true, or -d=true first for a draft and do not override it later.
Mixed short-flag clusters and fill/editor/template/recover/web flows are outside this gate."
fi

if (( invalid_edit_contract_count > 0 )); then
  deny "A gh pr edit that changes description content must supply an inspectable title/body pair first.
Use: gh pr edit [selector] --title \"type(scope): summary\" --body '<concise description>'
Safe metadata-only edits and safe metadata following that pair are supported.
Base changes, inline environment mutation, dynamic argv splitting, and body files are outside this gate."
fi

if (( invalid_ready_contract_count > 0 )); then
  deny "A gh pr ready command has an unbound selector, option, or expansion.
Use: gh pr ready [literal-selector] [--undo]
Dynamic argv splitting and URL selectors are outside this target-bound gate."
fi

# One typed marker is a one-operation capability. A shell tool call containing
# multiple review-affecting operations cannot spend that capability atomically,
# so require separate calls before inspecting or consuming the marker.
if (( protected_ack_count > 1 )); then
  deny "Multiple non-draft gh pr operations were found in one shell command.
Run each create/edit/ready operation as a separate command so each consumes its
own typed PR-review acknowledgment. Nothing from this command was authorized."
fi

# Supported authorization boundary: exactly one top-level simple command with
# literal argv, optionally normalized through command/exec/env. Recursive shell
# source, control flow, aliases/functions, substitutions, and compound commands
# can change execution count or ordering; recognizing their protected site is
# only grounds to deny, never grounds to consume a marker.
if (( ambiguous_execution_context || parsed_simple_count != 1 )); then
  deny "A protected gh pr operation appears in compound, recursive, or execution-ambiguous shell source.
Run one direct literal gh pr create/edit/ready command per tool call (command,
exec, or env wrappers are supported). Nothing from this command was authorized."
fi

# Drafts skip title/review requirements; all PRs still require size validation.
if (( protected_ack_count > 0 )); then
# Defense in depth for the create prefix above: an interactive editor or
# repository template is outside this pre-execution boundary. Ready/edit
# operations may omit a body because they do not create one implicitly.
if [[ "$subcmd" == create ]] && (( protected_body_count == 0 )); then
  deny "A non-draft gh pr create must supply an inspectable inline --body.
The gate cannot verify content produced later by an editor or repository template.
Prepare a concise description, pass it explicitly, and retry."
fi

# Direct shell calls can reopen a changed body file after the hook returns.
# The launcher instead checks its buffer as inline text and owns the gh handoff.
body_index=0
while (( body_index < protected_body_count )); do
  if [[ "${protected_body_kinds[$body_index]}" == file ]]; then
    deny "A gh pr --body-file snapshot cannot be bound to the bytes gh reads later.
Use the guarded scripts/gh-pr.sh launcher or pass one literal inline --body value."
  fi
  body_index=$((body_index + 1))
done

# Deterministic title check: every supplied literal `--title` / `-t` spelling
# must be a Conventional-Commit subject <=72 chars. Dynamic values fail closed;
# body quality / no-narrative is still confirmed in the acknowledgment below.
title_re='^(feat|fix|docs|refactor|test|chore|perf|ci|build)(\([^)]+\))?!?:[[:space:]].+'
title_index=0
while (( title_index < protected_title_count )); do
  pr_title="${protected_titles[$title_index]}"
  title_dynamic="${protected_title_dynamics[$title_index]}"
  if ! privacy_error="$(github_writing_check_privacy "$pr_title")"; then
    deny "$privacy_error"
  fi
  if (( title_dynamic )) \
     || [[ -z "$pr_title" || ! "$pr_title" =~ $title_re ]] \
     || (( ${#pr_title} > 72 )); then
    deny "PR title must be a Conventional-Commit subject <=72 characters (got ${#pr_title}).
Use type(scope): summary; types: feat fix docs refactor test chore perf ci build.
Fix --title and retry. See CONTRIBUTING.md #commit--pr-messages."
  fi
  title_index=$((title_index + 1))
done

# Apply the same summary budget to the body already bound by the PR argv parser.
body_index=0
while (( body_index < protected_body_count )); do
  if [[ "${protected_body_kinds[$body_index]}" != text ]]; then
    deny "PR description must be inspectable literal text. Pass one quoted inline --body value."
  fi
  pr_body="${protected_body_values[$body_index]}"
  if ! body_error="$(github_writing_check_body "$pr_body")"; then
    if [[ "$pr_body" != *[![:space:]]* ]]; then
      reject_pr "$body_error
${description_guidance}"
    fi
    writing_guidance="$(concise_writing_reminder)" || exit 2
    reject_pr "$body_error

$writing_guidance"
  fi
  body_index=$((body_index + 1))
done

fi

size_context="$(jq -nc --arg root "$repo_root" --arg project "$project_dir" --arg tooling "$tooling_root" \
  --arg session "$(jq -r '.session_id // ""' <<<"$payload")" \
  '{root:$root,project:$project,tooling:$tooling,session:$session}')"
pr_target="$(pr_target_resolve "${protected_size_args[@]}")" || deny 'Cannot determine the exact PR size or target. Publish the selected head and resolve repository, ref, or API errors before retrying.'
[[ "$(jq -r .branch <<<"$pr_target")" == "$branch" && "$(jq -r .head <<<"$pr_target")" == "$head" ]] \
  || deny 'The checkout changed during PR target resolution; retry from the current branch.'
size_status=0
size_reason="$(pr_size_check "$size_context" "$pr_target" "${protected_size_args[@]}")" || size_status=$?
if (( size_status )); then
  [[ -n "$size_reason" ]] || size_reason="PR size check failed; nothing was authorized."
  # Size prompts have their own recovery; never replace them with review approval.
  reject_pr "$size_reason"
fi

# shellcheck source=../lib/design-doc.sh
source "$lib_dir/design-doc.sh" 2>/dev/null \
  || deny 'The PR description verifier is unavailable.'
# shellcheck source=../lib/pr-description.sh
source "$lib_dir/pr-description.sh" 2>/dev/null \
  || deny 'The PR description verifier is unavailable.'
description_reason="$(pr_description_check "$repo_root" "$pr_target" "${protected_size_args[@]}")" || {
  deny "${description_reason:-The PR description check failed; nothing was authorized.}"
}

if (( protected_ack_count == 0 )); then
  current_target="$(pr_target_resolve "${protected_size_args[@]}")" \
    && [[ "$current_target" == "$pr_target" ]] || deny 'PR target changed during validation; retry with the current refs.'
  publish_checked_pr
  exit 0
fi

mkdir -p "$project_dir/.agents/state" || exit 2
request_spec="$(jq -nc --arg repo "$repo_root" --arg branch "$branch" --arg head "$head" \
  --argjson target "$(pr_target_binding "$pr_target")" \
  --arg session "$(jq -r '.session_id // ""' <<<"$payload")" \
  --arg body_sha256 "$publish_body_sha256" \
  '{binding:{repo:$repo,branch:$branch,head:$head,session:$session,target:$target},prefix:"reviewed:",fallback:"keep-draft"}
   | if $body_sha256 != "" then .binding.body_sha256 = $body_sha256 else . end')"
review_request="$(timed_user_prompt request "$request_file" "$request_spec" 2>&1)" || deny "$review_request"
request_id="$(jq -er .id <<<"$review_request")" || exit 2
timer_instruction="$(user_question instruction "$tooling_root" "$review_request")" || exit 2
case "$(jq -r .status <<<"$review_request")" in
  expired) deny "Review confirmation timed out. Leave the PR in draft or uncreated." ;;
  accepted) ;;
  *) deny "$timer_instruction
$ack_instruction" ;;
esac

current_target="$(pr_target_resolve "${protected_size_args[@]}")" \
  && [[ "$current_target" == "$pr_target" ]] || deny 'PR target changed after review; retry and review the current refs.'
timed_user_prompt consume "$request_file" "$request_id" >/dev/null \
  || deny 'Review confirmation expired or was already used; nothing was authorized.'
publish_checked_pr
exit 0
