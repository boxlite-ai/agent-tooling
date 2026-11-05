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
Use the supplied managed question on Claude Code or Codex; otherwise request the first line `design-decision: <Redesign|Reflect again|Overrule> <reason>`.

{{instruction}}
