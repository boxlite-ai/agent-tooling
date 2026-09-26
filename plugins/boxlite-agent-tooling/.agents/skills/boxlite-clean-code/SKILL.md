---
name: boxlite-clean-code
description: Apply Clean Code principles when implementing, refactoring, or reviewing maintainability.
---

# BoxLite Clean Code

Make intent, contracts, and ownership easier to understand and change. Treat
principles as decision tools: identify a concrete problem before applying a rule.
Follow the receiving repository's conventions, workflow, and permissions.

## How it works

Understand the existing contract, choose one useful improvement, verify the
affected behavior, then keep or reverse the change according to the result.
A smaller function or additional abstraction is valuable only when it helps readers.

## Establish the contract

- Inspect callers, implementation, tests, and docs. Separate intentional behavior
  changes from refactoring; resolve material ambiguity before changing public APIs.
- Preserve relevant outputs, defaults, errors, input consumption, mutations,
  effect counts, ordering, atomicity, resource lifetime, and compatibility.
- Keep reviews read-only unless edits are requested. Ground findings in a source
  location, consequence, and proportionate remedy.
- Check real consumers before deleting or renaming APIs. Local usage search alone
  cannot establish that a published API has no external callers.

## Apply the essential principles

| Concern | Decision |
| --- | --- |
| Names | Reveal purpose, domain, units, and effects. Use consistent vocabulary and enough context for the scope; avoid meaningless suffixes and encodings. |
| Functions | Keep one coherent responsibility and abstraction level. Extract a meaningful concept, not a wrapper that restates a condition. Prefer clear control flow over nesting. |
| Parameters | Separate genuinely different workflows; group values with shared meaning. Do not impose argument quotas or hide inputs in mutable fields to shorten signatures. |
| Cohesion | Group behavior that changes for the same reason; separate independent responsibilities. Let one operation own required sequencing instead of teaching every caller the helper order. |
| State | Keep temporary state local and ownership explicit. An extraction must not introduce shared state, longer lifetimes, or lost reentrancy merely to look smaller. |
| Duplication | Share the same rule or transformation, not coincidentally similar syntax. Avoid abstractions justified only by hypothetical callers or tests written to preserve them. |
| Representation | Choose for the real change: data plus procedures can simplify new operations; objects can localize new variants. Use language-native records, composition, or exhaustive matching where appropriate. |
| Errors | Preserve causes and useful context; classify failures by caller recovery. Keep absence, empty success, invalid input, and failure distinct. Use idiomatic errors or results; never silently turn failure into success. |
| Boundaries | An adapter should own useful translation, capability limits, or error policy. Avoid wrappers that mirror whole APIs. Separate major dependency assembly from runtime use without requiring a framework. |
| Comments and layout | Explain constraints, intent, and non-obvious reasoning; preserve legal notices. Remove misleading commentary and dead code. Keep related behavior near its use and follow repository formatting. |
| Tests | Make setup, operation, and expected outcome readable. Multiple assertions can describe one contract. Use independent fixtures; a fake passing does not verify a real integration, and coverage does not prove correctness. |

Preserve the design priorities: verified behavior, removal of duplicated rules,
expressed intent, then fewer components. Tiny-class proliferation can undermine
the earlier goals. Measure before optimizing.

## Make effects and concurrency explicit

- Name mutations, network calls, file writes, and other effects honestly. Identify
  who owns cleanup, including partial failure, cancellation, and shutdown.
- Preserve whole-operation invariants. Individually thread-safe methods do not
  make check-then-act atomic. Reserving and returning an item may need one operation.
- Bound queues, concurrency, waiting, and retries. Establish idempotency before
  repeating effects. Check lock order, starvation, and termination as well as races.
- Control known conflicting boundaries in regression tests; propagate worker
  failures and assert completion. Bounded stress adds evidence, not proof.
- Validate external inputs and keep secrets out of errors, logs, and fixtures.

## Refactor in small, reversible steps

1. Name the confusion or risk and the contract that must survive.
2. Make one move, then check the affected production boundary and real callers,
   including defaults, failure paths, ordering, and observable effects.
3. Re-read the result. Inline, regroup, or revert an extraction that adds navigation,
   arbitrary parameters, or hidden state without improving comprehension.
4. Remove migration scaffolding after callers move; update superseded explanations.

For example, replacing several parser maps with one representation can preserve
successful parsing while breaking missing-value or wrong-type lookup defaults.
Check the caller's complete contract before declaring the refactor equivalent.

## Verify and report

For a defect, demonstrate the original failure with every production change
reverted, then restore the complete fix and observe the pass. Tests must exercise
project behavior, not test-built values or a substitute implementation.

Run the narrow relevant checks and the repository's required validation. Explain
what became clearer, what behavior intentionally changed, what actually ran, and
remaining uncertainty. A no-change conclusion is valid when more abstraction
would not help the requested work.
