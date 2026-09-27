---
name: interactive-question
used-by: .agents/lib/hook-interactive-prompt.sh
placeholders: payload, commands
---
Invoke AskUserQuestion exactly once with this payload:
{{payload}}

After AskUserQuestion returns, run exactly one matching command with Bash:
{{commands}}
