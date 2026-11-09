## TL;DR

Edit runtime instructions and questions in Markdown; code owns routing, serialization, deadlines, and state.

## Locations

| Content | Source |
| --- | --- |
| Audit tasks, controls, and recovery | `.agents/prompts/audit/` |
| Design gate | `.agents/prompts/design/` |
| PR descriptions, review, size, and decomposition | `.agents/prompts/pr/` |
| Shared questions, timed requests, and Force pass cards | `.agents/prompts/questions/` |
| Writing reminder | `.agents/prompts/reminders/` |
| API and network recovery | `.agents/prompts/resume/` |
| Subagent dispatch | `.agents/prompts/subagent/` |
| Watcher attachment and schedules | `.agents/prompts/watch/` |
| Standalone reminder | `.agents/hooks/rule-recency.md`; copy beside its script |
| Auditor procedures | `.claude/agents/*.md` |
| Workflow and skills | `guidance/workflow.md`, `.agents/skills/` |

## Maintenance

Use a qualified name, such as `subagent_prompt audit/commit-push-task "$root" ...`; lookup is relative to the prompt root. Keep templates one directory below that root and update callers, fixtures, and guidance when moving them.

- Use `user_question` for human questions; question policy defines timed choices once, and gates keep their own bindings and effects.
- For conversation, run `bash scripts/user-question.sh QUESTION SAFE_FALLBACK` from the plugin root.

Templates declare `used-by` and `placeholders`.

- `subagent_prompt` reads them on each call, strips metadata, and substitutes explicit values literally.
- Missing, blank, or unresolved templates fail before dispatch.
- JSON question templates receive escaped string contents or complete JSON values.

Keep error/status diagnostics, usage help, protocol markers, commands, and user-supplied text in code.

- Preserve output limits and test runtime edits through callers.
- The optional standalone reminder stays best effort.
- Do not modify the protected writing skill without explicit authorization.

## Runtime contracts

Lookup has no basename search, implicit Markdown inlining, or embedded Bash fallback. Callers explicitly require skill loading.

- Missing, empty, or unresolved templates block partial dispatch, acknowledgment consumption, and publication.
- Watch variants retain 1400-byte bounds and exact claim commands. Failure leaves authority with the lease owner. Acknowledgment recovery stays within 1200 bytes.
- Resume prompts load before wake-budget recording. The native Force pass card uses `.agents/prompts/questions/interactive-question.md`.
- Standalone reminders copy `.agents/hooks/rule-recency.sh` and `.agents/hooks/rule-recency.md` together without plugin libraries.
