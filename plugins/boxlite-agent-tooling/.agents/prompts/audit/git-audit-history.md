---
name: git-audit-history
used-by: .claude/agents/commit-push-auditor.md
---

## TL;DR

Assess history for the attempt the hook prepared.

## Procedure

1. The hook already prepared `attempt_id`; its history input is `history_path`.
   Never run `history_cli`.
2. Follow `../.agents/prompts/audit/audit-reflection.md` and the history/reflection definitions
   in `../.agents/hooks/audit/commit-push-audit.schema.json`, relative to the CLI directory.
   Read original evidence before attributing defects to fixes. The parent supplies
   reflection; independently assess it in the dossier.
3. Bind the dossier's `history_review` to `attempt_id`. The hook records the dossier;
   never write history files.
