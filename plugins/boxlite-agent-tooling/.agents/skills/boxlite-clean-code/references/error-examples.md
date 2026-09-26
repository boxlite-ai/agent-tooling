## TL;DR
Give callers explicit failure and absence contracts while keeping normal operations readable and preserving recovery distinctions.

## How it works
Each original sketch separates domain decisions from error transport. Use the language's established exceptions, error values, or result types. Before/after API changes below are intentional contract choices, not automatically safe refactors.

## E01 — Separate shutdown sequencing from failure reporting

Nested invalid-handle, suspended-state, and operational checks can obscure device shutdown. A boundary can report failure while the operation retains its required guards and order.

```python
def shutdown_device(device_id, devices):
    device = devices.require(device_id)
    if device.is_suspended():
        raise ShutdownRefused("device is suspended")
    device.pause()
    device.clear_pending_work()
    device.close()


def request_shutdown(device_id, devices, reporter):
    try:
        shutdown_device(device_id, devices)
    except ShutdownFailure as failure:
        reporter.record(failure)
```

Assume `ShutdownRefused` belongs to the domain failure hierarchy. The reporting boundary deliberately consumes those failures; callers needing a failure result must receive one instead. An extraction must not lose the suspended-device guard simply to make the happy path straight.

**Check:** invalid and suspended devices cause no pause/clear/close effects; normal shutdown preserves their order; each intermediate failure has the documented cleanup and reporting result. Error handling does not make an irreversible device operation transactional.

## E02 — Establish the storage failure contract first

An empty-list stub makes a missing file look like successful empty content. Start by specifying the required failure, then implement the read with scoped ownership.

```python
def test_missing_section_is_reported(missing_path):
    with pytest.raises(SectionMissing):
        read_section(missing_path)


def read_section(path):
    try:
        with path.open("rb") as stream:
            return decode_section(stream)
    except FileNotFoundError as cause:
        raise SectionMissing("cannot open section") from cause
```

The missing-file test must fail against the old empty-success stub before passing with the implementation. The stream closes even if decoding fails. Define other storage and decoding failures deliberately; a broad catch must not misclassify corruption as absence.

**Check:** missing, valid empty, valid nonempty, unreadable, and malformed input take the intended paths; resources close after decode failure. A close failure can affect the visible exception and needs a policy when consequential.

## E03 — Stop low-level failure details from spreading through callers

A new provider failure should not force unrelated layers to learn that provider's taxonomy. Translate where the dependency enters the application while keeping the domain result explicit.

```rust
fn load_section(id: SectionId, source: &Source) -> Result<Section, StoreError> {
    let bytes = source.fetch(id).map_err(StoreError::from_source)?;
    decode_section(bytes)
}
```

This is a language adaptation: Rust propagates a typed result; Go can return a domain error; Java or Python may propagate an exception. The important boundary is what callers can usefully handle, not eliminating error types from every signature.

**Check:** the translation retains diagnostic cause and distinctions needed for recovery. A stable domain error does not justify converting every failure into a single untyped string or catching programmer defects.

## E04 — Translate port failures by the caller's response

```python
class Port:
    def __init__(self, vendor_port):
        self._vendor_port = vendor_port

    def open(self):
        try:
            self._vendor_port.open()
        except (VendorBusy, VendorNotReady) as cause:
            raise PortUnavailable("opening port failed") from cause
```

Before, each caller repeats vendor-specific catches with the same response. After, the adapter owns translation. Here both errors mean unavailable to this caller; if one permits retry and another requires operator action, retain that distinction instead.

**Check:** each mapped error preserves its cause; unmapped failures propagate; useful operation/resource context excludes secrets. Reporting happens at the intended boundary without duplicate logs. This narrow wrapper does not imply wrapping an entire vendor API.

## E05 — A meal allowance is normal policy, not failed retrieval

```python
def meal_reimbursement(employee_id, expenses, allowances):
    recorded = expenses.find_meals(employee_id)
    if recorded is None:
        return allowances.daily_meal_amount(employee_id)
    return recorded.total
```

A policy operation replaces exception-driven branching in every expense total. A special-case object could serve the same purpose when callers need several common operations. A simple value is sufficient here.

**Check:** absent receipts produce the configured allowance; a legitimate recorded zero remains zero; failed retrieval propagates and never becomes an allowance. Confirm whether “no meals” is a normal business state before changing the API.

## E06 — Replace a null cascade with explicit ownership and absence

```python
class ItemRegistration:
    def __init__(self, registry):
        if registry is None:
            raise ValueError("registry is required")
        self._registry = registry

    def register(self, item):
        existing = self._registry.find(item.identifier)
        if existing is None:
            raise UnknownItem(item.identifier)
        if existing.billing_period.has_retail_owner:
            existing.register(item)
```

Before, missing dependencies and missing items disappear into nested conditions or fail during later dereferencing. After, construction requires the dependency and the operation states its missing-item outcome. This example assumes missing items are errors; a different domain may return an explicit “not found” result.

**Check:** missing configuration fails at setup, valid registration occurs once, missing items follow the documented result, and non-retail items retain their intended behavior. Replacing a historical silent skip with an error requires explicit contract approval in the task.

## E07 — Successful absence can be an empty collection

```python
def total_pay(employees):
    return sum(employee.pay for employee in employees)


employees = employee_store.list_active()  # [] means a successful empty query.
amount = total_pay(employees)
```

Before, callers check for null before every iteration. After, a successful query always returns a collection. The producer owns the guarantee; catching every query exception and returning `[]` would hide outages.

**Check:** no employees yields zero, real employees retain order where relevant, and store failures remain failures. Preserve mutability and lazy/eager consumption contracts when replacing a nullable iterable.

## E08 — A required point should have a required-point contract

```python
def projected_distance(start: Point, end: Point) -> float:
    return (end.x - start.x) * 1.5
```

An operation requiring two points has no useful interpretation for an accidental missing argument. Reject malformed external data before calling it, or use a typed required value when the language supports one. Python annotations document intent but do not enforce it at runtime.

**Check:** valid and coincident points work; invalid boundary input is rejected before the metric executes. If absence is meaningful, represent and handle it explicitly. Assertions document internal assumptions but may be disabled and should not replace boundary validation.
