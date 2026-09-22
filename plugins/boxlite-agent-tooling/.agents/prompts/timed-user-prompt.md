---
name: timed-user-prompt
used-by: .agents/lib/timed-user-prompt.sh
placeholders: deadline, fallback, route
description: Shared non-blocking human-confirmation deadline.
---

{{route}}
Deadline: Unix {{deadline}}. Never restart the three-minute window.
Wait at most 60 seconds at a time while preparing; keep the task active.
No valid typed reply by the deadline: {{fallback}}. Silence never approves.
