---
name: subagent-retry
used-by: .agents/lib/subagent.sh
placeholders: task_name_json, retry_message_json
---
    If task_name={{task_name_json}} already exists, inspect that exact retained handle.
    If it is already running, wait for it synchronously. If it is idle,
    completed, or failed, retry it synchronously with:
    collaboration.followup_task(
      target={{task_name_json}},
      message={{retry_message_json}})
    Do not create a sibling task name for this generation; if the retained
    handle cannot be established, remain blocked.
