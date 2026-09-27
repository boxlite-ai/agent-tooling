---
name: commit-push-retry
used-by: .agents/hooks/preflight-commit-push.sh
placeholders: instruction, target_command_note
---
{{instruction}}

Retry the same git command after the verdict reports PASS.{{target_command_note}}
