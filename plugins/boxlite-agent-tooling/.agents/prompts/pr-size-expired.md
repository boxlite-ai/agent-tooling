---
name: pr-size-expired
used-by: .agents/lib/pr-size.sh
placeholders: lines, base, head, request_id, state, tooling
description: Expiry preserves splitting unless a human explicitly requests a new attempt.
---

PR size {{lines}} exceeds 400 lines. The exception deadline expired.
Current base {{base}}, head {{head}}. Reuse or create one tracking issue with a PR
checklist and split into coherent tested PRs of at most 400 lines. Create separate
issues only for work needing independent tracking.

Only a new explicit human instruction to request the exception again permits renewal.
Never infer or invent that instruction, renew autonomously, or accept a late approval.
First retry this guarded PR operation to remeasure; show its current diff, base/head,
size, and split plan. If that request remains expired, run
{{tooling}}/scripts/timed-user-prompt.sh renew with arguments {{state}},
{{request_id}}, and the verbatim human renewal instruction, safely quoted.
Then retry the guarded operation and ask for a fresh pr-size-exception: reason using
the new request ID and deadline. Renewal is not approval; other gates still apply.
