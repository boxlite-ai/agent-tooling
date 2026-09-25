---
name: git-audit-history
used-by: .claude/agents/commit-push-auditor.md
---

## TL;DR

Prepare, reconcile, and record each native Git audit through the shared history CLI.

## Procedure

Before reviewing code, invoke `bash "$history_cli" "$history_context" prepare` with
JSON on stdin: `{binding:{branch,head,command_kind,diff_hash,command_hash,
commit_subject_hash},snapshot:{tree,command}}`. Use the exact operation bindings, the
immutable staged tree from `git write-tree` for commit (HEAD tree for push), and the
exact target command. Retain returned attempt_id and history_path.

Read `../.agents/prompts/audit-reflection.md` relative to the CLI's directory.
Its schema is `../.agents/hooks/commit-push-audit.schema.json`; follow the history
and reflection definitions for this review. Read original evidence before attributing
a newly discovered defect to a fix. Include the required assessments in the dossier.

If preparation blocks, report its state path and reason; do not start another audit
or fabricate a dossier. Never overwrite an unfinished attempt. Confirm an interrupted
auditor has ended before closing its attempt with the CLI's error operation.

Record the exact completed dossier through
`bash "$history_cli" "$history_context" record "$attempt_id"` with the dossier on
stdin before returning. The parent gate validates it again. If this audit cannot
complete, call `error` with a concise JSON string explaining why. Do not edit history
files directly. A reflection requirement belongs to the parent agent; this auditor
independently judges its evidence on the next permitted run.
