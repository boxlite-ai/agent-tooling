---
name: pr-size-exception
used-by: .agents/lib/pr-size.sh
placeholders: lines, base, head, request_id, state, tooling
description: Ask whether to bypass the size guideline or split the measured PR.
---

PR size: {{lines}} added code lines; guideline 400.

- Base {{base}}, head {{head}}.
- Show the diff before asking.
- Bypass needs no written justification and applies only to this diff; other gates remain.
- Never invent a choice or treat a default selection as an answer.
- For a timely typed choice, run {{tooling}}/scripts/timed-user-prompt.sh respond with {{state}}, {{request_id}}, and the exact selected label, safely quoted.
- Retry after bypass.
- On Split PR or timeout, reuse or create one tracking issue with a PR checklist and split into small tested PRs.
- Create separate issues only for independent tracking.
