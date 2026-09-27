---
name: verdict-revise-answer
used-by: .agents/hooks/audit/preflight-verdict-check.sh
placeholders: branch, findings
---
Verdict proof check FAILED on branch '{{branch}}':

{{findings}}

Revise the user-facing answer to address each finding, then end the turn again; the
Stop gate will re-audit the revised answer automatically.
