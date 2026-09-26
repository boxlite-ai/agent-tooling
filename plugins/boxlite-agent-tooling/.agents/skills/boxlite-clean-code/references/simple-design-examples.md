## TL;DR
Preserve behavior first, remove duplicated rules, express intent, and keep only the abstractions that earn their cost.

## How it works
These original adaptations show how small extractions can reveal an owner and how over-extraction can undo that benefit. Verify each change through its real operation rather than treating shorter code or more classes as proof of improvement.

## R01 — Derive emptiness from one authoritative fact

```python
class WorkList:
    def __init__(self):
        self._items = []

    def size(self):
        return len(self._items)

    def is_empty(self):
        return self.size() == 0
```

Before, a count and an `empty` flag require two updates for every mutation. After, one fact determines both observations. Duplication includes duplicated knowledge, not only identical text.

**Check:** empty/nonempty transitions agree after additions and removals. A concurrent or remote collection may have different cost and consistency guarantees for emptiness versus size; do not replace a specialized operation without understanding that contract. Caller check-then-act can still race.

## R02 — Own image replacement once

```python
class EditableImage:
    def __init__(self, image):
        self._image = image

    def rotate(self, degrees):
        self._replace(self._image.rotated(degrees))

    def scale(self, factor):
        self._replace(self._image.scaled(factor))

    def _replace(self, replacement):
        previous = self._image
        previous.close()
        self._image = replacement
```

Before, scaling and rotation each create a result, release the previous image, and update ownership. After, one helper names the transition. This adaptation assumes transforms return a distinct owned image and `close()` cannot fail. It preserves transform-before-release and release-before-install ordering; a different required failure guarantee needs a separately designed ownership protocol.

**Check:** successful transformation releases exactly the previous image; transformation failure leaves it usable; no-op transforms do not return the same object into this helper. If close can fail or operations are concurrent, define failure state and synchronization explicitly. Forced garbage collection is not part of the ownership policy.

## R03 — Share vacation accrual sequence, vary the jurisdiction policy

```python
def accrue_vacation(employee, minimum_policy, payroll):
    earned = base_vacation_hours(employee)
    credited = minimum_policy.adjust(employee, earned)
    payroll.credit_vacation(employee.identifier, credited)
```

Before, two jurisdiction-specific methods repeat base calculation and payroll update, differing only in adjustment. After, the shared sequence owns those steps and receives the varying policy. An inheritance template with a policy hook can also work; this example uses composition.

**Check:** each supported policy receives the same earned-hours basis and the correct employee context; each successful accrual writes once. Verify behavior against the actual business specification. No numeric legal minimum is implied here, and a failed or repeated payroll call requires explicit transaction/idempotency rules. Similar workflows with different sequencing should remain distinct.

## R04 — Use recognizable names without manufacturing a class graph

```python
# Before: a chain of mandatory wrappers contributes no policy.
result = ValueReader(ValueStore(Value(amount))).read()

# After: use the value directly when no invariant or behavior is being owned.
result = amount
```

Meaningful operations and established pattern names help readers predict responsibilities. A type called `Command` should actually represent a command; the suffix is not a reason to create one. Likewise, an interface for every implementation or compulsory separation of all fields from behavior creates indirection without necessarily improving design.

**Check:** remove wrappers only when they contribute no validation, identity, lazy behavior, logging, compatibility, or ownership contract. Keep tests and clear shared rules before minimizing component count. A larger but clearer refactor may be better than the shortest possible program.
