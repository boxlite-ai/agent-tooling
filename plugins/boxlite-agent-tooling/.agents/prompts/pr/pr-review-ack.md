---
name: pr-review-ack
used-by: .agents/hooks/preflight-pr-review.sh
placeholders: context, review_question
description: Human review acknowledgment and bounded recovery instructions.
---

Review required{{context}}. {{review_question}}
Human must type reviewed: <what changed>; no AI narrative, logs, or secrets.
Never infer, fabricate, or pre-fill replies. Abort/Show me the diff aren't approval.
Claude records native replies; otherwise write .agents/state/pr-reviewed.json:
{"branch":"<current branch>","head":"<current HEAD>","message":"<verbatim response>","request":"<id>"}
Read id from .agents/state/pr-review-request.json. Then retry the same command.
