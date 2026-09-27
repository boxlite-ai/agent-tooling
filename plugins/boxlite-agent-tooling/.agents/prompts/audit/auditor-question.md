---
name: auditor-question
used-by: .agents/hooks/auditor-control.sh
placeholders: auditor, keep_command_json, override_command_json
---
{
  "question": "{{auditor}} is still running. What should I do?",
  "header": "Auditor",
  "options": [
    {"label": "Keep waiting (Recommended)",
     "description": "Leave every auditor running and dismiss this one-shot escalation.",
     "command": {{keep_command_json}}},
    {"label": "Force pass — auditor is taking too long", "commandLabel": "Force pass",
     "description": "Override commit-push-auditor and verdict-auditor for this prompt only; record OVERRIDDEN BY USER, never PASS.",
     "command": {{override_command_json}}}
  ],
  "multiSelect": false
}
