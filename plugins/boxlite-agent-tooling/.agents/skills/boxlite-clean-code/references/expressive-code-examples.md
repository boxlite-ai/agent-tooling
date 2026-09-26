## TL;DR

Names, variables, and helpers should reveal domain meaning and effects without changing behavior or creating unnecessary indirection.

## How it works

These original adaptations show concrete before/after decisions. The fragments illustrate a local contract; they are not complete implementations or executed test results.

### H01 — Replace mechanical comments with useful contract information

```python
attempts += 1  # Increase attempts by one.
```

The comment repeats the statement. Delete it. Similarly, empty generated parameter/return tags add no information. Useful documentation instead explains an actual boundary, such as whether the attempt count includes the initial call or only retries.

**Check:** comments describe the current counting and retry contract. Preserve required public API documentation, legal notices, and explanations the code cannot express.

**Limit:** do not delete a comment solely because its sentence mentions code. A short statement of units, protocol requirements, or an intentional limitation can prevent a real error.

### H05 — Use stable names for corresponding roles

Before, one request handler calls its result `answer`, another `response`, and a third `payload`, although all hold the same HTTP response role. After, use the repository's chosen term consistently:

```text
handle_creation_request → response
handle_deletion_request → response
```

This lets the reader carry the same expectation between comparable functions.

**Check:** the values really have the same role and type of meaning. If `payload` is only the response body, retain that distinction.

**Limit:** consistency is not a reason for a large unrelated rename or for erasing meaningful differences between request, response, and serialized content.

### H07 — Replace opaque mode selection and dense arithmetic

```text
Before: calculate_pay(employee, true)
After:  overtime_pay(employee)
        straight_time_pay(employee)
```

Name the operations when the Boolean chooses materially different policies. Inside the overtime calculation, distinguish regular duration, extra duration, base pay, and the premium instead of encoding everything in one expression.

**Check:** no overtime, exactly the threshold, just above it, and the relevant rounding boundaries. Retain the same rate units and whether the premium supplements or replaces base pay.

**Limit:** an explicit domain option can be valid input. Splitting entry points must not duplicate the shared pay rule or silently fix arithmetic while claiming a pure refactor.

### H10 — Give capture groups names before using their meaning

```python
# Before:
headers[match.group(1).lower()] = match.group(2)

# After:
field_name, field_value = match.group(1), match.group(2)
headers[field_name.lower()] = field_value
```

The variables explain which captured substring is the key and which is its value. Named capture groups can provide the same clarity if supported and conventional.

**Check:** the match exists; normalization, whitespace, duplicate-header behavior, and values are unchanged.

**Limit:** a renamed local does not validate a regular expression. Avoid extra variables that merely restate syntax without explaining meaning.

### H12 — Name policy values; keep obvious mathematics readable

```python
if rows_on_page == PAGE_ROW_LIMIT:
    flush_page()

circumference = 2 * math.pi * radius
```

The row limit is a policy. The factor two belongs visibly to the formula; introducing `TWO` would not explain it. A library constant also avoids repeated approximations or unnoticed typos in a familiar long number.

**Check:** the policy has one owner, units are clear, and the replacement constant preserves the value or explicitly changes it.

**Limit:** what is “obvious” depends on the audience. A unit-conversion value familiar to one team may deserve a name for another; defaults that can change are not mathematical facts.

### H13 — Reveal the role of a test fixture

Before, a repository assertion uses an unexplained person's name and numeric identifier. The reader cannot tell why that record matters. After, the fixture role is explicit:

```python
hourly_worker = fixture.hourly_employee
found = repository.find_by_name(hourly_worker.name)
assert found.employee_id == hourly_worker.expected_id
```

The scenario is a lookup for the hourly employee, not an unexplained coincidence between two literals.

**Check:** fixture expectations are established independently of `find_by_name`; the repository call crosses the actual boundary being tested.

**Limit:** building the expected identifier by calling the same lookup again is circular. A fixture factory should not hide every meaningful test input behind a large setup framework.

### H15 — Name a decision when it reduces mental work

```python
def eligible_for_removal(timer):
    return timer.expired and not timer.repeats
```

The caller can now say `if eligible_for_removal(timer)` when removal eligibility is a meaningful policy. A buffer predicate similarly reads more directly as `can_compact` than a caller negating `must_not_compact`.

**Check:** both terms still use the same state, evaluation order, and short-circuit behavior. A predicate should not acquire hidden effects during extraction.

**Limit:** a simple local guard may already be clearer inline. Do not add two wrappers solely to ensure a positive predicate name; negative conditions can be the natural domain expression.

### H16 — Separate payment orchestration at meaningful boundaries

```text
for each employee → pay_if_due(employee)
pay_if_due       → check eligibility, then calculate_and_deliver(employee)
```

This separates iteration from the individual payment decision. The operation that calculates and delivers still owns the required order and failure behavior.

**Check:** ineligible employees cause no transfer; eligible employees receive the correct amount once; retries and partial failure follow the existing payment contract.

**Limit:** extracting calculation and delivery into unrelated public methods can leak a transaction or idempotency protocol to callers. A short method is not worth a broken effect boundary.

### H19 — Compute the next boundary once

```python
next_depth = depth + 1
if next_depth < len(tags):
    child = parse_at_depth(body, tags, next_depth)
```

The check and call use the same domain quantity, so changing the meaning of “next” no longer requires finding parallel arithmetic.

**Check:** the last legal depth, first out-of-range depth, and empty tag sequence. Preserve the strict comparison and any existing mutation order.

**Limit:** naming `next_depth` does not prove recursion is bounded or the input valid. Do not change the boundary operator under the guise of extracting a variable.

### H20 — Separate rendering from interpretation in two passes

A rule widget stores the number of extra source dashes. Its renderer hand-builds markup and also turns that count into a display size.

```text
First move:  manual tag concatenation → existing tag renderer
Second move: ambiguous size arithmetic → display size from extra dash count
```

An adapted final shape is:

```python
attributes = rule_attributes(extra_dash_count)
return markup.render_void_element("hr", attributes)
```

The first extraction can reveal a second mixed responsibility that was previously obscured. The shared renderer may also produce different closing syntax from the handwritten code.

**Check:** zero and positive extra dashes, attribute values, and exact emitted markup. If closing syntax changes, record and test that compatibility or defect fix explicitly.

**Limit:** self-closing syntax is not universally required for all HTML contexts. Do not turn a historical output-format example into a blanket markup rule or build a rendering framework for one tag.

### H26 — Use domain vocabulary to reveal a scoring algorithm

An opaque loop advances an index by one or two and adds adjacent values. Naming those concepts as roll index, frame, strike, spare, and bonus exposes the intended bowling rules:

```text
strike → frame score plus next two rolls; advance one roll
spare  → frame score plus next roll; advance two rolls
open   → sum this frame's rolls; advance two rolls
```

This makes a missing or surprising rule easier to notice without reproducing the full scoring implementation.

**Check:** open frames, spares, consecutive strikes, and final-frame bonus handling. Ensure the input's validity and completeness contract is explicit.

**Limit:** descriptive names do not prove the score is correct. Do not move bonus arithmetic into helpers whose names imply rules their code does not implement.

### H27 — Name an abstraction at the level it actually supports

An interface called `dial(phone_number)` is misleading once real implementations connect through non-telephone transports:

```text
phone-only contract: dial(phone_number)
broader actual contract: connect(connection_address)
```

Use established terms for actual patterns and domain concepts. A wrapper named as a decorator should preserve the wrapped contract while adding behavior, such as closing a connection at the end of a session.

**Check:** each supported transport can express its real address and failure semantics; public names migrate deliberately.

**Limit:** do not replace a precise telephone API with a generic string locator when the domain remains telephone-only. A broad name cannot compensate for incompatible underlying contracts.

### H28 — Expose the full effect of a rename

Before, `do_rename` may update inbound references, rename the page, and mutate its path. After, expose that scope at the operation boundary:

```text
rename page only
rename page and update inbound references
```

Named operations or an explicit rename plan can make the choice readable. Keep the established order of reference updates, page mutation, and path rendering visible to the owner.

**Check:** both scopes, affected references, returned path, and partial failure. Renaming must not silently add reference rewriting for existing callers.

**Limit:** an optional scope is not inherently an invalid flag. Preserve transactions, rollback behavior, and API compatibility when reorganizing these effects.

### H29 — Let scope determine how much a name must carry

```python
for i in range(repetitions):
    game.roll(pins)
```

Within this tiny loop, `i` has a conventional role and does not escape. A cached index used across several phases instead needs a domain name, such as `first_unscored_roll`.

**Check:** a reader can recover meaning from the local scope without searching distant initialization.

**Limit:** do not mechanically expand every loop index or shorten semantically important indices merely because the function is small.

### H30 — Make lazy resource acquisition visible

Before, a getter opens an output stream when none exists. A name indicating creation or reuse communicates the effect:

```python
def open_or_reuse_output(self):
    if self.output is None:
        self.output = self.connection.open_output()
    return self.output
```

Callers can now see why the operation may allocate, perform I/O, or fail, rather than assuming it only reads an already available value.

**Check:** repeated calls reuse the resource, failed creation does not cache a broken value, and the owner closes it correctly. If callers can race, verify the appropriate acquisition invariant.

**Limit:** changing from lazy to eager acquisition alters exception timing and lifetime. A rename must not quietly make that behavioral change, and a name alone does not make the method thread-safe.
