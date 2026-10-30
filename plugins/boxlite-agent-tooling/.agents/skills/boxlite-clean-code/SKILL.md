---
name: boxlite-clean-code
description: Apply Clean Code principles when implementing, refactoring, or reviewing maintainability.
---

# BoxLite Clean Code

Clarify intent, contracts, ownership with obvious code and small, task-relevant
changes. Avoid unrelated rewrites/reformatting; follow repository workflow/permissions.

## How it works

Establish contracts; improve, verify, keep/reverse.
Apply principles to real problems; abstractions must earn their cost.

## Examples

Load relevant [examples](references/examples.md); keep repository examples local.
Before implementing/reviewing non-obvious algorithms, layouts, protocols,
ownership, or concurrency, read [Comments](references/comments.md).

## Establish the contract

- Before implementing, search code; inspect callers, implementation, docs, and nearby
  tests/scripts. Follow local naming, layout, tests, logging, errors, formatter,
  linter, language level, and module style.
- Separate intentional behavior changes from refactoring; resolve material API
  ambiguity. Preserve outputs, defaults, errors, input consumption, mutations,
  effect counts, ordering, atomicity, resource lifetime, and compatibility.
- Review read-only unless edits are requested; give source location, consequence, proportionate remedy.
- Check real consumers before deleting/renaming APIs; local search cannot exclude external callers.

## Apply the essential principles

| Concern | Decision |
| --- | --- |
| Names | Reveal purpose, domain, units, effects, scope; use consistent vocabulary and boolean predicates (`is_ready`). Avoid meaningless suffixes/encodings and `data`/`info`/`tmp`/`thing`/`handle`/`process` outside tiny scopes. Use each variable for one concept per scope. |
| Functions | One responsibility and abstraction level. Extract concepts, not wrappers restating conditions. Prefer guards and early returns over nesting. |
| Parameters | Short argument lists; group related values. Split boolean-selected workflows. No argument quotas or moving inputs to mutable fields to shorten signatures. |
| Cohesion | Group related state/behavior; separate reasons to change. Expose 1–2 facade operations; hide internals/helpers so callers need not learn order, shared state, or helper graphs. Exempt small, pure, stateless utility modules. |
| State | Keep temporary state local, ownership explicit. Extraction must not add shared state, extend lifetimes, or lose reentrancy. |
| Duplication | Share rules, policies, transformations—not similar syntax. Keep small local duplication when abstraction hides behavior. Build only what is used; delete dead code. Reject hypothetical callers or tests preserving unused abstractions. |
| Representation | Consider data/procedures for new operations, objects for variants. Prefer composition over inheritance/framework magic; use native records or exhaustive matches when apt. |
| Errors | Fail fast on missing config/invalid input. Include operation, resource ID, endpoint/status, input shape where applicable; preserve causes, mask secrets. Classify by recovery; distinguish absence, empty success, invalid input, failure. Use idiomatic errors/results; never swallow failure. |
| Boundaries | Validate untrusted inputs on entry; trust validated internals. Ask what each layer needs to know. Adapters own translation, capability limits, or error policy; avoid whole-API mirrors. Separate major assembly from runtime use; no framework required. |
| Comments/layout | Explain intent, contracts, constraints, trade-offs, non-obvious mechanisms. Use helpful diagrams/worked examples; verify against code. Preserve legal notices; remove misleading/redundant/obsolete comments. Keep related behavior nearby; follow project formatting. |
| Tests | Readable setup, operation, outcomes; multiple assertions may cover one contract. Independent fixtures. Fakes don't verify integration; coverage doesn't prove correctness. |

Prioritize verified behavior, shared rules, intent, then fewer components.
Avoid tiny-class proliferation. Measure before optimizing.

## Make effects and concurrency explicit

- Show effects at call sites: mutations, network calls, file writes, process exec.
  Own all resource cleanup through partial failure, cancellation, and shutdown.
- Preserve whole-operation invariants: thread-safe methods do not make check-then-act
  atomic. Reserve and return an item in one operation when needed.
- Make external-work timeouts, retries, and cancellation explicit. Bound queues,
  concurrency, memory, and waiting. Establish idempotency before retrying effects,
  or document why repetition is safe. Check lock order, starvation, and termination.
  Await completion signals; do not guess completion with sleeps.
- Control conflicting boundaries in regression tests; propagate worker failures
  and assert completion. Bounded stress supplies evidence, not proof.
- Keep secrets out of errors/logs/fixtures.

## Refactor in small, reversible steps

1. Name the risk/confusion and contract to preserve.
2. Make one move; check real callers and production boundaries: defaults, failures,
   order, effects. Parser-map merges must preserve missing/wrong-type lookup
   defaults and valid parsing.
3. Re-read; reverse extractions adding navigation, arbitrary parameters, or hidden
   state without clarity. After callers move, remove migration scaffolding and
   update superseded explanations. Skip abstractions without value.

## Verify and report

Test changed branches, parsing, retries, security, and boundaries through project behavior;
avoid test-built values, substitutes, and framework-only checks. Never weaken assertions;
fix code or establish an intentional contract change.

For fixes to existing behavior (new APIs/wrappers included), reproduce before fixing;
follow repository full-revert and compatibility-adapter rules. For wholly new contracts,
prove no prior equivalent; test implementation and security boundaries;
explain why defect proof is not applicable. Mixed changes apply both per claim.

Run focused then risk/required checks. Report checks run, intentional changes, clarity,
blockers, risks, uncertainty.
