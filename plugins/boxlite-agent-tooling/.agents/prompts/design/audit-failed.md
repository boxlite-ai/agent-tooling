---
name: audit-failed
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: findings, advice, instruction
---
The design audit failed for the current design:
{{findings}}
Advice (optional; adopt only items the human accepts):
{{advice}}
Fix these gaps in the design, then audit it again; rerun the audit on an unchanged
design only when a finding is wrong.

{{instruction}}
