## TL;DR
Choose explicit data or owned behavior according to invariants and the kinds of changes the code must support.

## How it works
These original adaptations preserve recognizable scenarios while using current language idioms. An API change needs caller migration; a new type is useful only when it owns a meaningful contract. Sketches omit unrelated imports and surrounding application types.

## O01 — Coordinates are an operation, not two unrelated writes

Before, clients assign `point.x` and `point.y` separately. A mutable point abstraction can instead replace its coordinate pair as one domain operation.

```python
class MovablePoint:
    def __init__(self, x, y):
        self._coordinates = (x, y)

    def move_cartesian(self, x, y):
        self._coordinates = (x, y)

    def move_polar(self, radius, angle):
        self.move_cartesian(radius * math.cos(angle), radius * math.sin(angle))

    def cartesian(self):
        return self._coordinates
```

The caller no longer controls storage layout or performs a half-update. An immutable point record may be even simpler when replacement values fit the domain. A logical paired update does not promise thread safety or transactional behavior across observers.

**Check:** Cartesian/polar operations agree within the numerical contract; failed validation leaves the old point intact if that is required. Define treatment of non-finite values and negative radii rather than inventing it during refactoring.

## O02 — Ask a vehicle for the domain measurement

```python
# Before: every display needs storage units and calculation policy.
remaining = vehicle.gallons_remaining / vehicle.tank_capacity_gallons

# After: the measurement has an explicit range and meaning.
remaining = vehicle.fuel_fraction_remaining()
```

The vehicle can change its storage representation without changing every display. Fraction and percentage are different contracts; naming should make the range clear. Diagnostics may legitimately need raw readings through a separate documented interface.

**Check:** empty and full produce the specified values; invalid capacity, sensor failure, and out-of-range readings retain explicit semantics. Do not hide a failed reading behind a plausible percentage.

## O03 — Shapes expose an extension trade-off

A closed set of data variants makes a new operation local to one function:

```python
@dataclass(frozen=True)
class Circle:
    radius: float

@dataclass(frozen=True)
class Rectangle:
    width: float
    height: float


def area(shape):
    match shape:
        case Circle(radius):
            return math.pi * radius * radius
        case Rectangle(width, height):
            return width * height
        case _:
            raise TypeError("unsupported shape")
```

A behavior-oriented version localizes a new variant:

```python
class Disk:
    def __init__(self, radius):
        self.radius = radius

    def area(self):
        return math.pi * self.radius * self.radius
```

Adding `perimeter` to the data version leaves the records unchanged. Adding a triangle requires updating its operations. Polymorphic shapes reverse that pressure: a new shape supplies existing operations, while a new operation usually touches every shape.

**Check:** implement the actual requested extension and inspect the changed surface. Do not combine both designs merely to satisfy a pattern; preserve dimension validation and unsupported-variant behavior.

## O04 — Replace structural navigation with the intended operation

```python
# Before: the compiler knows context layout and scratch-file policy.
path = context.options.scratch_directory / relative_class_file
with path.open("wb") as output:
    output.write(bytecode)

# After: the scratch owner supplies the operation and resource boundary.
with context.open_scratch_output(relative_class_file) as output:
    output.write(bytecode)
```

Introducing intermediate variables would shorten the chain without removing knowledge of the context's internals. A purpose-built operation can own path rules, mode, and creation behavior. Do not add a forwarding getter for every possible nested property.

**Check:** destination, traversal restrictions, creation/overwrite policy, errors, and closing responsibility remain explicit. Plain immutable configuration data and fluent builders can legitimately expose structure; count leaked policy rather than dots.

## O05 — Make transport data honest

```python
@dataclass(frozen=True)
class MailingAddress:
    street: str
    city: str
    postal_code: str
```

A record can communicate transport intent more clearly than a class containing only mechanical getters. It does not by itself validate postal rules or hide a representation. Immutability here is an explicit design choice, not a required property of every DTO.

**Check:** serialized names, missing/optional fields, equality, and caller mutation expectations remain compatible. Retain framework-required accessors where needed; a public schema change is not cosmetic cleanup.

## O06 — Separate persistence mechanics when policy needs its own owner

```python
def approve_reimbursement(claim_id, claims, approval_policy):
    claim = claims.load(claim_id)
    decision = approval_policy.evaluate(claim)
    claims.record_decision(claim_id, decision)
    return decision
```

Before, an Active Record row accumulates business decisions alongside loading and saving. After, the decision has a focused owner while the repository remains responsible for persistence. The row may still be the right data carrier; a duplicate domain model is not automatic progress.

**Check:** validation and decision behavior survive; recording uses the necessary transaction/concurrency control. This sketch leaves that persistence contract with `claims`; it does not guarantee safety by separating methods. Simple CRUD may not need another policy object.
