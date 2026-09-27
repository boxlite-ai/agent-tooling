---
name: subagent-claude
used-by: .agents/lib/subagent.sh
placeholders: claude_agent_json, description_json, task_json
---
  Claude Code
    Task(subagent_type={{claude_agent_json}},
         description={{description_json}},
         prompt={{task_json}})
    run_in_background: false
