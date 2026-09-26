## TL;DR

Date refactoring needs explicit boundary semantics, implementation ownership, and compatibility decisions before changes to names, types, or algorithms.

## How it works

The transformations below adapt a legacy date-library review. Structural changes preserve the established contract; suspected bugs and requested API changes are called out separately. Detailed matrices are in [date boundaries](date-boundaries.md).

### D01 — Separate desired behavior from characterized behavior

A weekday parser accepts full names with exact case. A reviewer expects case-insensitivity and additional abbreviations. These are three separate decisions:

```text
Characterized: "Tuesday" succeeds.
Proposed:      "tuesday" should also succeed.
Unresolved:    should "tues" be an accepted abbreviation?
```

Write the current contract first. Add an approved behavior change as a defect or feature test; track unresolved input forms as a requirement question. Changing an error string into an exception is also a contract change.

**Check:** exact case, alternate case, documented abbreviations, unknown strings, whitespace, and error form.

**Limit:** a reviewer’s intuition is evidence of a usability concern, not authority to expand a published parser's accepted language.

### D02 — Diagnose a family of weekday boundary failures

For “following weekday,” clarify whether “following” is strictly later. If it is, asking for Saturday from Saturday must advance a week, not return the input. For “nearest weekday,” examine all seven target offsets:

```text
forward distance: 0 1 2 3 4 5 6
nearest offset:   0 1 2 3 -3 -2 -1
```

If only future targets fail, look for an adjustment that is always negative or a branch whose condition cannot occur. Explain the range of each intermediate before changing it.

**Check:** same day, the three nearest future days, the three nearest past days, and transitions across month/year boundaries. Demonstrate the original failure before the fix.

**Limit:** these offsets depend on the chosen contract and weekday numbering. A fix is not merely refactoring; preserve other established date behavior while correcting it.

### D03 — Remove stale information while preserving useful obligations

Before, a source header contains license text, a copied change log, and outdated comments about integer error codes. After:

```text
retain: license and required attribution
move responsibility to version control: routine change history
update/remove: prose describing an error value no longer returned
retain: non-obvious calendar compatibility constraints
```

The useful distinction is what information the source must carry now. A comment cannot remain accurate merely because the code around it still compiles.

**Check:** compare public documentation with actual accepted values, return values, and exceptions. Verify that removal does not lose a required notice or explain-away a compatibility quirk.

**Limit:** structured documentation and embedded markup are not inherently clutter. Keep information needed by generated API docs when it is not otherwise expressed.

### D04 — Name the abstraction, with the surrounding vocabulary in view

A date abstraction is named after its integer storage. That encourages callers to assume every implementation uses the same representation. Move toward a domain name that distinguishes a calendar day from an instant.

```text
representation-flavored name → date-only domain name
ambiguous year getter       → year
comparison returning days   → days_since
```

Check existing platform names before choosing the replacement; the most obvious short name may already mean something else.

**Check:** callers understand timezone/time-of-day exclusions and the units/sign of comparisons. Rename internal references together; handle public aliases or a versioned migration explicitly.

**Limit:** a public rename is not behavior-preserving for source clients. Avoid a wide rename when a small local clarification addresses the task.

### D05 — Replace interchangeable integer codes with domain values

Raw `2` can mean a month, weekday, week-within-month, or interval policy. Give these separate types and convert at the external boundary:

```text
wire integer → validate/convert → Month
range policy → OPEN / INCLUDE_LEFT / INCLUDE_RIGHT / CLOSED
```

Internal operations that receive valid `Month` values no longer need to repeat the same integer-range check. Parsing and serialization remain responsible for invalid external codes.

**Check:** round-trip every supported external value, reject invalid values, and verify mappings against existing storage/protocol contracts.

**Limit:** enum ordering is not automatically the external representation. Type safety does not remove nullability, malformed input, versioning, or compatibility concerns.

### D06 — Treat removed safeguards as decisions, not cleanup

Two tempting removals are an explicit serialization identifier and local immutability declarations. Both may look like clutter while enforcing a contract:

```text
Before deletion:
What compatibility or reassignment condition does this mechanism constrain?
What replaces that protection?
Which existing persisted values or callers exercise it?
```

Serialization can fail loudly after a harmless edit or silently accept incompatible state. The trade-off needs an explicit persistence policy. Tests also do not prove that an immutability annotation or keyword has no value.

**Check:** supported historical serialized fixtures and required assignment invariants; keep compile-time checks active.

**Limit:** do not preserve every annotation unquestioningly, but do not remove one merely because a small current test suite passes.

### D07 — Trace callers before relocating bounds and construction

An abstract date holds the supported year limits, while its creation helper always constructs one concrete implementation. A calendar rule needs both creation and range checks.

```text
Before: rule → abstract date constants → hidden concrete implementation
After:  rule → selected date factory → creation + implementation bounds
```

This places related implementation knowledge together. Trace the whole creation path first; moving constants alone may leave consumers depending on a hidden choice elsewhere.

**Check:** selected bounds and created values belong to the same implementation; unsupported years fail at the documented boundary.

**Limit:** a mutable global factory is not required. An explicitly supplied factory may be clearer, and a single fixed implementation may need no abstract factory at all.

### D08 — Put data near its actual consumer

A cumulative-days table looks generally reusable, but only one concrete date representation uses it. Keeping it on the abstract type would require a public accessor nobody otherwise needs.

```text
Find consumers → only concrete date implementation
Move table privately there → preserve calculations
Delete genuinely unused sibling tables → verify exports/consumers
```

The table can move again if another real consumer appears. The same investigation applies to unused description fields and trivial constructors.

**Check:** output remains identical across representative calendar boundaries; verify published fields, reflection, serialization, and external callers before deletion.

**Limit:** “no local reference” is not proof of dead public API. Do not manufacture an abstraction solely to preserve hypothetical future reuse.

### D09 — Let the domain value own its meaning

A large date class translates month codes, formats month names, and determines quarters. These operations primarily concern the month concept:

```text
date.month_code_to_quarter(code) → Month.from_code(code).quarter()
date.month_code_to_text(code, short=True) → month.short_name()
```

Move parsing, formatting, and quarter calculation together where that cohesion is useful. A general weekday or month type need not be nested inside one particular date representation.

**Check:** names, abbreviations, locale assumptions, invalid-code behavior, and quarter boundaries survive the move.

**Limit:** moving localized display into an enum is not mandatory. A separate formatter can own presentation policy that changes independently of the domain value.

### D10 — Reveal arithmetic units and returned-new-value semantics

Break month arithmetic into meaningful intermediates before changing it:

```text
current month ordinal → target month ordinal → target year/month
original day + target month limit → resulting day
```

When an instance operation returns a new date, make that visible at the call site:

```python
later = original.plus_days(10)
```

Use the existing clamping rule consistently for both month and year changes; extract that shared rule only after verifying it is genuinely the same policy.

A method such as `date.end_of_month(other_date)` also deserves scrutiny: if it uses only the argument, either make it a function or let `other_date.end_of_month()` use its own state. Remove the misleading receiver without changing the selected date.

**Check:** the original remains unchanged, units are days/months/years as named, and month-end/leap-year behavior is preserved. Exercise the boundary addon’s repeated-addition cases.

**Limit:** renaming alone does not enforce immutability. Static-to-instance API changes and arithmetic-rule changes need deliberate caller migration.

### D11 — Delete an elegant abstraction with no consumer

A helper describing “first/second/last week” is moved into an enum and renamed as its string conversion. Removing the custom conversion lets the enum's default names satisfy edited tests. Then a usage search reveals that these tests are its only consumers.

```text
expensive polish → inspect consumers → no real requirement → remove helper/test
next similar helper → inspect consumers first
```

The reversal matters more than the clever migration. A test added to preserve an unused helper does not establish a product requirement.

**Check:** no published or external consumer needs the old text; other tests exercise actual behavior rather than this unused path.

**Limit:** do not delete a real contract merely because its only in-repository caller is a test. Public APIs and backward compatibility require a broader check.

### D12 — Find semantic dependencies that the compiler cannot see

A weekday formula uses the ordinal day number. It appears generic, but assumes which weekday corresponds to ordinal zero.

```text
Before: weekday = calculation(ordinal) with an implicit epoch
After:  weekday = calculation(ordinal, implementation's epoch weekday)
```

Expose that origin through the owning abstraction before moving the calculation into shared code. Rename the result and origin precisely enough that their units and numbering agree.

**Check:** known calendar dates still map correctly; if multiple origins are supported, each implementation exercises the generic calculation.

**Limit:** do not add unused epoch configurability. The principle is that code moved across a boundary must carry every dependency, including the ones absent from its import list.

### D13 — Put interval variation in its owner

A date method combines endpoint normalization with a switch over open/closed interval kinds. Separate those decisions:

```text
date operation: normalize endpoints according to existing contract
interval policy: choose strict/inclusive comparisons
```

A typed policy can own membership behavior, or a small exhaustive match can make the same closed set explicit. Shared generic date utilities should likewise live with their actual users rather than an arbitrary implementation.

**Check:** lower and upper endpoints, interior/exterior values, and reversed/coincident endpoint semantics. Use the detailed interval matrix in the boundary addon.

**Limit:** replacing a switch with methods is not itself a correctness improvement. Keep the old inclusivity and endpoint-normalization contract unless deliberately changing it.

### D14 — Read coverage as evidence about behavior

Suppose refactoring deletes many executable statements. The remaining few untested lines now form a larger percentage:

```text
before: many covered statements + a few uncovered ones
after:  fewer covered statements + the same uncovered behaviors
```

A percentage drop does not necessarily mean test protection declined. Inspect which scenarios are still covered and what the untested lines can do.

**Check:** retain meaningful regression and boundary tests; explain whether uncovered behavior is trivial, unreachable, or a real risk.

**Limit:** the converse also holds: deleting tests or moving code outside the measured package can improve a number while reducing confidence. Coverage is a navigation aid, not the completion criterion.

### D15 — Explain interacting leap-year rules

An opaque divisibility expression is easier to review when its intermediate meanings are visible:

```python
multiple_of_four = year % 4 == 0
century = year % 100 == 0
four_centuries = year % 400 == 0
return multiple_of_four and (not century or four_centuries)
```

The names reveal that the century exclusion itself has an exception. This is a local explanation of an established rule, not a reason to introduce three public helper methods.

**Check:** a typical common year, typical leap year, excluded century, and included four-century year, using the library's supported calendar and year range.

**Limit:** readable Boolean names do not establish which calendar policy the application intends. Preserve that contract and use a platform date library when it already supplies the needed behavior.
