---
name: timed-user-prompt
used-by: .agents/lib/user-question.sh
placeholders: deadline, fallback, question
description: Shared non-blocking human-confirmation deadline.
---

{{question}}
Deadline: Unix {{deadline}}. Never extend this attempt's window.
Wait at most 60 seconds at a time while preparing; keep the task active.
No valid user reply by the deadline: {{fallback}}. Silence never approves.
