## TL;DR

Explain models, contracts, and reasoning that code does not make obvious. Use diagrams and worked examples when they improve understanding.

## How it works

Write for readers who know the language but are new to the subsystem.

- Explain purpose and the overall model before local details.
- State relevant contracts: inputs, outputs, units, boundaries, ownership, failures.
  Put caller contracts in API documentation and mechanisms beside implementation.
- Explain constraints and what breaks if they change. Distinguish requirements
  from guarantees the code actually enforces.
- Use the implementation's names, units, and indexing conventions.
- Keep explanations beside their owner; link longer background or proofs.
- Prefer clarity over comment-length limits. Skip obvious narration, decorative
  diagrams, and examples that reveal nothing. No diagram quota per function.

## Choose the representation

| Explain | Useful form |
| --- | --- |
| Memory regions, packets, register fields | ASCII layout: addresses/offsets, sizes, units, boundaries, ownership |
| Calls, events, data movement | Flow/sequence: actors, operations, completion |
| Trees, links, ownership changes | Before/after diagram |
| Algorithms | Concrete input → important intermediate states → result |
| Correctness and termination | Preconditions, invariant, progress, stopping condition |
| States and exceptional behavior | State/event/condition/action/next-state table |
| Arithmetic, alignment, bit operations | Worked calculation with assumptions |
| Concurrency | Required ordering and a concrete failure scenario |

## Trace an algorithm

Use a small input that exposes the important decisions: duplicates, wraparound,
alignment, overlapping ranges, or another meaningful boundary.

1. State the goal and assumptions.
2. Trace important state changes with consistent names; omit mechanical steps.
3. Show the result and why it follows; include an invariant and progress when useful.
4. Add a boundary or counterexample when it prevents a likely misunderstanding.

## Verify the explanation

Check values, arrows, ranges, ownership, and ordering against implementation.
Mark illustrative values and schematic omissions. Examples illustrate behavior;
they do not prove correctness or complexity. Use existing documentation-test
facilities for runnable examples. Update explanations when behavior changes.

The examples below illustrate review decisions, not complete implementations.

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

## C24 — Show the layout before constructing it

Before: scattered addresses and writes make readers reconstruct the arrangement.
After: show regions and their roles before the assignments.

```c
/*
 * Planned guest RAM layout, high addresses first.
 * Schematic: smaller regions and gaps are grouped.
 *
 * RAM_SIZE        +-------------------------------+
 *                 | initramfs + alignment padding | loader -> kernel
 * initramfs_start +-------------------------------+
 *                 | kernel image and workspace   | loader / kernel
 * KERNEL_START    +-------------------------------+
 *                 | boot metadata, reserved gaps | loader -> kernel
 * 0               +-------------------------------+
 *
 * Keep the archive outside the kernel's required working region.
 */
```

Use actual ranges and identify each writer/reader. Check alignment and reserved
extents against the implementation; a planned layout does not prove bounds checks
exist. Distinguish metadata describing memory from the memory it describes.

## C25 — Trace the decisions that distinguish an algorithm

Before: "binary search" names the algorithm but leaves its equality behavior unclear.
After: use duplicates to show why equality continues searching left.

```c
/*
 * Find the first index with value >= target.
 * Input must be sorted ascending; return n (array length) if none qualifies.
 * lo/hi bound the unresolved positions [lo, hi); mid = floor((lo + hi) / 2).
 *
 * Example: a = [2, 4, 4, 7, 9], target = 4
 *
 *   lo  hi  mid  a[mid]  update
 *    0   5    2       4  hi = 2
 *    0   2    1       4  hi = 1
 *    0   1    0       2  lo = 1
 *
 * Result: lo == hi == 1, the first matching position.
 *
 * Invariant: values before lo are < target; values at or after
 * hi are >= target. Each step shrinks the unresolved range.
 * On equality, moving hi left preserves earlier equal values.
 *
 * Boundaries: an empty array returns 0; target 10 above returns 5.
 */
```

The midpoint formula describes the trace; use the implementation's overflow-safe
arithmetic. Preserve its actual interval convention and comparison. A first-match
trace would misdescribe a search allowed to return any equal element.

## C26 — Derive the calculation and explain its direction

Before: a mask clears bits without explaining the placement constraint.
After: calculate a representative case and show why rounding upward fails.

```c
/*
 * Round the archive's start downward to a 4 KiB boundary.
 * Clearing the lowest 12 bits performs this alignment.
 *
 * Illustrative values:
 *   RAM end - archive size:
 *   0x20000000 - 0x12345 = 0x1ffedcbb
 *
 *   align downward -> 0x1ffed000
 *
 * Rounding upward would make the archive end at 0x20000345,
 * beyond RAM. The mask requires a power-of-two page size.
 */
```

Check size <= available RAM before subtraction and verify the final extent against
other reserved regions. The calculation explains alignment; it does not establish
that the surrounding loader validates input size or prevents overlap.
