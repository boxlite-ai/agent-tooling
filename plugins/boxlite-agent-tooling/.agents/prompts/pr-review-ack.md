---
name: pr-review-ack
used-by: .agents/hooks/preflight-pr-review.sh
placeholders: context, review_question
description: Human review acknowledgment and bounded recovery instructions.
---

Review required{{context}}. Ask: {{review_question}}
Also confirm no internal/AI narrative, pasted logs, or secrets.
Require human-typed free text: reviewed: <what this PR changes in their own words>.
Abort and Show me the diff never grant approval. Do not pre-fill an answer.
Read the id from .agents/state/pr-review-request.json. For a valid response, write
.agents/state/pr-reviewed.json:
{"branch":"<current branch>","head":"<current HEAD>","message":"<verbatim response>","request":"<id>"}
Then retry the same command. Never infer or fabricate the human response.
