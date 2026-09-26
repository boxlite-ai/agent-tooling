# Coding decisions

Use the relevant section to connect a concrete concern to a change and its checks.
Page numbers refer to the [first edition](book-map.md). Language and runtime
adaptations below are this skill's guidance, not claims made by the book.

## Names, functions, comments, and layout

| Evidence | Decision and limiting case | Source |
| --- | --- | --- |
| A name hides purpose, units, or effects | Name the actual concept and scope. Check keyword callers and compatibility before renaming. | Ch. 2, pp. 18–30; ch. 17, pp. 309–313 |
| Orchestration mixes policy with parsing or I/O | Extract a coherent lower-level operation. A wrapper that merely restates a condition adds no abstraction. | Ch. 3, pp. 35–37 |
| Parameters expose unrelated workflows or required call order | Prefer distinct operations or one owner of the sequence. Natural value groups need no artificial object; fewer parameters do not justify hidden state. | Ch. 3, pp. 40–46; ch. 15, pp. 258–265 |
| Comments repeat mechanics or contradict behavior | Repair intent and structure; retain legal notices, mathematical reasoning, protocol constraints, and accurate public contracts. | Ch. 4, pp. 55–74 |
| Related behavior is hard to find | Keep collaborators near their use within repository conventions. Avoid unrelated formatting and file-size quotas. | Ch. 5, pp. 76–90 |

For example, a password predicate that also starts a session hides a state change.
Expose the real operation or separate responsibilities only if the required
ordering and atomicity survive (ch. 3, pp. 44–46).

## Cohesion, representation, and dependency boundaries

- Choose representation by the change that is actually needed. Data plus
  procedures makes new operations easier; objects can localize new variants.
  Neither wins universally (ch. 6, pp. 93–97). **Adaptation:** closed variants with
  exhaustive matching and immutable records can be appropriate language idioms.
- Group behavior that changes for the same reason; separate independent
  responsibilities. Shared fields alone do not imply shared responsibility.
  Report formatting may belong outside an employee despite data access
  (ch. 10, pp. 138–150; ch. 17, pp. 293–294).
- A caller repeatedly reconstructing a collaborator's internal structure may need
  an operation owned by that collaborator. Count leaked knowledge, not dots;
  intentional data traversal and fluent APIs differ (ch. 6, pp. 98–101).
- Share one domain rule when it has one owner. Tolerate similar local syntax when
  policies evolve independently. Prefer temporary duplication over a premature
  shared interface (ch. 12, pp. 173–176; ch. 14, pp. 212–250).
- Introduce an adapter when it owns useful translation, capability limits, error
  policy, or observed provider volatility. Do not mirror an entire vendor API.
  Test caller decisions with fakes and the real adapter's assumptions separately
  (ch. 8, pp. 114–120). **Adaptation:** a fake passing is not integration evidence.
- Separate major dependency assembly from runtime use; use a factory when creation
  timing matters. Ordinary local values need no container, interface, or framework
  (ch. 11, pp. 154–167). Keep transaction and authorization behavior discoverable.

## Errors, absence, and resource ownership

Translate failures according to what callers can do: retry, correct input, or
propagate. Preserve the cause and useful operation context without secrets; do not
merge categories requiring different recovery (ch. 7, pp. 105–109).

**Adaptation:** use idiomatic exceptions, Go errors, Rust results, or equivalent
contracts. Absence, empty success, invalid input, and failure are different states.
Do not turn a failed query into an empty list merely to remove error handling.
Explicit optional values can express legitimate absence (ch. 7, pp. 109–112).

Identify the owner of each resource and the state after partial failure. Catching
an error does not imply rollback. **Adaptation:** include cancellation, cleanup,
deadlines, bounded retries, and idempotency for repeated effects; preserve security
validation at external boundaries (ch. 7, pp. 105–106; app. A, pp. 317–321).

## Tests and the order of design priorities

Keep scenario setup, the operation, and expected outcomes readable. Several
assertions may describe one contract; do not build fixture machinery merely to
enforce one assertion per test (ch. 9, pp. 124–133).

Use independent fixtures and explicit time, randomness, and environment assumptions.
Check boundaries and patterns of failure; coverage locates unexamined code but
does not establish correctness (ch. 9, pp. 132–133; ch. 17, pp. 313–314).
**Adaptation:** retained tests should cross the project's real behavior boundary;
dependency experiments and synthetic demonstrations belong in scratch space.

Preserve the priority order: verified behavior, removal of duplicated rules,
expressed intent, then fewer components. Tiny-class proliferation can defeat the
earlier goals (ch. 12, pp. 172–176). Measure before optimizing.

## Concurrency and lifecycle

Identify the invariant spanning operations: individually safe methods do not make
check-then-act safe. Give one operation ownership of reservation or consumption;
returning a reserved item and mutating its collection may need to remain atomic
(ch. 13, pp. 180–186; app. A, pp. 329–333).

Reduce shared mutable state and separate domain logic from scheduling. Examine
lock order, starvation, cancellation, and shutdown—not only race freedom
(ch. 13, pp. 183–190; app. A, pp. 335–342).

**Adaptation:** bound queues, workers, waiting, and cleanup; verify the target
runtime's primitive contracts. Control a known conflicting boundary in regression
tests, propagate worker failures, and assert completion as well as final values.
Use bounded stress as additional evidence, never proof of race freedom. Avoid
sleep-based causality and do not copy historical universal performance claims.
