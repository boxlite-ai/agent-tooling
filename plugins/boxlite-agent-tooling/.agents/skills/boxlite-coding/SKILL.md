---
name: boxlite-coding
description: Apply Clean Code principles when implementing, refactoring, or reviewing maintainability.
---

# BoxLite Coding

Make intent, contracts, and ownership easier to understand and change. Use
evidence from the requested code to choose a proportionate improvement; a smell
is a reason to investigate, not a verdict. Follow the receiving repository's
conventions, workflow, and permissions.

## How it works

Establish the observable contract, make one useful structural change, verify the
affected behavior, then keep or reverse the change according to the result.
The references supply decision criteria and examples, not mandatory patterns.

## Establish the task and contract

- **Review:** remain read-only unless edits are requested. Report a source
  location, concrete consequence, and small remedy; skip unsupported style claims.
- **Refactor:** inspect callers, implementation, tests, and docs before moving
  code. Preserve relevant outputs, defaults, errors, input consumption, mutation,
  effect counts, ordering, atomicity, resource lifetime, and compatibility.
- **Implement or fix:** distinguish intended behavior changes from structural
  cleanup. Resolve material contract ambiguity before changing a public boundary.
  For a defect, demonstrate the original failure before verifying the fix.

Check real consumers before deleting or renaming an API. Local usage search alone
does not establish that a published API has no external callers. Do not promote
successful local checks into evidence about untested integrations or deployments.

## Choose the relevant guidance

| Task concern | Read when needed |
| --- | --- |
| Naming, responsibility, representation, errors, tests, dependencies, concurrency | [Decision guide](references/decision-guide.md); use the relevant section |
| A refactor changes several collaborating parts or its benefit is unclear | [Refactoring cases](references/refactoring-cases.md) |
| Attribution, edition, chapter coverage, or checking a book claim | [Book map](references/book-map.md) |

## Work in reversible steps

1. Name the concrete difficulty: hidden effects, ambiguous units, duplicated
   policy, scattered change, leaked call order, or an unprotected invariant.
2. Choose the smallest useful move. Extraction should introduce a meaningful
   concept or owner. Similar syntax alone does not establish a shared rule.
3. Run checks at the changed boundary, including relevant failures and callers.
   Tests must exercise project behavior, not values constructed by the assertion.
4. Re-read the result. Inline, regroup, or revert an extraction that adds navigation,
   arbitrary parameters, or hidden mutable state without improving comprehension.
5. Remove obsolete paths and migration scaffolding once callers have moved;
   update explanations that describe the old behavior.

Use language-native error and data models. Do not impose numeric size quotas,
mandatory object hierarchies, or an interface for every class. Preserve legal
notices and comments explaining domain constraints, protocols, or non-obvious
reasoning. Keep atomic operations intact even when they both mutate and return.

## Verify and report

Use the narrow relevant checks and the repository's required validation. For a
regression test, remove every production change and observe the original defect,
then restore the complete fix and observe the pass. Keep test adaptation limited
to exercising the old contract; never implement the fix in the test.

For changes, explain what became easier to understand, the preserved or explicitly
changed contract, actual verification, and remaining uncertainty. For reviews,
separate demonstrated defects from optional improvements. A no-change conclusion
is valid when an additional abstraction would not help the requested work.

## Source

Original synthesis of Robert C. Martin et al., *Clean Code*, first edition,
with contemporary adaptations identified in the references. See the
[edition and chapter map](references/book-map.md); no book listings are bundled.
