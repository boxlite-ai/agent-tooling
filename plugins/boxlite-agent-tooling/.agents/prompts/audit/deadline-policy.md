---
name: deadline-policy
used-by: scripts/design-worker.py, .agents/hooks/preflight-commit-push.sh, .agents/hooks/audit/run-commit-push-audit.sh, .agents/hooks/audit/run-verdict-audit.sh, .agents/skills/boxlite-verdict-audit/SKILL.md
---

## Runtime deadline

Deadline: task or history_path's attempts[-1].input.deadline (Unix seconds).
Never invent/extend it. Before expiry, normal completeness rules apply.

At expiry, stop checks, clean up owned work, deliver valid output:

- FAIL iff confirmed blockers remain, including prior findings; otherwise PASS,
  even with zero checks completed.
- Advisory per unfinished/unread/unverified check: reason, remaining work. Never
  claim verification or make expiry a finding.
- Partition history snapshot keys truthfully. Keep unresolved IDs open/not_assessed;
  only evidence resolves/retracts them.
- Unassessed required reflection: assessment="unchecked", reasons in evidence,
  auditor_assessment, and advisories. Confirmed insufficient reflection still blocks.
- Known unverified verdict claim: proof.status="blocked", nonempty deadline reason.
  Unknown claims: disclose unread scope; never invent proof.

Only completeness FAIL rules yield. Identity/binding/schema/cancellation remain enforced.
No valid report, crash, or hard kill: execution error, never automatic PASS.
