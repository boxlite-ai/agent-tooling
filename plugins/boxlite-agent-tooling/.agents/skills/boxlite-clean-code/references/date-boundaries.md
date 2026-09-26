## TL;DR

Date refactoring must preserve calendar arithmetic, representation boundaries, interval semantics, and compatibility.

## How it works

These appendix examples extend the SerialDate refactoring case. The snippets and
matrices are original teaching examples. Suggested API shapes are adaptations,
not book listings. Arithmetic, conversion, interval, serialization, and metadata
observations below were checked against the book's extracted original Java classes;
this does not establish current spreadsheet or library compatibility.

## Month clamping is not associative

```text
2004-05-31 + 2 months                 → 2004-07-31
(2004-05-31 + 1 month) + 1 month      → 2004-07-30
```

The intermediate June date clamps to day 30, which the next addition retains.
**Before → after decision:** replacing a pair of monthly transitions with one
larger jump changes the result; preserve the stepwise operation when that is the
contract. **Check:** ordinary days, month-end clamping, leap February, and both
positive and negative supported offsets. **Limit:** a domain may instead promise
“always the last day” or use an original anchor; make that a deliberate rule,
not an algebraic simplification of a clamping API.

## A domain month and a calendar month use different indices

```text
Wrong boundary: calendar.set_month(domain_month)      # January becomes February
Explicit boundary: calendar.set_month(domain_month - 1)
Reverse boundary: domain_month = calendar.month + 1
```

The book's domain uses January = 1; its Calendar conversion uses January = 0.
**Why:** both integers look valid, so an off-by-one translation can survive type
checking. **Check:** January and December in both directions and round trips with
explicit timezone assumptions. **Limit:** not every date library uses this indexing;
keep the translation at the verified boundary. Naming or wrapping the value helps
only if conversion behavior is also checked.

## Historical spreadsheet compatibility is an explicit exception

Verified behavior of the book's original date implementation:

| Input date | Serial | Construction result |
|---|---:|---|
| 1900-01-01 | 2 | Valid |
| 1900-02-28 | 60 | Valid |
| 1900-02-29 | — | Rejected |
| 1900-03-01 | 61 | Valid |

The book documents a historical spreadsheet convention that inserts a nonexistent
1900 leap day, explaining an early-1900 mismatch. **Before → after decision:**
replacing the date representation with a generic ordinal library must preserve the
intended mapping or expose an explicit conversion; an epoch change is observable.
**Check:** boundary dates, both conversion directions, and the actual consuming
file/application. **Limit:** the table verifies the book's code, not any current
Excel version, alternate date system, or exported file format. Do not convert the
historical comment into an unverified universal compatibility promise.

## Interval endpoints: names must describe normalized bounds

For lower = 10 and upper = 12, the source implementation gives:

| Policy | Day 10 | Day 11 | Day 12 | Coincident bounds at day 10 |
|---|---|---|---|---|
| Open | Excluded | Included | Excluded | Excluded |
| Closed left | Included | Included | Excluded | Excluded |
| Closed right | Excluded | Included | Included | Excluded |
| Closed | Included | Included | Included | Included |

```text
Before: include_first sounds like “include the first supplied argument”
After:  normalize endpoints; apply closed_left to the lower endpoint
        contains(day, 12, 10, closed_left) == contains(day, 10, 12, closed_left)
```

**Why:** sorting endpoints changes what “first” appears to mean. The final named
interval policies clarify the original behavior. **Check:** each endpoint,
interior, exterior, reversed inputs, and equal inputs for every policy.
**Limit:** if callers mean the first supplied argument rather than the lower bound,
normalization is a contract change. Invalid policy values also need an explicit
boundary result; do not silently treat every unknown value as open.

## Serialization equality and locale-dependent fixtures

```text
Weak:  restored = deserialize(serialize(date)); require restored == date
Stronger contract: also check required metadata and representation boundaries
Environment: Saturday in en_US; samedi in fr_FR for the source's formatting
```

The date's equality compares its serial value, so equality alone cannot show that
all required metadata survived. Its original name tests assume English while the
implementation uses default locale symbols. **Before → after decision:** test the
observable fields and set the intended locale explicitly, or assert a documented
locale-dependent contract. **Check:** round trip, required metadata, supported
version compatibility, and controlled locale/timezone.
**Limit:** bytes need not be identical when semantic compatibility is sufficient;
English fixtures are valid when English is an explicit input, not an accidental
machine setting. The source initializes format symbols statically, so changing a
process-wide locale later is not a reliable way to isolate tests.

## Missing annual date and invalid rule configuration differ

The original relative-day rule returns no date both when its subrule has no date
and when its integer selection code matches no supported operation.

```text
Before: valid rule with absent base → null; invalid selection → null
After:  valid rule with absent base → NoDate
        invalid selection at construction/parsing → InvalidConfiguration
```

**Why:** a caller may accept absence but must repair invalid configuration.
**Check:** absent base, each supported direction, invalid selection, invalid
weekday, out-of-range year, and missing subrule. **Limit:** the separation is a
behavior/API change, requiring compatibility decisions and caller migration. A
public enum helps represent valid choices; it does not by itself validate nullable
references or untrusted input.

## Date equality does not establish whole-object immutability

```text
Original: a = date(2000-04-15, description="first")
          a.set_description("second")      # same date equality, changed object
Adaptation: immutable_date = date(2000-04-15)
            annotation = note(immutable_date, "second")
```

The original class documents immutability while allowing description mutation;
the subclass also duplicates description storage. **Before → after decision:**
clarify whether the promise covers the date components or the entire object; move
metadata into a separate owner when their lifecycles differ.
**Check:** date equality/hash remain stable; required metadata survives updates
and serialization; callers using description APIs have a migration path.
**Limit:** mutable annotations are not inherently wrong. The problem is an unclear
contract and duplicated ownership, not a universal ban on metadata setters.
