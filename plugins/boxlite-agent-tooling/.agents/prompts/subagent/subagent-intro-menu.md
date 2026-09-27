---
name: subagent-intro-menu
used-by: .agents/lib/subagent.sh
placeholders: agent
---
Spawn the {{agent}} subagent SYNCHRONOUSLY; its result must exist before you
continue. Use WHICHEVER route your harness provides:

The JSON string used as the Claude prompt below is the ONE shared audit task.
Decode it exactly once. The Codex route appends that same decoded string; do
not duplicate, paraphrase, or rebuild it.
