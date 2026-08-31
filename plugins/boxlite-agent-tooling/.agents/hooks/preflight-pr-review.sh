#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr create` / `gh pr edit` / `gh pr ready` on a
# user-TYPED acknowledgment that they have reviewed the PR.
#
# `gh pr create --draft` (and `-d`) is intentionally excluded — draft PRs are
# not yet requesting review, so no ack is required.
#
# Flow on a denied attempt:
#   1. Hook denies the gh tool call.
#   2. Reason text instructs the parent agent to obtain a TYPED confirmation
#      from the human (not a yes/no click) and persist it verbatim to
#      .agents/state/pr-reviewed.json bound to current branch + HEAD.
#   3. Parent retries -> hook validates the marker and allows on match.
#
# Wired in .claude/settings.json under hooks.PreToolUse with matcher "Bash".
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
#   Commit `--title`, and an explicit, inspectable PR body carrying the
#   before/after call graph (CONTRIBUTING.md #commit--pr-messages). A non-draft
#   create without a body fails closed; neither check consumes the ack marker.
#
# * One-shot consumption: the marker file is `rm -f`'d on the allow path so
#   each successive gh pr command forces a fresh ack, even at the same HEAD.
#   Mirrors the trade-off in preflight-commit-push.sh.
#
# Tests: bash .agents/hooks/preflight-pr-review.test.sh
set -euo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

# Parse simple commands without `eval`. Keeping quotes as lexical state makes a
# separator inside title/body data inert, while every real `&&`, `;`, newline,
# grouping boundary, or command substitution gets its own argv. Bash 3.2 has no
# associative arrays, so the small parallel arrays below are intentionally plain.
protected_count=0
protected_subcmds=()
protected_drafts=()
protected_title_count=0
protected_title_commands=()
protected_titles=()
protected_title_dynamics=()
protected_body_count=0
protected_body_commands=()
protected_body_kinds=()
protected_body_values=()
unsafe_content_expansion_count=0
invalid_create_contract_count=0
invalid_edit_contract_count=0
invalid_ready_contract_count=0
unsafe_authorization_context_count=0
opaque_protected_count=0
parsed_simple_count=0
ambiguous_execution_context=0
recursive_scan_depth=0
literal_assignment_count=0
literal_assignment_names=()
literal_assignment_values=()
literal_assignment_dynamics=()
record_title() {
  protected_title_commands[$protected_title_count]="$1"
  protected_titles[$protected_title_count]="$2"
  protected_title_dynamics[$protected_title_count]="$3"
  protected_title_count=$((protected_title_count + 1))
}

record_body() {
  protected_body_commands[$protected_body_count]="$1"
  protected_body_kinds[$protected_body_count]="$2"
  protected_body_values[$protected_body_count]="$3"
  protected_body_count=$((protected_body_count + 1))
}

record_literal_assignment() {
  local assignment_word="$1" assignment_dynamic="$2"
  literal_assignment_names[$literal_assignment_count]="${assignment_word%%=*}"
  literal_assignment_values[$literal_assignment_count]="${assignment_word#*=}"
  literal_assignment_dynamics[$literal_assignment_count]="$assignment_dynamic"
  literal_assignment_count=$((literal_assignment_count + 1))
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
  local subcmd_index=0
  local command_slot draft=0 first_arg="" next_value="" next_quoted=0 next_dynamic=0
  local next_unquoted_glob=0
  local create_prefix_valid=1 create_scan_start=0 content_record_end="$word_count"
  local edit_prefix_valid=1 edit_scan_start=0 edit_content_mode=0
  local draft_scan_index=0
  local payload="" payload_index=0 payload_dynamic=0 wrapper="" option_flags=""
  local option_index=0 option_char="" option_needs_value=0
  (( word_count > 0 )) || return 0
  parsed_simple_count=$((parsed_simple_count + 1))

  # This is deliberately a narrow recognizer, not a Bash interpreter. A single
  # literal command may contain assignment prefixes and command/exec/env. The
  # prefixes are scanned to find protected operations, but an authorizable PR
  # command cannot mutate its executable, checkout, host, or repository context.
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
        scan_command_fragment "$payload"
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
      scan_command_fragment "$payload"
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
        -u|-C|-P|--unset|--chdir)
          (( command_index + 1 < word_count )) || return 0
          unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
          command_index=$((command_index + 2))
          ;;
        --unset=*|--chdir=*)
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
  case "${executable##*/}" in
    bash|sh)
      if [[ -n "$pending_heredoc_delimiter" ]]; then
        pending_heredoc_executes_body=1
        ambiguous_execution_context=1
      fi
      payload_index=$((command_index + 1))
      while (( payload_index < word_count )); do
        token="${shell_words[$payload_index]}"
        case "$token" in
          --) return 0 ;;
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
                scan_command_fragment "$payload"
                recursive_scan_depth=$((recursive_scan_depth - 1))
              fi
              return 0
            fi
            payload_index=$((payload_index + 1))
            ;;
          *) return 0 ;;
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
      --repo|--hostname|-R)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        index=$((index + 2))
        continue
        ;;
      --repo=*|--hostname=*|-R?*)
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
  [[ "${shell_words[$index]}" == pr ]] || return 0
  subcmd_index=$((index + 1))
  while (( subcmd_index < word_count )); do
    skip_shell_redirections "$subcmd_index"
    subcmd_index="$redirection_skip_index"
    (( subcmd_index < word_count )) || break
    token="${shell_words[$subcmd_index]}"
    case "$token" in
      --repo|--hostname|-R)
        unsafe_authorization_context_count=$((unsafe_authorization_context_count + 1))
        subcmd_index=$((subcmd_index + 2))
        ;;
      --repo=*|--hostname=*|-R?*)
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
  [[ "$subcmd" == create || "$subcmd" == edit || "$subcmd" == ready ]] \
    || return 0

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

    # A literal selector may precede edit flags. It is kept for compatibility,
    # but a dynamic/globbed selector cannot be bound to the inspected command.
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
    # Ready has one literal optional selector and one optional boolean. Persistent
    # repository flags, extra operands, and expansions can retarget the operation
    # after the branch/HEAD acknowledgment and therefore stay outside the gate.
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
        record_title "$command_slot" "$next_value" "$next_dynamic"
        index=$((index + 2))
        continue
        ;;
      --title=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "$command_slot" "${token#--title=}" \
          "${shell_word_dynamics[$index]}"
        ;;
      -t=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "$command_slot" "${token#-t=}" \
          "${shell_word_dynamics[$index]}"
        ;;
      -t?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        record_title "$command_slot" "${token#-t}" \
          "${shell_word_dynamics[$index]}"
        ;;
      --body-file|-F)
        (( next_unquoted_glob == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( next_dynamic )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "$next_value"
        fi
        index=$((index + 2))
        continue
        ;;
      --body-file=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "${token#--body-file=}"
        fi
        ;;
      -F=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "${token#-F=}"
        fi
        ;;
      -F?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( shell_word_dynamics[$index] )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "${token#-F}"
        fi
        ;;
      --body|-b)
        (( next_unquoted_glob == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( next_quoted && next_dynamic == 0 )); then
          record_body "$command_slot" text "$next_value"
        else
          record_body "$command_slot" opaque ""
        fi
        index=$((index + 2))
        continue
        ;;
      --body=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body "$command_slot" text "${token#--body=}"
        else
          record_body "$command_slot" opaque ""
        fi
        ;;
      -b=*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body "$command_slot" text "${token#-b=}"
        else
          record_body "$command_slot" opaque ""
        fi
        ;;
      -b?*)
        (( shell_word_unquoted_globs[$index] == 0 )) \
          || unsafe_content_expansion_count=$((unsafe_content_expansion_count + 1))
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body "$command_slot" text "${token#-b}"
        else
          record_body "$command_slot" opaque ""
        fi
        ;;
      --fill|--fill-first|--fill-verbose|-f)
        record_body "$command_slot" opaque ""
        ;;
    esac
    index=$((index + 1))
  done
}

finish_shell_word() {
  local completed_word completed_quoted completed_escaped
  (( shell_word_started )) || return 0
  completed_word="$shell_word"
  completed_quoted="$shell_word_quoted"
  completed_escaped="$shell_word_escaped"
  shell_words[${#shell_words[@]}]="$shell_word"
  shell_word_quotes[${#shell_word_quotes[@]}]="$shell_word_quoted"
  shell_word_dynamics[${#shell_word_dynamics[@]}]="$shell_word_dynamic"
  shell_word_unquoted_dynamics[${#shell_word_unquoted_dynamics[@]}]="$shell_word_unquoted_dynamic"
  shell_word_unquoted_globs[${#shell_word_unquoted_globs[@]}]="$shell_word_unquoted_glob"
  shell_word_redirections[${#shell_word_redirections[@]}]="$shell_word_redirection"
  shell_word=""
  shell_word_started=0
  shell_word_quoted=0
  shell_word_dynamic=0
  shell_word_unquoted_dynamic=0
  shell_word_unquoted_glob=0
  shell_word_redirection=0
  shell_word_escaped=0
  if (( heredoc_expect )); then
    pending_heredoc_delimiter="$completed_word"
    pending_heredoc_expands=$(( completed_quoted == 0 && completed_escaped == 0 ))
    heredoc_expect=0
  elif [[ "$completed_word" =~ ^[0-9]*\<\<(-?)(.*)$ \
       && "${BASH_REMATCH[2]}" != \<* ]]; then
    heredoc_strip_tabs=0
    [[ "${BASH_REMATCH[1]}" != - ]] || heredoc_strip_tabs=1
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      pending_heredoc_delimiter="${BASH_REMATCH[2]}"
      pending_heredoc_expands=$(( completed_quoted == 0 && completed_escaped == 0 ))
    else
      heredoc_expect=1
    fi
  fi
}

# If the direct-command recognizer did not claim this simple command, look for a
# still-visible protected argv sequence later in it. That sequence may be behind
# a launcher, leading redirection, or an executable glob. We cannot authorize
# such source, but we must not let it bypass the gate either. This is deliberately
# conservative: data that spells three separate command words should be quoted as
# one value if it is not intended for execution.
detect_visible_protected_sequence() {
  local word_count="${#shell_words[@]}" candidate_index=0 noun_index verb_index
  local executable_index=0 launcher_payload_index=-1
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
  esac
  if (( launcher_payload_index >= 0 && launcher_payload_index < word_count )) \
     && [[ "${shell_words[$launcher_payload_index]}" == -- ]]; then
    launcher_payload_index=$((launcher_payload_index + 1))
  fi
  while (( candidate_index < word_count )); do
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
  finish_shell_word
  inspect_simple_command
  if (( protected_count == protected_before \
     && opaque_protected_count == opaque_before )); then
    detect_visible_protected_sequence
  fi
  shell_words=()
  shell_word_quotes=()
  shell_word_dynamics=()
  shell_word_unquoted_dynamics=()
  shell_word_unquoted_globs=()
  shell_word_redirections=()
}

# `$()` source is executable even when its surrounding word is double quoted.
# Extract it without executing, mark the outer word uninspectable, and scan the
# nested source as its own command fragment. Single quotes and escaped dollars
# never call this path, so literal examples remain inert.
scan_dollar_substitution() {
  local sub_start=$((scan_index + 2)) sub_index="$((scan_index + 2))"
  local sub_depth=1 sub_quote="" sub_escaped=0 sub_comment=0 sub_char=""
  local sub_source=""
  while (( sub_index < scan_length )); do
    sub_char="${command_fragment:$sub_index:1}"
    if (( sub_comment )); then
      [[ "$sub_char" == $'\n' ]] && sub_comment=0
    elif (( sub_escaped )); then
      sub_escaped=0
    elif [[ "$sub_quote" == "'" ]]; then
      [[ "$sub_char" == "'" ]] && sub_quote=""
    elif [[ "$sub_quote" == '"' ]]; then
      case "$sub_char" in
        '"') sub_quote="" ;;
        \\)
          if (( sub_index + 1 < scan_length )); then
            case "${command_fragment:$((sub_index + 1)):1}" in
              '$'|'`'|'"'|\\|$'\n') sub_escaped=1 ;;
            esac
          fi
          ;;
      esac
    else
      case "$sub_char" in
        \\) sub_escaped=1 ;;
        "'"|'"') sub_quote="$sub_char" ;;
        '#') sub_comment=1 ;;
        '(') sub_depth=$((sub_depth + 1)) ;;
        ')')
          sub_depth=$((sub_depth - 1))
          (( sub_depth > 0 )) || break
          ;;
      esac
    fi
    sub_index=$((sub_index + 1))
  done
  sub_source="${command_fragment:$sub_start:$((sub_index - sub_start))}"
  shell_word_started=1
  shell_word_dynamic=1
  [[ "$scan_quote" == '"' ]] || shell_word_unquoted_dynamic=1
  scan_command_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

scan_backtick_substitution() {
  local sub_start=$((scan_index + 1)) sub_index=$((scan_index + 1))
  local sub_escaped=0 sub_char="" sub_source=""
  while (( sub_index < scan_length )); do
    sub_char="${command_fragment:$sub_index:1}"
    if (( sub_escaped )); then
      sub_escaped=0
    elif [[ "$sub_char" == \\ ]]; then
      sub_escaped=1
    elif [[ "$sub_char" == '`' ]]; then
      break
    fi
    sub_index=$((sub_index + 1))
  done
  sub_source="${command_fragment:$sub_start:$((sub_index - sub_start))}"
  shell_word_started=1
  shell_word_dynamic=1
  [[ "$scan_quote" == '"' ]] || shell_word_unquoted_dynamic=1
  scan_command_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

scan_heredoc_expansions() {
  local command_fragment="$1"
  local scan_index=0 scan_length="${#command_fragment}" scan_escaped=0
  local scan_char="" scan_next="" shell_word_started=0 shell_word_dynamic=0
  while (( scan_index < scan_length )); do
    scan_char="${command_fragment:$scan_index:1}"
    scan_next=""
    (( scan_index + 1 >= scan_length )) \
      || scan_next="${command_fragment:$((scan_index + 1)):1}"
    if (( scan_escaped )); then
      scan_escaped=0
    else
      case "$scan_char" in
        \\) scan_escaped=1 ;;
        '$')
          [[ "$scan_next" != '(' ]] || scan_dollar_substitution
          ;;
        '`') scan_backtick_substitution ;;
      esac
    fi
    scan_index=$((scan_index + 1))
  done
}

skip_pending_heredoc() {
  local line_start=$((scan_index + 1)) line_end line heredoc_body=""
  [[ -n "$pending_heredoc_delimiter" ]] || return 0
  while (( line_start <= scan_length )); do
    line_end="$line_start"
    while (( line_end < scan_length )) \
       && [[ "${command_fragment:$line_end:1}" != $'\n' ]]; do
      line_end=$((line_end + 1))
    done
    line="${command_fragment:$line_start:$((line_end - line_start))}"
    [[ "$line" != *$'\r' ]] || line="${line%$'\r'}"
    if (( heredoc_strip_tabs )); then
      line="${line#"${line%%[!$'\t']*}"}"
    fi
    if [[ "$line" == "$pending_heredoc_delimiter" ]]; then
      if (( pending_heredoc_executes_body )); then
        ambiguous_execution_context=1
        recursive_scan_depth=$((recursive_scan_depth + 1))
        scan_command_fragment "$heredoc_body"
        recursive_scan_depth=$((recursive_scan_depth - 1))
      elif (( pending_heredoc_expands )); then
        scan_heredoc_expansions "$heredoc_body"
      fi
      pending_heredoc_delimiter=""
      pending_heredoc_expands=0
      pending_heredoc_executes_body=0
      scan_index="$line_end"
      return 0
    fi
    heredoc_body+="$line"$'\n'
    (( line_end < scan_length )) || break
    line_start=$((line_end + 1))
  done
  if (( pending_heredoc_executes_body )); then
    ambiguous_execution_context=1
    recursive_scan_depth=$((recursive_scan_depth + 1))
    scan_command_fragment "$heredoc_body"
    recursive_scan_depth=$((recursive_scan_depth - 1))
  elif (( pending_heredoc_expands )); then
    scan_heredoc_expansions "$heredoc_body"
  fi
  scan_index=$((scan_length - 1))
}

scan_command_fragment() {
  local command_fragment="$1"
  local -a shell_words=() shell_word_quotes=() shell_word_dynamics=()
  local -a shell_word_unquoted_dynamics=()
  local -a shell_word_unquoted_globs=()
  local -a shell_word_redirections=()
  local shell_word="" shell_word_started=0 shell_word_quoted=0 shell_word_dynamic=0
  local shell_word_escaped=0 shell_word_unquoted_dynamic=0 shell_word_unquoted_glob=0
  local shell_word_redirection=0
  local scan_index=0 scan_length="${#command_fragment}" scan_quote=""
  local scan_escaped=0 scan_comment=0 scan_char="" scan_next=""
  local pending_heredoc_delimiter="" pending_heredoc_expands=0
  local pending_heredoc_executes_body=0
  local heredoc_expect=0 heredoc_strip_tabs=0
  while (( scan_index < scan_length )); do
    scan_char="${command_fragment:$scan_index:1}"
    scan_next=""
    (( scan_index + 1 >= scan_length )) \
      || scan_next="${command_fragment:$((scan_index + 1)):1}"
    if (( scan_comment )); then
      if [[ "$scan_char" == $'\n' ]]; then
        scan_comment=0
        finish_simple_command
        skip_pending_heredoc
      fi
      scan_index=$((scan_index + 1))
      continue
    fi
    if (( scan_escaped )); then
      # Bash removes an escaped physical newline before tokenization.
      if [[ "$scan_char" != $'\n' ]]; then
        shell_word+="$scan_char"
        shell_word_started=1
        shell_word_escaped=1
      fi
      scan_escaped=0
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == "'" ]]; then
      if [[ "$scan_char" == "'" ]]; then
        scan_quote=""
      else
        shell_word+="$scan_char"
      fi
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == ansi ]]; then
      if (( scan_escaped )); then
        shell_word+="$scan_char"
        scan_escaped=0
      elif [[ "$scan_char" == \\ ]]; then
        shell_word+="$scan_char"
        scan_escaped=1
      elif [[ "$scan_char" == "'" ]]; then
        scan_quote=""
      else
        shell_word+="$scan_char"
      fi
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == '"' ]]; then
      case "$scan_char" in
        '"') scan_quote="" ;;
        \\)
          # Bash keeps a double-quoted backslash unless it precedes $, `, ",
          # backslash, or a physical newline. Preserve the resulting argv.
          case "$scan_next" in
            '$'|'`'|'"'|\\|$'\n') scan_escaped=1 ;;
            *) shell_word+=\\ ;;
          esac
          ;;
        '$')
          if [[ "$scan_next" == '(' ]]; then
            ambiguous_execution_context=1
            scan_dollar_substitution
          else
            shell_word+="$scan_char"
            [[ "$scan_next" =~ [A-Za-z0-9_\{\*@#\?\$!\-] ]] \
              && shell_word_dynamic=1
          fi
          ;;
        '`') ambiguous_execution_context=1; scan_backtick_substitution ;;
        *) shell_word+="$scan_char" ;;
      esac
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    case "$scan_char" in
      \\) scan_escaped=1 ;;
      '$')
        if [[ "$scan_next" == "'" ]]; then
          scan_quote=ansi
          shell_word_started=1
          shell_word_quoted=1
          shell_word_dynamic=1
          scan_index=$((scan_index + 2))
          continue
        elif [[ "$scan_next" == '(' ]]; then
          ambiguous_execution_context=1
          scan_dollar_substitution
        else
          shell_word+="$scan_char"
          shell_word_started=1
          if [[ "$scan_next" =~ [A-Za-z0-9_\{\*@#\?\$!\-] ]]; then
            shell_word_dynamic=1
            shell_word_unquoted_dynamic=1
          fi
        fi
        ;;
      "'"|'"') scan_quote="$scan_char"; shell_word_started=1; shell_word_quoted=1 ;;
      '#')
        if (( shell_word_started == 0 )); then
          scan_comment=1
        else
          shell_word+="$scan_char"
        fi
        ;;
      ' '|$'\t'|$'\r') finish_shell_word ;;
      $'\n') finish_simple_command; skip_pending_heredoc ;;
      ';'|'('|')'|'{'|'}')
        ambiguous_execution_context=1
        finish_simple_command
        ;;
      '&')
        if [[ "$scan_next" == '>' \
           || ( "$shell_word_redirection" == 1 \
             && ( "$shell_word" == *'>' || "$shell_word" == *'<' ) ) ]]; then
          shell_word+="$scan_char"
          shell_word_started=1
          shell_word_redirection=1
        else
          ambiguous_execution_context=1
          finish_simple_command
        fi
        ;;
      '|')
        if (( shell_word_redirection )) && [[ "$shell_word" == *'>' ]]; then
          shell_word+="$scan_char"
          shell_word_started=1
        else
          ambiguous_execution_context=1
          finish_simple_command
        fi
        ;;
      '<'|'>')
        shell_word+="$scan_char"
        shell_word_started=1
        shell_word_redirection=1
        if [[ "$scan_next" == '(' ]]; then
          # Process substitution is one shell word even though it contains a
          # parenthesized command. Reuse the balanced-substitution scanner so
          # grouping separators inside it cannot split the surrounding argv.
          ambiguous_execution_context=1
          shell_word_dynamic=1
          shell_word_unquoted_dynamic=1
          scan_dollar_substitution
        fi
        ;;
      '*'|'?'|'[')
        shell_word+="$scan_char"
        shell_word_started=1
        shell_word_unquoted_glob=1
        ;;
      '`') ambiguous_execution_context=1; scan_backtick_substitution ;;
      *) shell_word+="$scan_char"; shell_word_started=1 ;;
    esac
    scan_index=$((scan_index + 1))
  done
  finish_simple_command
}

scan_command_fragment "$command"

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
    exit 0
  fi
  subcmd="operation"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
project_dir="${CLAUDE_PROJECT_DIR:-$repo_root}"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
marker_file="$project_dir/.agents/state/pr-reviewed.json"
max_age_seconds=600
state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
if [[ ! -r "$state_lib" ]]; then
  printf 'preflight-pr-review: shared audit state library is unavailable.\n' >&2
  exit 2
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$state_lib"
marker_selection=""
marker_selected_identity=""

# If caller-controlled path/ref length pushes a diagnostic over the context budget,
# retain a complete recovery protocol without echoing those values again. A generic
# "read CONTRIBUTING" denial is fail-closed but unsatisfiable: neither host can infer
# the typed acknowledgment or marker shape needed for the retry.
bounded_ack_recovery="PR-review acknowledgment required; the detailed diagnostic exceeded 1200 bytes.
Use AskUserQuestion on Claude or request_user_input on Codex. Ask the human to choose
Other and type:
  reviewed: <one-line summary in their own words of what this PR changes>
Read the free-form Other text (Claude calls it notes). If it starts with 'reviewed: ',
write it verbatim to .agents/state/pr-reviewed.json under the project root as:
  { \"branch\": \"<current branch>\", \"head\": \"<current HEAD>\",
    \"message\": \"<verbatim Other text>\" }
Then retry the same gh command. Abort means no write or retry; Show me the diff means
show the current diff/log and re-ask. Invalid text means re-ask without writing.
Never infer the acknowledgment. Never fabricate, paraphrase, or pre-fill it."

cleanup_marker_selection() {
  if [[ -n "$marker_selection" && -n "$marker_selected_identity" ]]; then
    verdict_audit_unlink_if_identity \
      "$marker_selection" "$marker_selected_identity" 2>/dev/null || true
  fi
  marker_selection=""
  marker_selected_identity=""
}

deny() {
  local reason="$1" reason_bytes
  cleanup_marker_selection
  reason_bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( reason_bytes > 1200 )); then
    # Fail closed without feeding an unbounded command, branch, path, or marker
    # value back into the model context.
    reason="$bounded_ack_recovery"
  fi
  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# The acknowledgment binds the current checkout's branch and HEAD. Inline
# assignments, env mutations, gh target flags, and inherited explicit selectors
# can make the eventual executable or remote differ from that reviewed state.
if (( unsafe_authorization_context_count > 0 )) \
   || [[ -n "${GH_REPO:-}" || -n "${GH_HOST:-}" \
      || -n "${GIT_DIR:-}" || -n "${GIT_WORK_TREE:-}" ]]; then
  deny "A protected gh pr command changes or inherits execution/target context that is not bound to the review acknowledgment.
Run it from the reviewed checkout with no inline environment assignments, env options,
gh --repo/--hostname flags, or inherited GH_REPO, GH_HOST, GIT_DIR, or GIT_WORK_TREE."
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
Use: gh pr create --title \"type(scope): summary\" --body '<fenced graph>'
Safe metadata flags may follow that prefix.
Put --draft, -d, --draft=true, or -d=true first for a draft and do not override it later.
Mixed short-flag clusters and fill/editor/template/recover/web flows are outside this gate."
fi

if (( invalid_edit_contract_count > 0 )); then
  deny "A gh pr edit that changes description content must supply an inspectable title/body pair first.
Use: gh pr edit [selector] --title \"type(scope): summary\" --body '<fenced graph>'
Safe metadata-only edits and safe metadata following that pair are supported.
Base changes, inline environment mutation, dynamic argv splitting, and body files are outside this gate."
fi

if (( invalid_ready_contract_count > 0 )); then
  deny "A gh pr ready command has an unbound selector, option, or expansion.
Use: gh pr ready [literal-selector] [--undo]
Repository overrides and dynamic argv splitting are outside this branch/HEAD-bound gate."
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

# Defense in depth for the create prefix above: an interactive editor or
# repository template is outside this pre-execution boundary. Ready/edit
# operations may omit a body because they do not create one implicitly.
if [[ "$subcmd" == create ]] && (( protected_body_count == 0 )); then
  deny "A non-draft gh pr create must supply an inspectable inline --body.
The gate cannot verify content produced later by an editor or repository template.
Prepare the fenced before/after call graph, pass it explicitly, and retry."
fi

# A body-file read is only a pre-execution snapshot: another process can replace
# it after validation and before gh opens it. The hook cannot bind those bytes to
# gh, so inline body text is the only authorizable representation.
body_index=0
while (( body_index < protected_body_count )); do
  if [[ "${protected_body_kinds[$body_index]}" == file ]]; then
    deny "A gh pr --body-file snapshot cannot be bound to the bytes gh reads later.
Pass the complete fenced call graph as one literal inline --body value."
  fi
  body_index=$((body_index + 1))
done

# Deterministic title check: every supplied literal `--title` / `-t` spelling
# must be a Conventional-Commit subject <=72 chars. Dynamic values fail closed;
# body quality / no-narrative is still confirmed in the acknowledgment below.
protected_fix_flags=()
protected_index=0
while (( protected_index < protected_count )); do
  protected_fix_flags[$protected_index]=0
  protected_index=$((protected_index + 1))
done
title_re='^(feat|fix|docs|refactor|test|chore|perf|ci|build)(\([^)]+\))?!?:[[:space:]].+'
title_index=0
while (( title_index < protected_title_count )); do
  pr_title="${protected_titles[$title_index]}"
  title_command="${protected_title_commands[$title_index]}"
  title_dynamic="${protected_title_dynamics[$title_index]}"
  if (( title_dynamic )) \
     || [[ -z "$pr_title" || ! "$pr_title" =~ $title_re ]] \
     || (( ${#pr_title} > 72 )); then
    deny "PR title must be a Conventional-Commit subject <=72 characters (got ${#pr_title}).
Use type(scope): summary; types: feat fix docs refactor test chore perf ci build.
Fix --title and retry. See CONTRIBUTING.md #commit--pr-messages."
  fi
  if [[ "$pr_title" =~ ^fix(\([^\)]+\))?!?: ]]; then
    protected_fix_flags[$title_command]=1
  fi
  title_index=$((title_index + 1))
done

# Deterministic body check: a supplied PR body must carry the before/after
# end-to-end call graph mandated by CONTRIBUTING.md #commit--pr-messages.
#
# Only inspected when its command segment actually supplies a body. `gh pr ready`
# and body-preserving edits carry nothing to read; non-draft creates were required
# above to supply an inspectable body.
body_index=0
while (( body_index < protected_body_count )); do
  body_command="${protected_body_commands[$body_index]}"
  body_kind="${protected_body_kinds[$body_index]}"
  body_value="${protected_body_values[$body_index]}"
  pr_body=""
  pr_title=""
  (( protected_fix_flags[$body_command] == 0 )) || pr_title="fix: inspected"
  if [[ "$body_kind" == text ]]; then
    pr_body="$body_value"
  fi

  # Line-start anchors below: an extracted body begins mid-line, glued to the flag.
  pr_body=$'\n'"$pr_body"
  body_lc="$(tr '[:upper:]' '[:lower:]' <<<"$pr_body")"
  # The visual contract is deliberately a constrained prefix, not a partial
  # Markdown parser. With the heading as the first non-blank body line and one
  # exact column-one text fence immediately after it, no earlier comment, raw
  # HTML block, outer fence, or indented block can hide or reinterpret the tree.
  graph_records="$(awk '
    BEGIN { state = "leading" }
    function gfm_backtick_closer(line, spaces, position, count, rest) {
      spaces = 0
      while (spaces < 4 && substr(line, spaces + 1, 1) == " ") spaces++
      if (spaces > 3) return 0
      position = spaces + 1
      count = 0
      while (substr(line, position + count, 1) == "`") count++
      if (count < 3) return 0
      rest = substr(line, position + count)
      return rest ~ /^[[:space:]]*$/
    }
    { sub(/\r$/, "", $0) }
    state == "leading" {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 != "## call graph") {
        invalid = 1
        exit
      }
      print "@heading"
      state = "after_heading"
      next
    }
    state == "after_heading" {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 != "```text") {
        invalid = 1
        exit
      }
      state = "graph"
      next
    }
    state == "graph" {
      if ($0 == "```") {
        print "@closed"
        state = "after_graph"
        next
      }
      if (gfm_backtick_closer($0)) {
        invalid = 1
        exit
      }
      if ($0 == "before") {
        if (before_seen || after_seen) {
          invalid = 1
          exit
        }
        before_seen = 1
        print "@before-label"
        active_graph = 1
        next
      }
      if ($0 == "after") {
        if (!before_seen || after_seen) {
          invalid = 1
          exit
        }
        after_seen = 1
        print "@after-label"
        active_graph = 2
        next
      }
      if (active_graph == 1) print "@before:" $0
      if (active_graph == 2) print "@after:" $0
      next
    }
    state == "after_graph" {
      if (!post_recorded && $0 !~ /^[[:space:]]*$/) {
        print "@post:" $0
        post_recorded = 1
      }
    }
    END {
      if (invalid || state != "after_graph") print "@invalid"
    }
  ' <<<"$body_lc")"
  # Herestrings, not pipes: `grep -q` exits on first match and would SIGPIPE the
  # writer, which `set -o pipefail` would then read as a failed check.
  has_graph_record() { grep -qFx "$1" <<<"$graph_records"; }
  missing=""

  if has_graph_record '@invalid' || ! has_graph_record '@closed'; then
    missing+="
  - the canonical body prefix: first non-blank line '## Call graph', then one closed column-one '\`\`\`text' fence"
  fi
  has_graph_record '@before-label' \
    || missing+="
  - a 'Before' graph"
  has_graph_record '@after-label' \
    || missing+="
  - an 'After' graph"
  before_graph="$(sed -n 's/^@before://p' <<<"$graph_records")"
  after_graph="$(sed -n 's/^@after://p' <<<"$graph_records")"
  post_graph_line="$(sed -n 's/^@post://p' <<<"$graph_records")"
  # Each graph needs a hop of its own, shaped like the documented
  # `fn_name (Type · path/file.ext:LOC)`. Matching a bare `file.ext:LOC` was
  # too loose — one occurs mid-sentence — so a paragraph mentioning a file in
  # passing counted as a graph.
  #
  # What it actually requires: a `(` to the left of the reference and a `)` to
  # the right. Not a balanced group, and neither side is stricter than the
  # other. Being permissive is deliberate — a Type half carries its own
  # parentheses in `(fn(u32) -> u32 · src/x.rs:5)`, and refusing to cross them
  # denied a hop conforming to CONTRIBUTING.md's documented shape. The cost is
  # that an unrelated parenthetical straddling the reference also satisfies it.
  #
  # So this only reaches "shaped like a hop". It cannot tell a real graph from
  # a fabricated one, and no pattern here could — that judgment is left to the
  # human on the typed `reviewed:` ack below.
  #
  # Per graph, not body-wide: a body-wide count lets a prose-only After ride
  # along on Before's hops, which is not an end-to-end before/after graph.
  hop_re='\(.*[A-Za-z0-9_./-]+\.[A-Za-z]+:[0-9]+.*\)'
  before_hops="$(grep -cE "$hop_re" <<<"$before_graph" || true)"
  after_hops="$(grep -cE "$hop_re" <<<"$after_graph" || true)"
  # Reports what is checked — a parenthesised reference — rather than naming
  # parts (`fn_name`, `Type`) the pattern does not require; the canonical shape
  # is printed in full below.
  (( before_hops >= 1 && after_hops >= 1 )) \
    || missing+="
  - a hop line inside a closed 'text' fence with a parenthesised 'path/file.ext:LOC' in each graph (found ${before_hops} in Before, ${after_hops} in After)"

  # Bug-fix extras — only decidable when --title was inspectable above.
  if [[ "$pr_title" =~ ^fix(\([^\)]+\))?!?: ]]; then
    # "Mark the faulty hop" is literal: the marker has to sit on a hop line
    # inside the Before graph. A `BUG:` loose in prose, or down in After, marks
    # nothing. The arrow is deliberately not required — `←`, `<-` and a bare
    # `BUG:` all read the same, and mandating one Unicode glyph is typing
    # friction, not signal. The word boundary keeps `debug:` from qualifying.
    marker_re='(^|[^[:alnum:]_])bug:'
    # Same line, either order: `hop … ← BUG: why` or `← BUG: why … hop`.
    marked_hop() {
      grep -qE "${hop_re}.*${marker_re}" <<<"$before_graph" ||
        grep -qE "${marker_re}.*${hop_re}" <<<"$before_graph"
    }
    marked_hop \
      || missing+="
  - fix: PR — '← BUG: <what goes wrong>' on a hop line inside the Before graph"
    [[ "$post_graph_line" =~ ^fixes[[:space:]]+#[1-9][0-9]*$ ]] \
      || missing+="
  - fix: PR — 'Fixes #<positive issue number>' as the first non-blank line after the graph fence"
  fi

  if [[ -n "$missing" ]]; then
    deny "PR description needs the mandated before/after call graph.
Missing:${missing}

Required prefix; make this the first non-blank body content:
  ## Call graph
  \`\`\`text
  Before
    fn_name (Type · path/file.ext:LOC) <- BUG: what fails
  After
    fn_name (Type · path/file.ext:LOC) - new behavior
  \`\`\`
  Fixes #<n>
For fix titles, mark the faulty Before hop and keep Fixes #<n> immediately after the fence.
Use real symbols and current line numbers. Rewrite and retry; see CONTRIBUTING.md #commit--pr-messages."
  fi
  body_index=$((body_index + 1))
done

# The acknowledgment UX is repeated on every missing/stale/malformed-marker
# denial. Keep the typed `reviewed:` shape, Other/notes transport, marker binding,
# abort/diff branches, and anti-fabrication rule inside the 1200-byte reason cap.
# Do not interpolate the raw command or marker contents; either can be unbounded.
REQUIRED_MESSAGE_RE='^reviewed:[[:space:]]+[^[:space:]]'

ack_instruction="PR-review acknowledgment required for gh pr ${subcmd}; bind ${branch}@${head}.
Use the host's native input tool (AskUserQuestion on Claude; request_user_input on
Codex). Ask the human to confirm the PR template has no internal/AI narrative,
pasted logs, or secrets; they must choose 'Other' and type:
  reviewed: <one-line summary in their own words of what this PR changes>
Options: 'Abort' and 'Show me the diff'.
Read the free-form Other text from the tool result (Claude calls it notes); never
infer it from chat or an option selection.

If that text matches ${REQUIRED_MESSAGE_RE}, write it verbatim to
.agents/state/pr-reviewed.json under the project root as:
  { \"branch\": \"<bound branch>\", \"head\": \"<bound HEAD>\",
    \"message\": \"<verbatim notes>\" }
Then retry the same gh command. Abort means no write/retry. Show me the diff: run
git diff main...HEAD --stat and git log main..HEAD --oneline, then re-ask. Invalid
text: re-ask without writing/retrying.
Never infer the acknowledgment. Never fabricate, paraphrase, or pre-fill it."
# ─────────────────────────────────────────────────────────────────────────────

marker_selection="${marker_file}.inspect-$$-${RANDOM:-0}"
marker_selected_identity="$(verdict_audit_link_no_clobber_identity \
  "$marker_file" "$marker_selection" 2>/dev/null)" || marker_selected_identity=""
if [[ -z "$marker_selected_identity" ]]; then
  marker_selection=""
  deny "No current PR-review acknowledgment is on file.

${ack_instruction}"
fi

marker_snapshot="$(verdict_audit_read_regular_state \
  "$marker_selection" 8192 json 2>/dev/null)" || marker_snapshot=""
marker_mtime=""
marker_json=""
if [[ "$marker_snapshot" == *$'\n'* ]]; then
  marker_mtime="${marker_snapshot%%$'\n'*}"
  marker_json="${marker_snapshot#*$'\n'}"
fi
marker_document="$(printf '%s' "$marker_json" | jq -ecs '
  def exact_keys($wanted): (keys | sort) == ($wanted | sort);
  def bounded_line($bytes):
    type == "string" and utf8bytelength <= $bytes
    and (explode | all(. != 0 and . != 10 and . != 13));
  if length == 1 and (.[0] | type) == "object"
     and (.[0] | exact_keys(["branch", "head", "message"]))
     and (.[0].branch | bounded_line(4096))
     and (.[0].head | type == "string"
          and test("^[0-9a-f]{40}([0-9a-f]{24})?$|^\\?$"))
     and (.[0].message | bounded_line(1024))
  then .[0] else empty end
' 2>/dev/null || true)"
if [[ -z "$marker_document" || ! "$marker_mtime" =~ ^[0-9]+$ ]]; then
  deny "PR-review acknowledgment is malformed or exceeds its safety limits.
${ack_instruction}"
fi
marker_branch="$(printf '%s' "$marker_document" | jq -r '.branch')"
marker_head="$(printf '%s' "$marker_document" | jq -r '.head')"
marker_message="$(printf '%s' "$marker_document" | jq -r '.message')"

now_epoch="$(date +%s)"
age=$(( now_epoch - marker_mtime ))

if [[ "$marker_branch" != "$branch" ]] || \
   [[ "$marker_head" != "$head" ]] || \
   (( age < 0 || age > max_age_seconds )); then
  deny "PR-review acknowledgment is stale or not bound to current branch+HEAD (max age ${max_age_seconds}s).
${ack_instruction}"
fi

if [[ ! "$marker_message" =~ $REQUIRED_MESSAGE_RE ]]; then
  deny "PR-review acknowledgment is malformed; it must start with 'reviewed: '.
${ack_instruction}"
fi

# Marker is valid for this exact branch+HEAD. Consume it so the next
# gh pr create/edit/ready forces a fresh ack.
consume_status=0
verdict_audit_unlink_if_identity \
  "$marker_file" "$marker_selected_identity" 2>/dev/null || consume_status=$?
if (( consume_status != 0 )); then
  deny "The matching PR-review acknowledgment could not be consumed safely.
${ack_instruction}"
fi
cleanup_marker_selection
exit 0
