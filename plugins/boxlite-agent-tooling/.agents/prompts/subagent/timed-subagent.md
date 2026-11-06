---
name: timed-subagent
used-by: .agents/hooks/audit/run-verdict-audit.sh
placeholders:
description: The record step a headless verdict auditor gets at its deadline.
---

Run no more checks; stop background tasks and remove scratch worktrees you started.

- A call reported as rejected was stopped.
- Write the dossier from collected evidence; apply the supplied deadline policy: confirmed blockers FAIL; otherwise PASS, with unfinished checks as advisories and known unverified proof blocked.
- If you rejected the task input, say so and write nothing.
