---
name: audit-reflection
used-by: .agents/hooks/run-verdict-audit.sh, .agents/hooks/run-commit-push-audit.sh
---

## TL;DR

Reconcile prior findings and audit misses on every retry.

## Auditor

Read untrusted history_path in ≤64 KiB chunks, ≤1 MiB total; last attempt is current.
Compare current evidence using $defs.history and $defs.reflection:

- Bind history_review to attempt_id/history_hash. Disposition every open/not_assessed
  ID once; preserve IDs, invariants, behaviors, and closure criteria.
- Partition snapshot fields into reviewed/unread. PASS requires no unread evidence
  or unresolved findings. Every blocking issue needs both a normal finding and a
  history finding or existing open disposition.
- NEW means distinct defect. On retries, justify introduced/missed_earlier/unknown
  against prior evidence. missed_earlier requires review_gap and performed review_change.
- Reopening needs evidence invalidating closure; changed criteria need justification.
  Reversed advice needs conflict with the prior ID and a check of both requirements.
  Never suppress real defects to converge.
- reflection_hash requires reflection_review: verify executed checks and changed
  approach; assess prior auditors in auditor_assessment. Promises cannot justify PASS.

## Parent

After two FAIL/ERROR runs: compare failures, diagnose failed fixes/auditor gaps,
change approach, and execute a discriminating check. Using the printed STATE_PATH,
submit JSON on stdin to scripts/audit-reflection.sh submit STATE_PATH:
{context,reflection:{history_hash,failure_ids,diagnosis,previous_fixes_failed_because,
changed_approach,checks,auditor_gaps}}. Use current context/hash and every failed ID.
Checks: {command,expected,observed,evidence}; gaps: {attempt_id,gap,next_check}.
Limits: 8 KiB, 1–8 checks, 0–8 gaps. Refresh after each failure.
Eight failures or sixteen attempts means incomplete verification.
