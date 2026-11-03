---
name: audit-expired
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: findings
---
No design decision arrived within 5 minutes, so edits stay blocked. Open findings:
{{findings}}

- Draft a redesign from the findings and reflection; do not post it.
- Ask the human once to approve its exact text, and do not wait for a reply.
- Until they approve, keep it unposted, report it, and keep edits blocked.
- Silence never overrules or approves; their typed first line `design-decision: <Redesign|Reflect again|Overrule> <reason>` still counts.
