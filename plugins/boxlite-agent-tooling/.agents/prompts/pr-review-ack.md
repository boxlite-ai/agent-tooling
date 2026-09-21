---
name: pr-review-ack
used-by: .agents/hooks/preflight-pr-review.sh
placeholders: context, review_question
description: Human review acknowledgment and bounded recovery instructions.
---

PR-review acknowledgment required{{context}}.
Use AskUserQuestion on Claude or request_user_input on Codex. Ask the human:
{{review_question}}
Also confirm no internal/AI narrative, pasted logs, or secrets.
They must choose Other and type:
  reviewed: <one-line summary in their own words of what this PR changes>
Options: Abort and Show me the diff.
Read the free-form Other text (Claude calls it notes). If it starts with 'reviewed: '
followed by nonblank text, write it verbatim to .agents/state/pr-reviewed.json:
  { "branch": "<current branch>", "head": "<current HEAD>", "message": "<verbatim Other text>" }
Then retry the same gh command. Abort means no write/retry. Show me the diff means
show the current diff/log and re-ask. Invalid text means re-ask without writing.
Never infer the acknowledgment. Never fabricate, paraphrase, or pre-fill it.
