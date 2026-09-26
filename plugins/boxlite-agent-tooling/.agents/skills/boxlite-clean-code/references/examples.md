## TL;DR

Choose the example topic matching the current code, then compare the transformation, preserved behavior, and limits.

## How it works

Choose the topic matching the current code; do not load every addon by default.
Examples are compact adaptations. Fragments assume surrounding domain types and
are illustrative unless stated otherwise. Preserve the receiving project's
contracts instead of copying a historical mechanism mechanically.

| Concern | Examples |
| --- | --- |
| Intent, units, vocabulary, and context | [Names](names.md) |
| Abstraction, arguments, sequencing, and side effects | [Functions](functions.md) |
| Rationale, misleading prose, warnings, and dead comments | [Comments](comments.md) |
| Proximity, spacing, scopes, and team formatting | [Layout](layout-examples.md) |
| Representation, data records, polymorphism, and service traversal | [Objects and data](objects-data-examples.md) |
| Exceptions, recovery, cleanup, nulls, and failure context | [Errors](error-examples.md) |
| Capability boundaries, learning tests, and provider adapters | [Dependency boundaries](boundary-examples.md) |
| Controlled time, test vocabulary, scenarios, and assertions | [Tests](test-examples.md) |
| Cohesion, responsibility, prime reports, SQL, and portfolio quotes | [Classes](class-examples.md) |
| Assembly, injection, factories, persistence, and policy interception | [Systems](system-examples.md) |
| Shared rules, image ownership, policy composition, and excess abstractions | [Simple design](simple-design-examples.md) |
| Args parser evolution, incremental migration, and structured diagnostics | [Parser refactoring](args-refinement.md) |
| JUnit comparison formatting, prefix/suffix boundaries, and extraction reversals | [Comparison refactoring](comparison-refactoring.md) |
| SerialDate types, calendar arithmetic, ownership, and compatibility | [Date refactoring](date-refactoring.md) |
| Calendar origins, month clamping, interval matrices, and serialization | [Date boundaries](date-boundaries.md) |
| Stack capabilities, feature envy, pagination, sequencing, and defaults | [Ownership and contracts](ownership-and-contract-examples.md) |
| Expressions, fixtures, payment flow, bowling, rendering, and lazy effects | [Expressive code](expressive-code-examples.md) |
| Build entry points, imports, constants, enum policy, and diagnostic tests | [Tooling and types](tooling-and-type-examples.md) |
| Reasons for concurrency, shared state, isolation, and ownership | [Concurrency purpose](concurrency-purpose.md) |
| Read-modify-write races, collection contracts, and check-then-act | [Atomic operations](concurrency-atomic-operations.md) |
| Server throughput, bounded workers, task ownership, and shutdown | [Server lifecycle](concurrency-server-lifecycle.md) |
| Producers/consumers, readers/writers, philosophers, and deadlocks | [Execution models](concurrency-execution-models.md) |
| Reproducers, controlled interleavings, stress, and instrumentation | [Concurrency testing](concurrency-testing.md) |

For each example, compare the original difficulty, the changed structure, and the
behavior that must survive. A shorter method is not automatically an improvement.
Repeated principles use different domain cases; read the refactoring addons when
the sequence of intermediate changes matters. The checks are verification ideas,
not claims that every illustrative fragment is a runnable standalone program.
