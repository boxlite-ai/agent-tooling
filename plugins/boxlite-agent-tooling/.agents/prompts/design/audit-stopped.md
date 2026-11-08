---
name: audit-stopped
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: fails, reason, findings, instruction, reply_format
---
INCOMPLETE: the design-audit loop stopped after FAIL {{fails}} because {{reason}}. Open findings:
{{findings}}

Only the human chooses. Require `{{reply_format}}` on the first line. Never answer or relay it through a command.

{{instruction}}
