---
name: adversarial-iteration
description: Iterate design-review findings through evidence, fix, and fresh review.
---

# Adversarial Iteration

Use for related design failures and fix-induced defects, not typos.

Read the [ledger](references/iteration-ledger.md) before starting, the [reviewer
adapter](references/reviewer-receipt-adapter.md) before reviews, and the [fixer
prompt](references/round-agent-prompt.md) before fixes.

## Roles and states

```text
freeze baseline → independent reviewer → revision-bound receipt
                                      ├─ FINDINGS → fresh fixer → CANDIDATE → verify
                                      │                         ├─ failed → BLOCKED → fresh correction attempt
                                      │                         └─ passed → review again
                                      ├─ explicit ZERO_FINDINGS → termination gates
                                      └─ missing/invalid receipt → INPUT_ERROR

two consecutive fix-attempt-induced material defects → DIVERGED → split or rebaseline
```

- Orchestrator owns the frozen surface and ledger. The read-only reviewer produces
  findings or explicit zero. A fresh fixer consumes `FINDINGS` for A1; A2+ consumes the
  preceding evidence-bound `BLOCKED` receipt.
- Never infer `ZERO_FINDINGS` from missing findings or a fixer summary. Missing,
  malformed, or wrong-surface review evidence is `INPUT_ERROR`.
- Run autonomously in `/loop`; do not commit before termination.

## Preserve the review surface

Freeze the objective, scoped instruction/spec set, full OID, snapshot, and surface.
Bind `change_objective_digest` and `applicable_instructions_digest` through reviewer
request/receipt and fixer dispatch/candidate. Drift is `INPUT_ERROR`; changed intent
requires rebaseline. Union every fix delta and retain lifecycle/adjacent evidence.

Before each review, run bounded local forward/reverse-reference, schema/event,
lifecycle, and variant discovery. Add validated adjacent contracts first. Incomplete or
opaque discovery cannot authorize public review or zero.

Preserve an immutable pre-attempt snapshot; a fingerprint is not one. Bind red proof to
the finding's immutable defect snapshot, not an already-fixed correction snapshot.
Reuse it only while snapshot, reproducer, adapter, and signal are unchanged. Run
restores and mutants separately in disposable copies, never the authoritative tree.

Each receipt binds the fingerprint and classifies every surface/adjacent item full,
partial, or unread. Inherited context is not coverage; zero requires no partial/unread.

## REFLECT before fixing

For each stable finding ID, state:

1. which artifact decision violated the invariant;
2. which assumption went unverified and why;
3. which repository rule was violated;
4. which cheap check would have caught it;
5. which revision or hunk introduced it, or `unknown` without evidence.

Name each per-finding failure class. Add a shared pattern only with evidence.

Run all four checks before changing production code:

1. **Timeline:** draw interleavings for concurrent state and find check/act gaps.
2. **Upstream contract:** read the producer; do not infer semantics from a type name.
3. **Lifecycle:** trace initialization through teardown, including in-flight work and
   stop order.
4. **Variants:** enumerate every covered type’s destructor, serializer, and contract.

At two or more occurrences, require the cheapest repository-specific executable
preflight with positive/negative fixtures until installed. Otherwise require
revision-bound evidence.

## Reproduce, fix, and verify

- On the immutable defect snapshot, observe the system-level reproducer fail. Follow
  two-side and test-only compatibility-adapter rules. An earlier setup failure is
  `INVALID` unless it is the defect.
- Plan from the REFLECT class, reproducer assertion, decisive cheap check, smallest
  satisfying primitive, and adjacent contracts needing coverage; then implement it.
- Give each finding a semantic mutant against the current API. Require independent potency
  adjudication; then run all reproducers and mutants. Survivors, weak assertions, or
  invalid baselines block handoff.
- The orchestrator re-runs verification and records phase-bound argv, exit, digests,
  and decisive signal. Self-reported counts are not evidence.

## Handoff and divergence

Before review, search validated changed-file argv for round narrative and scaffolding,
using end-of-options and no shell-built path list.
Update the ledger and return the risk-first summary. Truncated conversation is never
the cumulative source of truth.

The orchestrator evaluates the full ledger before dispatch. Return `DIVERGED`, make no
further fix, and do not commit when either condition holds:

1. two consecutive reviewer receipts identify a material defect introduced by the
   immediately preceding fix; or
2. a failure class recurs after its repository-specific preflight was installed.

`DIVERGED` is not success. Return a split or rebaseline plan around independently
reviewable invariants, not arbitrary line or file counts.

## Termination

Complete only when all conditions hold:

1. an independent reviewer returns explicit `ZERO_FINDINGS`, bound to the current
   fingerprint, with every surface and adjacent review item fully read;
2. every finding is closed with evidence and a green system-level reproducer;
3. current receipts kill every mutant and pass every adjacent-contract/preflight check;
4. independent verification receipts are complete and remaining design risk is empty.

Before accepting zero or `COMPLETE`, recapture HEAD, status, item/contract digests, and
review target. Require the accepted binding; generation cannot detect external writes.

Optional reviewer command: `/codex:adversarial-review`, accepted only through the
reviewer adapter. Run `/loop` with dynamic pacing and no interval. The ledger, not
conversation history, is the audit trail.
