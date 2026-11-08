---
name: pr-review-ack
used-by: .agents/hooks/preflight-pr-review.sh
placeholders: context, review_question
description: Human review acknowledgment and bounded recovery instructions.
---

Review required{{context}}. {{review_question}}
Use the reviewed: line shown for this request. Include what changed and omit logs and secrets.
Never infer, fabricate, or pre-fill replies. Keeping draft or inspecting the diff gives no approval.
The prompt hook records a timely reply in the checkout that opened the question. Retry the same command.
