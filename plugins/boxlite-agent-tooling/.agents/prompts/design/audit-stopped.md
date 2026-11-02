---
name: audit-stopped
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: fails, reason, findings, instruction
---
INCOMPLETE: the design-audit loop stopped after FAIL {{fails}} because {{reason}}. Open findings:
{{findings}}

Only the human chooses:

- Redesign: a fresh draft from the findings and reflection; the count resets.
- Reflect again: one more audit after a reflection.
- Overrule: OVERRIDDEN BY USER, never PASS.

Never answer for them or relay their words.
On Claude Code, use the managed question; otherwise ask them to reply with the first line `design-decision: <Redesign|Reflect again|Overrule> <reason>`.

{{instruction}}
