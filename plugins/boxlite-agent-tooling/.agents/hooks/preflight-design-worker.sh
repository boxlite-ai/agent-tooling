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
  [[ "$command" == *design-doc.sh* ]] || exit 0
  # shellcheck source=../lib/shell-scan.sh
  source "$plugin_root/.agents/lib/shell-scan.sh" || exit 2
  runner_requested=0
  recursive_scan_depth=0
  inspect_runner_command() {
    local index=0 count="${#shell_words[@]}" token
    while (( index < count )); do
      token="${shell_words[$index]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        index=$((index + 1)); continue
      fi
      case "${token##*/}" in
        env|command|exec)
          index=$((index + 1))
          while (( index < count )) && [[ "${shell_words[$index]}" == -* ]]; do
            case "${shell_words[$index]}" in -u|--unset|-C|--chdir|--argv0) index=$((index + 1)) ;; esac
            index=$((index + 1))
          done
          ;;
        *) break ;;
      esac
    done
    (( index < count )) || return 0
    token="${shell_words[$index]}"
    case "${token##*/}" in
      bash|sh|dash|zsh|ksh|source|.)
        index=$((index + 1))
        while (( index < count )) && [[ "${shell_words[$index]}" == -* ]]; do
          token="${shell_words[$index]}"
          index=$((index + 1))
          if [[ "$token" == -*c* ]] && (( index < count )); then
            if (( recursive_scan_depth >= 16 )); then runner_requested=1; return 0; fi
            recursive_scan_depth=$((recursive_scan_depth + 1))
            shell_scan_fragment "${shell_words[$index]}"
            recursive_scan_depth=$((recursive_scan_depth - 1))
            return 0
          fi
          [[ "$token" != -- ]] || break
        done
        if (( index >= count )) || [[ "${shell_words[$index]}" == [\<\>]* ]]; then
          [[ -z "$pending_heredoc_delimiter" ]] || pending_heredoc_executes_body=1
          return 0
        fi
        ;;
    esac
    (( index < count )) || return 0
    token="${shell_words[$index]}"
    if [[ "${token##*/}" == design-doc.sh ]] || (( shell_word_dynamics[index] )); then
      if (( index + 1 >= count )) || [[ "${shell_words[$((index + 1))]}" == run ]] \
        || (( shell_word_dynamics[index + 1] )); then
        runner_requested=1
      fi
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
