---
name: git-audit-history
used-by: .claude/agents/commit-push-auditor.md
---

## TL;DR

Prepare and record native Git audits through the shared history CLI.

## Procedure

1. Before review, run `bash "$history_cli" "$history_context" prepare` with stdin JSON:
   `{binding:{branch,head,command_kind,diff_hash,command_hash,commit_subject_hash},
   snapshot:{tree,command}}`. Bind the exact operation/command and immutable tree:
   `git write-tree` for commit, HEAD tree for push. Retain attempt_id/history_path.
2. Follow `../.agents/prompts/audit-reflection.md` and the history/reflection definitions
   in `../.agents/hooks/commit-push-audit.schema.json`, relative to the CLI directory.
   Read original evidence before attributing defects to fixes. The parent supplies
   reflection; independently assess it in the dossier.
3. Before returning, send the exact dossier on stdin to
   `bash "$history_cli" "$history_context" record "$attempt_id"`; the parent revalidates.
   If unable to finish, call `error` with a concise JSON reason string.

Blocked preparation: report state path/reason; do not audit or fabricate a dossier.
Never overwrite unfinished attempts or edit history files. Before closing an
interrupted attempt with `error`, confirm its auditor has ended.
