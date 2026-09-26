# Refactoring as an experiment

These original summaries explain decisions, reversals, and useful checks from the
first edition of *Clean Code*. Apply the reasoning to the actual contract; the
book's intermediate and final listings are not portable implementation templates.

## Args: migrate one responsibility at a time

Repeated changes for additional argument types motivate an abstraction. The
refactor introduces a marshaler, migrates one type, temporarily keeps old and new
maps, then removes obsolete maps and forwarding helpers as their callers move.
Adding a real argument type checks whether the boundary localizes change.

Unit tests remain green while acceptance tests expose a wrong-type Boolean lookup
that must still return false. A representation change disturbed a caller-visible
fallback (ch. 14, pp. 212–250; acceptance-test surprise, p. 224).

**Apply:** record existing missing-value, wrong-type, token-consumption, and error
contracts; check component and acceptance behavior after the representation move.
Temporary duplication is useful migration scaffolding, not a reason to keep both
paths permanently. Do not copy the example's silent defaults into an unrelated API.

## JUnit: reverse an extraction when it stops helping

The comparison formatter starts with substantial tests. Changes clarify original
versus compacted strings and normalize suffix state. An explicit prefix parameter
exposes sequencing but is then rejected as arbitrary; one operation owns the
ordered analysis. Later revisions inline earlier extractions and return temporary
values to local scope (ch. 15, pp. 258–265).

**Apply:** check whether a parameter represents meaningful data or merely forces
call order. Reconsider extractions after surrounding code changes. Preserve null,
equality, overlap, empty-difference, truncation, and context-boundary behavior.
Clarity can improve by inlining; helper count is not a success metric.

## SerialDate: inspect consumers and semantic assumptions

Additional tests reveal weekday boundary defects before restructuring. The author
moves potentially reusable data near its only current user, then deletes an
elegant enum-based helper and its tests after discovering no real consumer.
Moving weekday arithmetic also requires exposing its ordinal-origin dependency;
successful compilation alone would not establish correctness
(ch. 16, pp. 268–282; detailed listings, app. B, pp. 349–407).

**Apply:** separate bug fixes and compatibility changes from refactoring. Preserve
range inclusivity, month-end clamping, units, environment assumptions, and mutation
semantics. Check external API commitments before deleting public symbols. Tests
created solely to justify an unused abstraction do not establish its value.

For example, month addition can clamp at each step: May 31 plus two months yields
July 31, while two single-month additions yield July 30 in the illustrated contract
(app. B, pp. 370–371). A familiar algebraic identity is not a domain requirement.

## Checks that transfer to other refactors

- Establish the observable behavior before changing representation or ownership.
- Exercise the real caller boundary, including defaults and failure paths.
- Distinguish deliberate contract changes from accidental ones.
- Delete temporary structures only after verifying all consumers have moved.
- Keep a structural experiment only when the resulting code is easier to follow.
