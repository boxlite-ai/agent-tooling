## TL;DR

Names should reveal a value's role, units, and domain without forcing readers to decode hidden context.

## How it works

These compact adaptations preserve the examples' decisions, not full application
implementations. Java-like fragments assume the surrounding domain types exist.

## N1 — Elapsed time includes its unit

Before: `int d;` needs a comment and oral explanation.
After: `int elapsedDays;` or `int daysSinceCreation;` states the actual quantity.
Choose the name from the real origin and unit; renaming milliseconds to days is
not a conversion. Check callers and serialization names before changing an API.

## N2 — Minesweeper cells expose their meaning

```java
// Before: the representation is visible but the purpose is hidden.
for (int[] x : theList)
    if (x[0] == 4) result.add(x);

// First improvement: preserve the array representation.
for (int[] cell : gameBoard)
    if (cell[STATUS_INDEX] == FLAGGED) flaggedCells.add(cell);

// When Cell already owns the representation:
for (Cell cell : gameBoard)
    if (cell.isFlagged()) flaggedCells.add(cell);
```

The algorithm did not get shorter; the domain became visible. Introducing `Cell`
is a separate representation change. Preserve cell identity, order, and selection.

## N3 — Source and destination have different roles

Before: `copyChars(a1, a2)` forces callers to inspect the loop.
After: `copyChars(source, destination)` exposes the direction of copying.
Check overlapping buffers, lengths, mutation, and argument order; a better name
must not silently reverse the operation or introduce a new allocation.

## N4 — Noise words do not define a contract

Before: `getActiveAccount()`, `getActiveAccounts()`, and `getActiveAccountInfo()`
compete without explaining which result is appropriate.
After, if these are the actual distinctions: `findActiveAccount(id)`,
`listActiveAccounts()`, and `summarizeActiveAccount(id)`.
Likewise, `ProductInfo` and `ProductData` need a real distinction or one concept.
Do not invent distinctions simply to justify keeping redundant APIs.

## N5 — Pronounceable names support discussion

Before: a record exposes `genymdhms` and `modymdhms`.
After: `createdAt` and `modifiedAt` express the two timestamps.
Preserve their precision and timezone; readable names cannot resolve an ambiguous
time contract. Use the domain's established terminology when it differs.

## N6 — Searchable constants identify a rule

```java
// Before
total += (taskDays[j] * 4) / 5;
// After, when these constants describe the actual planning policy
realTaskDays = taskDays[j] * REAL_DAYS_PER_IDEAL_DAY;
totalWeeks += realTaskDays / WORK_DAYS_PER_WEEK;
```

Search now finds the planning rule rather than every occurrence of `5`.
Preserve integer truncation, grouping, units, and overflow behavior. A short loop
index is still reasonable inside a tiny scope.

## N7 — Type and scope encodings can become stale

Before: `PhoneNumber phoneString` lies after the type changes;
`m_dsc` requires decoding a field prefix and an abbreviation.
After: `PhoneNumber phoneNumber` and `description` name the concepts.
Use repository conventions; do not rename unrelated fields merely to remove a
prefix. The same caution applies to mandatory `I` prefixes on interface names.

## N8 — Visually ambiguous names cost more than they save

Before: `l`, `O`, and `O1` are hard to distinguish from digits.
After: `lineCount`, `origin`, and `nextOrigin`, when those are their real meanings.
Changing editor fonts only transfers the decoding burden to the next reader.
Long, nearly identical controller names likewise need their distinguishing purpose
near the front, not hidden in a suffix.

## N9 — Creation methods expose the interpretation

Before: `new Complex(23.0)` leaves the coordinate convention implicit.
After: `Complex.fromReal(23.0)` distinguishes it from polar or Cartesian creation.
Keep existing constructor compatibility when required; a named factory is useful
when it explains an actual ambiguity, not as a mandatory wrapper around `new`.

## N10 — One vocabulary, distinct operations

| Before | After and reason |
| --- | --- |
| Equivalent APIs alternate between `fetch`, `retrieve`, and `get` | Use the established term consistently so callers need not remember authorship. |
| `add(a, b)` combines values, while another `add(x)` inserts into a collection | Use `combine` and `insert` when those are the actual distinct meanings; respect standard library conventions. |
| `HolyHandGrenade()` or `whack()` hides an operation behind a joke | Prefer `deleteItems()` or the domain's explicit termination operation. |
| A queue or visitor receives an invented business-sounding name | Use established technical names such as `JobQueue` when they identify the abstraction accurately. |

Consistency means matching semantics, not forcing every operation to share a verb.

## N11 — Context belongs to a concept

Before: `state` travels separately from street, city, and postal code.
After: `address.state` makes the context available at the point of use.
Avoid replacing this with application prefixes on every class: `PostalAddress`
communicates a distinction that `GSDAccountAddress` obscures.
Do not combine independently owned records solely because their fields look alike.

## N12 — Guess statistics own their grammar

```text
Before: a printing method maintains number, verb, and pluralSuffix separately.
After: GuessStatisticsMessage.make(candidate, count) owns their shared grammar.
Cases: count 0 → "no" + plural; 1 → "1" + singular; many → count + plural.
```

The extraction names a cohesive concept and isolates formatting from output.
Adaptation: keep grammar parts local to each call or use a fresh value object;
moving them into shared mutable fields would add reentrancy hazards.
