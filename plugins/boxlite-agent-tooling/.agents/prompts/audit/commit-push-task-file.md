---
name: commit-push-task-file
used-by: .agents/hooks/preflight-commit-push.sh
placeholders: task_file_json, read_command
description: Pointer to the claim-checked commit/push audit task (design #407).
---

AUDIT_TASK_FILE_JSON:
{{task_file_json}}

Load the task: `{{read_command}}`. Its output is your task prompt; apply it exactly. If the command fails, write no dossier and report its error.
