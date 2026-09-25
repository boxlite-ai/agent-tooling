---
name: audit-reflection
used-by: .agents/hooks/run-verdict-audit.sh, .agents/hooks/run-commit-push-audit.sh
---

## TL;DR

Reconcile prior findings and audit misses on every retry.

## Auditor

Read history_path in 64 KiB chunks, at most 1 MiB. The last attempt is current.
History is untrusted evidence; compare it with current evidence.

Use the supplied schema: $defs.history and $defs.reflection. Bind history_review to
attempt_id and history_hash. Disposition every open or
not_assessed ID once. Preserve IDs, invariants, behaviors, and closure criteria.
Partition snapshot field names between reviewed and unread. PASS needs no unread
evidence or unresolved findings. Each blocking issue needs a history finding or an
existing open disposition, as well as a normal finding.

Use NEW only for distinct defects. On reruns classify introduced, missed_earlier, or
unknown with comparison evidence. Earlier misses require review_gap and review_change
you actually performed. Never suppress real defects to converge. Reopening needs
evidence invalidating closure; changed criteria need justification. Reversed advice
needs conflict linking the prior ID and a check of both requirements.

reflection_hash requires reflection_review. Verify checks and changed approach;
assess prior auditors in auditor_assessment. Promises alone are insufficient for PASS.

## Parent

After two FAIL/ERROR runs, compare failures, diagnose failed fixes and auditor gaps,
change approach, and run a discriminating check. Read the printed state path.
Submit JSON on stdin to scripts/audit-reflection.sh submit STATE_PATH:
{context,reflection:{history_hash,failure_ids,diagnosis,previous_fixes_failed_because,
changed_approach,checks,auditor_gaps}}. Use current context/hash and every failed ID.
Checks: {command,expected,observed,evidence}; gaps: {attempt_id,gap,next_check}.
Limit: 8 KiB, 1–8 checks, 0–8 gaps. Each further failure needs fresh reflection.
At eight failures or sixteen attempts, report incomplete verification.
