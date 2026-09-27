## TL;DR

Edit runtime instructions and questions in Markdown; code owns routing, serialization, deadlines, and state.

## Locations

| Content | Source |
| --- | --- |
| Audit tasks, controls, and recovery | `.agents/prompts/audit/` |
| Design gate | `.agents/prompts/design/` |
| PR descriptions, review, size, and decomposition | `.agents/prompts/pr/` |
| Timed questions and interactive rendering | `.agents/prompts/questions/` |
| Writing reminder | `.agents/prompts/reminders/` |
| API and network recovery | `.agents/prompts/resume/` |
| Subagent dispatch | `.agents/prompts/subagent/` |
| Watcher attachment and schedules | `.agents/prompts/watch/` |
| Standalone reminder | `.agents/hooks/rule-recency.md`; copy beside its script |
| Auditor procedures | `.claude/agents/*.md` |
| Workflow and skills | `guidance/workflow.md`, `.agents/skills/` |

## Maintenance

Use a qualified name, such as `subagent_prompt audit/commit-push-task "$root" ...`; lookup is relative to the prompt root. Keep templates one directory below that root and update callers, fixtures, and guidance when moving them.

Templates declare `used-by` and `placeholders`. `subagent_prompt` reads them on each call, strips metadata, and substitutes explicit values literally. Missing, blank, or unresolved templates fail before dispatch. JSON question templates receive escaped string contents or complete JSON values.

Keep error/status diagnostics, usage help, protocol markers, commands, and user-supplied text in code. Preserve output limits and test runtime edits through callers. The optional standalone reminder stays best effort. Do not modify the protected writing skill without explicit authorization.
