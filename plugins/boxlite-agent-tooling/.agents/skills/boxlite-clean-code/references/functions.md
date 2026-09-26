## TL;DR

Functions become easier to reason about when their abstraction, arguments, effects, and sequencing express one coherent operation.

## How it works

Fragments are compact adaptations, not complete library implementations. Preserve
the stated contracts when translating them into the receiving language.

## F1 — FitNesse rendering reads at one level

```java
// Before: page traversal, include strings, buffering, and rendering interleave.
// After: the orchestration exposes the page's lifecycle.
if (page.isTest()) {
    includeSetups(page, content);
    content.append(page.originalContent());
    includeTeardowns(page, content);
    page.replaceContent(content.toString());
}
return page.renderHtml();
```

Keep suite setup before regular setup, teardown in the required reverse order,
and non-test rendering unchanged. Preserve newline placement and page mutation.
A shared include operation can own traversal, path rendering, and directive syntax.

## F2 — A cohesive facade owns temporary state

Before: callers create a buffer, find inherited pages, render paths, and remember
the setup/content/teardown order.
After: `SetupTeardownIncluder.render(page, options)` owns that sequence and keeps
its helpers private. A fresh operation object can own the buffer for one render.
This reduces caller knowledge; using shared fields just to eliminate arguments
would instead lengthen state lifetime and weaken concurrency safety.

## F3 — Extraction must add a concept

Before: `if (isTestPage(page)) includeFixtures(page);`.
Unhelpful extraction: `includeFixturesIfTestPage(page)` merely repeats the branch.
Useful extraction: `includeFixtureHierarchy(page)` can own suite and page traversal.
Evaluate the resulting explanation and navigation cost, not the function count.

## F4 — Repeated payroll dispatch reveals an extension boundary

```text
Before: calculatePay, isPayday, and deliverPay each switch on employee.type.
After: one construction boundary chooses an Employee implementation;
       each operation delegates to that employee's behavior.
```

This localizes a genuinely recurring type distinction. A small exhaustive match
over a closed data model may be clearer; do not manufacture a hierarchy for one
branch. Check every employee variant and preserve invalid-type handling.

## F5 — Queries, transformations, and events read differently

| Intent | Concrete operation | Preserve |
| --- | --- | --- |
| Ask about an input | `fileExists(path)` | Absence versus access failure |
| Transform or acquire | `openFile(path)` returns a stream | Ownership, cleanup, and failures |
| Announce an event | `recordFailedAttempts(count)` | Mutation and event-delivery semantics |

A function that fills an output argument should make that mutation obvious.
For example, `appendFooter(report)` can become `report.appendFooter()` when the
report owns the operation, or return a new report when immutability is intended.
Do not switch between those contracts as a cosmetic refactor.

## F6 — Workflow flags obscure caller intention

Before: `render(true)` versus `render(false)`.
After, when callers are in scope: `renderSuite()` versus `renderSingleTest()`.
Keep the existing flag as a compatibility entry point when callers cannot move.
An ordinary predicate value is not automatically two unrelated workflows.

## F7 — Natural argument groups deserve names

```text
makeCircle(x, y, radius) → makeCircle(Point(x, y), radius)
new Point(x, y)         → keep the natural ordered pair
format(pattern, args)   → treat the argument sequence as one coherent collection
```

Group related meaning, not an arbitrary bundle created to hit an argument quota.
For repeated stream writes, `FieldWriter(stream).write(name)` may own a stable
resource; ensure that ownership and lifetime actually belong to the writer.

## F8 — Argument ordering is part of readability

Before: `assertEquals(message, expected, actual)` is easy to misread.
After, in a supporting assertion API: `assertThat(actual).isEqualTo(expected)`
with a separately named diagnostic message.
Likewise, a floating-point tolerance deserves an explicit name and unit.
Preserve comparison semantics; a nicer call form does not justify changing equality.

## F9 — Password checking must disclose session mutation

```java
// Before: a predicate unexpectedly resets session state on success.
boolean checkPassword(User user, String password) {
    if (!credentialsMatch(user, password)) return false;
    session.initialize();
    return true;
}
// Honest combined operation when its atomic contract must remain intact:
boolean authenticateAndInitializeSession(User user, String password);
```

Separate verification from initialization only when callers need separate actions
and ordering remains safe. Test rejected credentials, existing session contents,
and repeated successful calls; a rename alone does not fix destructive semantics.

## F10 — Command/query separation has an atomicity limit

Before: `if (set("username", value))` obscures whether it asks or changes state.
For an ordinary single-threaded contract, explicit existence and mutation calls
can clarify the flow. For concurrent shared state, `setIfPresent(name, value)`
may need to stay one atomic operation with an explicit result.
Do not replace it with a racy `contains(name)` followed by `set(name, value)`.

## F11 — Page deletion separates policy from mechanics

```text
Before: nested success-code checks delete page → registry reference → config key.
After: one operation performs those steps in order; its boundary handles failure.
```

Keep failure propagation and the state after each partial deletion explicit.
Logging an exception does not undo earlier effects or establish success.
Use idiomatic exceptions or result/error returns; retain distinctions that callers
need for retries or correction. Cleanup and rollback are separate design decisions.

## F12 — A global error enum can couple unrelated domains

Before: unrelated modules all extend one `Error` enumeration and reuse inaccurate
codes to avoid changing its consumers.
After: each boundary owns meaningful error categories and translates them for callers.
The improvement is dependency ownership, not mandatory exceptions; typed result
unions can serve the same purpose when they match the language and public contract.

## F13 — Early exits can clarify a small operation

Before: a prime generator nests its entire algorithm under `if (limit >= 2)`.
After: return the contract's empty result for `limit < 2`, then run the algorithm.
Keep cleanup and error paths correct. One exit is not a readability goal by itself,
and an empty result must not replace an error when the original API rejected input.
