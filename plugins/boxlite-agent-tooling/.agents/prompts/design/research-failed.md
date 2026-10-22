---
name: research-failed
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: findings, instruction
---
The research audit failed for the current design:
{{findings}}
Fix these gaps in the design, then audit it again; rerun the audit on an unchanged
design only when a finding is wrong.

{{instruction}}
