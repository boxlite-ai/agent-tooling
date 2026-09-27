---
name: commit-push-reflection-required
used-by: .agents/hooks/preflight-commit-push.sh
placeholders: history_path, tooling_root
---
Repeated audits require reflection before retrying. Read {{history_path}} and {{tooling_root}}/.agents/prompts/audit-reflection.md. Compare all failed runs, explain failed fixes and earlier audit misses, run a discriminating check, and submit the current reflection with scripts/audit-reflection.sh.
