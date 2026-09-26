## TL;DR

Useful comments explain intent and constraints that code cannot express, while stale narration obscures the current contract.

## How it works

These adaptations distinguish useful explanation from stale narration. Fragments
illustrate review decisions; they are not complete implementations.

## C1 — Benefits eligibility becomes a named predicate

Before: a comment explains an employee flag check combined with an age threshold.
After: `employee.isEligibleForFullBenefits()` names that domain decision.
Preserve the exact flag and threshold semantics, especially the equality boundary.
Do not copy an illustrative age or benefits rule into a real policy.

## C2 — A date-pattern example stays beside its pattern

Before: unrelated fields separate a date regular expression from its sample text.
After: keep the sample adjacent or give the parser an explicit format-oriented name.
For example, a GMT HTTP-date sample helps identify the expected shape; it does not
prove that a permissive regular expression validates calendar dates correctly.

## C3 — Unusual sorting policy needs an explanation

Before: a path comparator returns a positive result for every foreign object type.
After: explain the intended cross-type ordering and verify comparator laws.
A comment can reveal intent without making the policy correct: antisymmetry and
transitivity still need to hold, or the API should reject incomparable values.

## C4 — A race-test comment explains intent, not success

Before: a test starts thousands of widget-builder threads to increase contention.
After: describe which shared invariant is being challenged and join all workers
before checking their failures. Adaptation: use a bounded, controlled interleaving
for a known race; a stress comment and a green run do not prove race freedom.

## C5 — Comparison comments must match the library contract

Before: `assertTrue(a.compareTo(b) == -1); // a < b`.
After: `assertTrue(a.compareTo(b) < 0)` when only the result's sign is specified.
Prefer an expressive assertion to a comment translating a magic return value.
Retain an exact-value check only if that value itself belongs to the contract.

## C6 — A formatter warning preserves isolation

Before: repeated `SimpleDateFormat` allocation looks like an optimization target.
After: retain the explanation that each call needs an independent mutable formatter,
or replace it with a verified thread-safe abstraction as a separate change.
Do not move an unsafe formatter into shared static state merely to save allocations.

## C7 — Expensive tests need explicit execution policy

Before: an underscore hides a huge-file test from automatic discovery.
After: use a named slow/integration test category with the resource requirement
and an explicit way to run it. A skip reason explains cost; it does not establish
that the omitted behavior has been tested or justify permanently disabling it.

## C8 — A transitional stub needs an actionable condition

Before: a version-producing method returns null with a vague reminder to revisit it.
After: identify the compatibility condition that permits the stub and the concrete
change that will remove it. Preserve or fix its current contract separately;
a future-work comment cannot make a missing implementation correct.

## C9 — Trimming can be part of a parser's semantics

Before: `matchedItem.trim()` looks like cosmetic whitespace cleanup.
After: explain that retained leading spaces could create another nested list item.
Test indented input and intended content. Do not delete the explanation until a
name or parser abstraction communicates that non-obvious consequence equally well.

## C10 — Missing properties are not every I/O failure

```text
Before: catch IOException and claim defaults were loaded.
After: initialize documented defaults; ignore only the permitted missing-file case;
       propagate read/permission/format failures with context; close the stream.
```

Make the source of defaults observable. This is a proposed behavior correction
when the old implementation swallowed failures, not merely a comment cleanup.

## C11 — A wait comment cannot promise a wakeup protocol

Before: a method that waits once claims to return immediately when a flag changes.
After: describe what the actual wait/check code guarantees, or deliberately fix
the notification and deadline loop with a regression test.
Verify timeout, notification, interruption, and spurious-wakeup behavior; changing
the prose alone does not repair a missing synchronization protocol.

## C12 — Mechanical documentation creates false confidence

Before: a getter repeats its name in three documentation lines; copied field
comments label both a version and an unrelated information field as a version.
After: delete redundant private narration and correct real public contracts.
Likewise, `responderInstance()` can become `responderBeingTested()` when that is
the fact its comment repeats. Retain units, ranges, ownership, and legal notices.
Do not impose a blanket ban on API documentation or a quota for every private member.

## C13 — Error-response extraction still needs failure semantics

Before: sending code nests another try/catch to report an error and close a response.
After: a named `reportFailureAndClose` operation owns that policy.
An empty catch inside the helper still loses evidence. Decide how secondary errors
are reported and ensure resources close even if reporting fails; distinguish those
behavior changes from merely moving the existing block.

## C14 — Name both sides of a dependency question

```java
// Before: a comment decodes a long containment expression.
boolean depends = module.getDependencies().contains(system.getName());
// After: intermediate names expose the relationship being tested.
var dependencies = module.getDependencies();
var currentSystem = system.getName();
boolean dependsOnCurrentSystem = dependencies.contains(currentSystem);
```

Keep evaluation order and call counts. Extra variables help only when their names
expose concepts that the original expression made readers reconstruct.

## C15 — Word counting does not need brace labels

Before: a long input loop ends with comments such as `// while` and `// try`.
After: separate reading/counting from reporting, with obvious scopes and cleanup.
Preserve tokenization, newline treatment, encoding, and error output; those are
behavioral choices that a structural refactor must not accidentally replace.

## C16 — History and disabled code belong outside active logic

Before: change journals, personal bylines, and commented-out stream/PNG operations
compete with the implementation that actually runs.
After: remove obsolete alternatives once their intent is understood; use version
history for the old implementation. Keep a current compatibility rationale when
it explains why the active behavior still exists.

## C17 — Documentation must remain readable at its source

Before: escaped markup overwhelms a short test-runner usage example.
After: use the documentation tool's supported code-block format and check both
the source and rendered output. Prefer useful syntax examples to decorative HTML;
do not remove markup that the repository's documentation pipeline requires.

## C18 — Default configuration belongs to its owner

Before: `setPort(port)` claims a default such as 8082 that is selected elsewhere.
After: document assignment at the setter and the default where configuration is
constructed. Check changed defaults there; a distant comment can silently become
wrong while the setter remains completely unchanged.

## C19 — Keep local assumptions, not a pasted manual

Before: a Base64 round-trip test embeds a long description of the encoding standard.
After: state the alphabet, padding, and input assumptions that affect this test.
Keep standards background in maintained documentation when needed; the test should
expose the behavior it verifies, including malformed or boundary input.

## C20 — Allocation arithmetic needs units

Before: a PNG buffer formula combines width, height, channel bytes, filters, and
header allowance while its comment does not identify which term represents which.
After: derive capacity through a layout operation with explicit units and bounds.
Do not guess that renaming constants preserves the formula: verify dimensions,
row overhead, arithmetic overflow, and the encoder's actual space requirements.

## C21 — The prime sieve keeps its mathematical rationale

```java
int upperFactor = (int) Math.sqrt(maximum);
// Every composite up to maximum has a factor no greater than this bound.
crossOutMultiplesThrough(upperFactor);
```

Replace narration such as “increment count” with meaningful names and stages,
but retain the reason for the square-root bound. Check 0, 1, 2, and perfect squares.
Adaptation: keep scratch arrays local to an invocation instead of copying static
mutable fields from an example; repeated and concurrent calls must stay isolated.

## C22 — Position banners can hide a missing boundary

Before: `// Actions //////////////////` divides a large collection of methods.
After: group genuinely related operations through their owning module and names.
A rare section marker may help in an established layout; repeating decorative
banners until readers ignore them adds neither cohesion nor a usable navigation cue.

## C23 — A pattern comment can explain an external format

Before: a time/date regular expression has no explanation of its intended format.
After: show its expected shape, such as hours, minutes, seconds, weekday, month,
day, and year, alongside the pattern or within a dedicated date-format abstraction.
This differs from C2's detached HTTP-date example: the concern here is explaining
syntax that a name alone does not reveal. Check the actual formatter/parser pair;
a sample shape does not establish range validation or a timezone contract.
