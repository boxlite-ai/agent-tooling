## TL;DR

Edit runtime instructions and questions in Markdown; code owns routing, serialization, deadlines, and state.

## Locations

| Content | Source |
| --- | --- |
| Subagent dispatch, questions, audit tasks, watcher attachment, reminders | `.agents/prompts/*.md` |
| Standalone reminder | `.agents/hooks/rule-recency.md`; copy beside its script |
| Auditor procedures | `.claude/agents/*.md` |
| Workflow and skills | `guidance/workflow.md`, `.agents/skills/` |

## Maintenance

Templates declare `used-by` and `placeholders`. `subagent_prompt` reads them on each call, strips metadata, and substitutes explicit values literally. Missing, blank, or unresolved templates fail before dispatch. JSON question templates receive escaped string contents or complete JSON values.

Keep error/status diagnostics, usage help, protocol markers, commands, and user-supplied text in code. Preserve output limits and test runtime edits through callers. The optional standalone reminder stays best effort. Do not modify the protected writing skill without explicit authorization.
