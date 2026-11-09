#!/usr/bin/env bash
# shellcheck disable=SC2034 # ambiguous_execution_context belongs to the caller.
# Shell-word scanner for command gates. Source only; no work on load.
#
# shell_scan_fragment SOURCE splits SOURCE into simple commands without running
# it. At each simple-command boundary it calls the caller's
# finish_simple_command, which reads the dynamically scoped shell_words arrays
# (words plus per-word quote, dynamic, glob, redirection, and escape flags) and
# must call shell_scan_finish_word first. Substitutions, process substitutions,
# and executable heredoc bodies are scanned recursively and set the caller's
# ambiguous_execution_context=1; recursive_scan_depth counts nesting.

shell_scan_finish_word() {
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
  shell_word_escapes[${#shell_word_escapes[@]}]="$completed_escaped"
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

# `$()` source is executable even when its surrounding word is double quoted.
# Extract it without executing, mark the outer word uninspectable, and scan the
# nested source as its own command fragment. Single quotes and escaped dollars
# never call this path, so literal examples remain inert.
shell_scan_dollar_substitution() {
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
  shell_scan_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

shell_scan_backtick_substitution() {
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
  shell_scan_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

shell_scan_heredoc_expansions() {
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
          [[ "$scan_next" != '(' ]] || shell_scan_dollar_substitution
          ;;
        '`') shell_scan_backtick_substitution ;;
      esac
    fi
    scan_index=$((scan_index + 1))
  done
}

shell_scan_skip_pending_heredoc() {
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
        shell_scan_fragment "$heredoc_body"
        recursive_scan_depth=$((recursive_scan_depth - 1))
      elif (( pending_heredoc_expands )); then
        shell_scan_heredoc_expansions "$heredoc_body"
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
    shell_scan_fragment "$heredoc_body"
    recursive_scan_depth=$((recursive_scan_depth - 1))
  elif (( pending_heredoc_expands )); then
    shell_scan_heredoc_expansions "$heredoc_body"
  fi
  scan_index=$((scan_length - 1))
}

shell_scan_fragment() {
  local command_fragment="$1"
  local -a shell_words=() shell_word_quotes=() shell_word_dynamics=()
  local -a shell_word_unquoted_dynamics=()
  local -a shell_word_unquoted_globs=()
  local -a shell_word_redirections=() shell_word_escapes=()
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
        shell_scan_skip_pending_heredoc
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
            shell_scan_dollar_substitution
          else
            shell_word+="$scan_char"
            [[ "$scan_next" =~ [A-Za-z0-9_\{\*@#\?\$!\-] ]] \
              && shell_word_dynamic=1
          fi
          ;;
        '`') ambiguous_execution_context=1; shell_scan_backtick_substitution ;;
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
          shell_scan_dollar_substitution
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
      ' '|$'\t'|$'\r') shell_scan_finish_word ;;
      $'\n') finish_simple_command; shell_scan_skip_pending_heredoc ;;
      '{'|'}')
        # Braces are reserved words, not shell metacharacters. Keep launcher
        # operands such as xargs -I{} in the same argv. A comma or sequence
        # inside braces may expand and cannot establish literal arguments.
        if [[ "$scan_char" == '{' && "$scan_next" == '}' ]]; then
          shell_word+='{}'
          shell_word_started=1
          scan_index=$((scan_index + 1))
        elif (( shell_word_started == 0 )) \
          && [[ -z "$scan_next" || "$scan_next" =~ [[:space:]\;\&\|\(\)\<\>] ]]; then
          ambiguous_execution_context=1
          finish_simple_command
        else
          shell_word+="$scan_char"
          shell_word_started=1
          if [[ "$scan_char" == '{' && "${command_fragment:$scan_index}" =~ ^\{[^{}]*(,|\.\.) ]]; then
            shell_word_dynamic=1
            shell_word_unquoted_dynamic=1
          fi
        fi
        ;;
      ';'|'('|')')
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
          shell_scan_dollar_substitution
        fi
        ;;
      '*'|'?'|'[')
        shell_word+="$scan_char"
        shell_word_started=1
        shell_word_unquoted_glob=1
        ;;
      '`') ambiguous_execution_context=1; shell_scan_backtick_substitution ;;
      *) shell_word+="$scan_char"; shell_word_started=1 ;;
    esac
    scan_index=$((scan_index + 1))
  done
  finish_simple_command
}
