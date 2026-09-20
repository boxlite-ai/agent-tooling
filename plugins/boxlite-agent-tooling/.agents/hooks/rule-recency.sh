#!/usr/bin/env bash
# Standalone UserPromptSubmit text hook. Full plugin manifests intentionally do not
# wire it; consumers opt in through templates/{codex-hooks,claude-settings}.json.
# Bare acknowledgements, answers, and controls add no reminder. Every substantive
# prompt gets the same compact reminder. No counter, session state, model call,
# plugin path, or sibling file.
# Best effort: this hook never blocks a prompt and always exits zero.

payload="$(cat)"
prompt="$(printf '%s' "$payload" \
  | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)"
bare_reply="$(printf '%s' "$prompt" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -d '[:punct:]' \
  | tr -s '[:space:]' ' ' \
  | sed 's/^ //;s/ $//')"

prompt_has_escaped_quote=false
[[ "$payload" == *'\"'* ]] && prompt_has_escaped_quote=true

if [[ "$prompt_has_escaped_quote" == false ]]; then
  case " $bare_reply " in
  " ok "|" okay "|" k "|" kk "|" yes "|" yep "|" yeah "|" ya "|" yup "| \
  " no "|" nope "|" sure "|" cool "|" nice "|" got it "|" thanks "| \
  " thank you "|" ty "|" thx "|" proceed "|" continue "|" go "| \
  " go ahead "|" go on "|" done "|" next "|" stop "|" nvm ")
    exit 0
    ;;
  esac
fi

cat <<'EOF'
REPLY SHAPE:
- <=80 prose words by default; no walls of text. Keep uncertainty, risks, failures visible; link long evidence.
- Choose call graph, sequence diagram, real example, bullets, table, or short prose by clarity; no form is mandatory.
- Whenever useful, walk one real example step by step, showing what changes and the general rule. Label hypothetical values.
- Answer first, in one sentence. No preamble, recap, praise, repetition, or closing offer.
- Explicit depth requests allow more short sections, never dense text.
- Non-trivial work: follow repository Workflow; research prior art before design.
EOF
exit 0
