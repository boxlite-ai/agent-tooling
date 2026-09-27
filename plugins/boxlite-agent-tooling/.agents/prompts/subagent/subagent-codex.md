---
name: subagent-codex
used-by: .agents/lib/subagent.sh
placeholders: task_name_json, codex_message_json
---
  Codex
    collaboration.spawn_agent(
      task_name={{task_name_json}},
      fork_turns="none",
      message=CONCAT({{codex_message_json}}, DECODED_TASK_PROMPT_ABOVE))
