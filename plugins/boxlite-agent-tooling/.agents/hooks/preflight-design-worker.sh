#!/usr/bin/env bash
# The host hook owns launch; the Bash action itself is a read-only status command.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || exit 2
# shellcheck source=../lib/hook-host.sh
source "$plugin_root/.agents/lib/hook-host.sh" || exit 2
host="$(hook_host_kind)" || exit 2
[[ "$host" == claude || "$host" == codex ]] || exit 0
python="$(command -v python3)" || { printf 'design-doc: python3 is required\n' >&2; exit 2; }
command="$(printf '%s' "$payload" | "$python" -I -c '
import json,sys
command=json.load(sys.stdin).get("tool_input",{}).get("command","")
if not isinstance(command,str) or "\0" in command: sys.exit(2)
sys.stdout.write(command+"\1")
')" || { printf 'design-doc: invalid tool command\n' >&2; exit 2; }
command="${command%$'\001'}"
if [[ "$command" != "bash \"$plugin_root/scripts/design-doc.sh\" run" ]]; then
  # shellcheck source=../lib/shell-scan.sh
  source "$plugin_root/.agents/lib/shell-scan.sh" || exit 2
  runner_requested=0
  recursive_scan_depth=0
  inspect_runner_payload() {
    if (( recursive_scan_depth >= 16 )); then runner_requested=1; return 0; fi
    recursive_scan_depth=$((recursive_scan_depth + 1))
    shell_scan_fragment "$1"
    recursive_scan_depth=$((recursive_scan_depth - 1))
  }
  inspect_runner_command() {
    local source_index=0 token prefix operator wrapper payload argument syntax_only=0
    local -a words=() quotes=() dynamics=()
    while (( source_index < ${#shell_words[@]} )); do
      token="${shell_words[$source_index]}"
      if (( shell_word_redirections[source_index] )); then
        # A redirection may share its word with the executable: runner>file.
        prefix="${token%%[<>]*}"
        operator="${token#"$prefix"}"
        prefix="${prefix%&}"
        if [[ -n "$prefix" && ! "$prefix" =~ ^[0-9]+$ \
              && ! "$prefix" =~ ^\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]; then
          words+=("$prefix")
          quotes+=("${shell_word_quotes[$source_index]}")
          dynamics+=("${shell_word_dynamics[$source_index]}")
        fi
        source_index=$((source_index + 1))
        case "$operator" in
          '<'|'>'|'>>'|'<<'|'<<-'|'<<<'|'<>'|'>|'|'<&'|'>&')
            source_index=$((source_index + 1)) ;;
        esac
        continue
      fi
      words+=("$token")
      quotes+=("$((shell_word_quotes[source_index] || shell_word_escapes[source_index]))")
      dynamics+=("${shell_word_dynamics[$source_index]}")
      source_index=$((source_index + 1))
    done
    local index=0 count="${#words[@]}"
    while (( index < count && quotes[index] == 0 )); do
      case "${words[$index]}" in
        if|then|elif|else|while|until|do|'!') index=$((index + 1)) ;;
        time)
          index=$((index + 1))
          while (( index < count )) && [[ "${words[$index]}" == -p ]]; do index=$((index + 1)); done
          if (( index < count )) && [[ "${words[$index]}" == -- ]]; then index=$((index + 1)); fi
          ;;
        *) break ;;
      esac
    done
    while (( index < count )); do
      token="${words[$index]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        index=$((index + 1)); continue
      fi
      case "${token##*/}" in
        env|command|exec)
          wrapper="${token##*/}"
          index=$((index + 1))
          while (( index < count )) && [[ "${words[$index]}" == -* ]]; do
            token="${words[$index]}"
            if [[ "$wrapper" == command && "$token" != --* && "$token" == -*[vV]* ]]; then return 0; fi
            if [[ "$wrapper" == env ]]; then
              case "$token" in
                -S|--split-string)
                  index=$((index + 1))
                  (( index < count )) || { runner_requested=1; return 0; }
                  payload="${words[$index]}" ;;
                --split-string=*) payload="${token#*=}" ;;
                -S?*) payload="${token#-S}" ;;
              esac
              case "$token" in
                -S|--split-string|--split-string=*|-S?*)
                  (( dynamics[index] == 0 )) || { runner_requested=1; return 0; }
                  for (( argument=index + 1; argument<count; argument++ )); do
                    (( dynamics[argument] == 0 )) || { runner_requested=1; return 0; }
                    printf -v token '%q' "${words[$argument]}"
                    payload+=" $token"
                  done
                  inspect_runner_payload "$payload"
                  return 0 ;;
              esac
            fi
            case "$token" in
              --) index=$((index + 1)); break ;;
              -u|--unset|-C|--chdir|--argv0|-a) index=$((index + 1)) ;;
            esac
            index=$((index + 1))
          done
          ;;
        *) break ;;
      esac
    done
    (( index < count )) || return 0
    token="${words[$index]}"
    case "${token##*/}" in
      bash|sh|dash|zsh|ksh|source|.)
        index=$((index + 1))
        while (( index < count )) && [[ "${words[$index]}" == -* ]]; do
          token="${words[$index]}"
          index=$((index + 1))
          case "$token" in
            --) break ;;
            --help|--version) return 0 ;;
            --rcfile|--init-file|-o|-O) index=$((index + 1)) ;;
            --*) ;;
            -?*)
              [[ "$token" != *n* ]] || syntax_only=1
              if [[ "$token" == *c* ]] && (( index < count )); then
                (( syntax_only == 0 )) || return 0
                inspect_runner_payload "${words[$index]}"
                return 0
              fi ;;
          esac
        done
        (( syntax_only == 0 )) || return 0
        if (( index >= count )); then
          [[ -z "$pending_heredoc_delimiter" ]] || pending_heredoc_executes_body=1
          return 0
        fi
        ;;
    esac
    (( index < count )) || return 0
    token="${words[$index]}"
    if [[ "${token##*/}" == design-doc.sh ]]; then
      if (( index + 1 >= count )) || [[ "${words[$((index + 1))]}" == run ]] \
        || (( dynamics[index + 1] )); then
        runner_requested=1
      fi
    elif (( dynamics[index] && index + 1 < count )); then
      if [[ "${words[$((index + 1))]}" == run ]] || (( dynamics[index + 1] )); then runner_requested=1; fi
    fi
  }
  finish_simple_command() {
    shell_scan_finish_word
    inspect_runner_command
    shell_words=(); shell_word_quotes=(); shell_word_dynamics=()
    shell_word_unquoted_dynamics=(); shell_word_unquoted_globs=()
    shell_word_redirections=(); shell_word_escapes=()
  }
  shell_scan_fragment "$command"
  (( runner_requested )) || exit 0
  printf 'design-doc: use only bash "%s/scripts/design-doc.sh" run, without prefixes or extra arguments\n' "$plugin_root" >&2
  exit 2
fi
selection="$(printf '%s' "$payload" | "$python" -I -c '
import json,os,sys
p=json.load(sys.stdin); command=p.get("tool_input",{}).get("command","")
if not isinstance(command,str): sys.exit(2)
if command != "bash \""+sys.argv[1]+"/scripts/design-doc.sh\" run": sys.exit(2)
cwd=p.get("tool_input",{}).get("workdir") or p.get("tool_input",{}).get("cwd") or p.get("cwd") or os.getcwd()
if not isinstance(cwd,str) or not os.path.isabs(cwd): sys.exit(2)
print(cwd)
' "$plugin_root")" || {
  printf 'design-doc: use only bash "%s/scripts/design-doc.sh" run, without prefixes or extra arguments\n' "$plugin_root" >&2
  exit 2
}
[[ -n "$selection" ]] || exit 0
exec "$python" -I "$plugin_root/scripts/design-worker.py" "$host" "$selection"
