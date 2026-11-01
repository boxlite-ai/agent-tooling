---
name: audit-expired
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: findings
---
No design decision arrived within 5 minutes, so edits stay blocked. Open findings:
{{findings}}
Draft a redesign from the findings and reflection, do not post it, and ask the human to
approve its exact text. Silence never overrules; their typed first line
`design-decision: <Redesign|Reflect again|Overrule> <reason>` still counts.
