---
name: pr-size-declined
used-by: .agents/lib/pr-size.sh, scripts/continue-timed-prompts.sh
placeholders: request_id, state, tooling
description: A split choice remains in force until a new explicit human request.
---

The user chose Split PR. Reuse or create one tracking issue with a PR checklist
and split into coherent tested PRs. Do not ask again automatically.
Only a new explicit human instruction permits reconsideration: run
{{tooling}}/scripts/timed-user-prompt.sh renew with {{state}}, {{request_id}},
and that verbatim instruction, safely quoted. Retry the guarded operation to
remeasure and ask again. Renewal grants no bypass.
