---
name: pr-review-ack
used-by: .agents/hooks/preflight-pr-review.sh
placeholders: context, review_question
description: Human review acknowledgment and bounded recovery instructions.
---

Review required{{context}}. {{review_question}}
Require human-typed reviewed: <what changed>; no AI narrative, logs, or secrets.
Never infer or fabricate replies; never pre-fill. Abort and Show me the diff do not approve.
Claude's native hook records replies. Otherwise write .agents/state/pr-reviewed.json:
{"branch":"<current branch>","head":"<current HEAD>","message":"<verbatim response>","request":"<id>"}
Read id from .agents/state/pr-review-request.json. Then retry the same command.
