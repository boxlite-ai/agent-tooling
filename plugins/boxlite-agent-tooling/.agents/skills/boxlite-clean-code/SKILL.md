---
name: boxlite-clean-code
description: Apply Clean Code principles when implementing, refactoring, or reviewing maintainability.
---

# BoxLite Clean Code

Clarify intent, contracts, and ownership. Prefer obvious code and small, task-relevant
changes; don't rewrite or reformat unrelated code. Follow repository workflow and permissions.

## How it works

Establish the contract, improve, verify, then keep or reverse.
Apply principles to concrete problems; abstractions must earn their cost.

## Examples

[Example index](references/examples.md): read only relevant topics.
Keep repository examples in local instructions.

## Establish the contract

- Search code before implementing. Inspect callers, implementation, docs, and nearby
  tests/scripts. Follow local naming, module layout, tests, logging, errors, formatter,
  linter, language level, and module style.
- Separate intentional behavior changes from refactoring; resolve material API
  ambiguity. Preserve outputs, defaults, errors, input consumption, mutations,
  effect counts, ordering, atomicity, resource lifetime, and compatibility.
- Review read-only unless edits are requested; give source location, consequence, and proportionate remedy.
- Check real consumers before deleting/renaming APIs; local search cannot rule out external callers.

## Apply the essential principles

| Concern | Decision |
| --- | --- |
| Names | Reveal purpose, domain, units, effects, and scope with consistent vocabulary. Booleans are predicates (`is_ready`). Avoid meaningless suffixes/encodings and `data`/`info`/`tmp`/`thing`/`handle`/`process` outside tiny scopes. Never reuse a variable for two concepts in one scope. |
| Functions | One responsibility and abstraction level. Extract concepts, not wrappers restating conditions. Prefer guard clauses and early returns over nesting. |
| Parameters | Short argument lists; group related values. Split boolean-selected workflows. No argument quotas or moving inputs into mutable fields just to shorten signatures. |
| Cohesion | Group related state/behavior; separate reasons to change. Expose 1–2 facade operations; keep internals/helpers private so callers need not learn order, shared state, or helper graphs. Small stateless utility modules of pure helpers are exempt. |
| State | Keep temporary state local and ownership explicit; extraction must not add shared state, longer lifetimes, or lost reentrancy. |
| Duplication | Share rules, policies, transformations—not similar syntax. Keep small local duplication when abstraction hides behavior. Build only what is used; delete dead code. Reject hypothetical callers or tests preserving unused abstractions. |
| Representation | Consider data/procedures for new operations, objects for variants. Prefer composition over inheritance/framework magic; use native records or exhaustive matches where appropriate. |
| Errors | Fail fast on missing config/invalid input. Include operation, resource ID, endpoint/status, input shape where applicable; preserve causes, mask secrets. Classify by recovery; distinguish absence, empty success, invalid input, failure. Use idiomatic errors/results; never swallow failure. |
| Boundaries | Validate untrusted inputs on entry; trust validated internals. Ask what each layer needs to know. Adapters own translation, capability limits, or error policy; avoid whole-API mirrors. Separate major assembly from runtime use; no framework required. |
| Comments/layout | Explain why: intent, constraints, trade-offs. Preserve legal notices; remove misleading, redundant, or dead-decision comments. Keep related behavior nearby; follow formatting conventions. |
| Tests | Readable setup, operation, outcomes; multiple assertions may cover one contract. Independent fixtures. Fakes don't verify integration; coverage doesn't prove correctness. |

Prioritize verified behavior, shared rules, intent, then fewer components.
Avoid tiny-class proliferation. Measure before optimizing.

## Make effects and concurrency explicit

- Expose effects at call sites: mutations, network calls, file writes, process exec.
  Own cleanup of all resources through partial failure, cancellation, and shutdown.
- Preserve whole-operation invariants: individually thread-safe methods do not make
  check-then-act atomic. Reserve and return an item in one operation when needed.
- Make external-work timeouts, retries, and cancellation explicit. Bound queues,
  concurrency, memory, and waiting. Establish idempotency before retrying effects,
  or document why repetition is safe. Check lock order, starvation, and termination.
  Wait for completion signals instead of sleeping to guess event completion.
- Control conflicting boundaries in regression tests; propagate worker failures
  and assert completion. Bounded stress supplies evidence, not proof.
- Keep secrets out of errors, logs, and fixtures.

## Refactor in small, reversible steps

1. Name the risk/confusion and contract to preserve.
2. Make one move; check real callers and production boundaries, including defaults,
   failures, order, effects. Merging parser maps must preserve missing/wrong-type
   lookup defaults as well as valid parsing.
3. Re-read; reverse extractions adding navigation, arbitrary parameters, or hidden state
   without clarity. Remove migration scaffolding and update superseded explanations
   after callers move. Make no change when abstraction adds no value.

## Verify and report

Add/update tests for changed branching, parsing, retries, security, and boundaries.
For bugs, write a focused reproducer first; observe the defect before fixing.
Verify with every production change reverted, then restore the complete fix
and observe the pass; follow the repository's compatibility-adapter procedure.

Test project behavior, not test-built values, substitutes, or only a library/framework.
Never weaken assertions for a pass; fix code or establish an intentional contract change.

Run the smallest relevant check first; broaden for risk and required validation.
Claim only checks run. Report intentional changes, clarity, observed results,
blockers, residual risk, and uncertainty.
