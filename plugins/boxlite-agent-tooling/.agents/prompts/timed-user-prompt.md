---
name: timed-user-prompt
used-by: .agents/lib/timed-user-prompt.sh
placeholders: deadline, fallback
description: Shared non-blocking human-confirmation deadline.
---

Ask once through non-blocking input (Codex: request_user_input_async); avoid blocking modals.
Deadline: Unix {{deadline}}. The recorded three-minute window must never restart.
Use waits of at most 60 seconds while preparing; do not end the task while waiting.
Without a valid typed reply by the deadline: {{fallback}}. Silence never grants approval.
