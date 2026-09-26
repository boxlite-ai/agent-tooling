## TL;DR

Ownership is clearer when interfaces expose real capabilities, dependencies carry meaning, and operations preserve the full contract they promise.

## How it works

These original adaptations use compact fragments and transformation steps. Collaborator names describe assumed contracts; they are not complete implementations or claims of executed tests.

### H03 — A stack should not invent a capacity percentage

Before, every stack must report how full it is. An implementation without a fixed capacity returns zero just to satisfy the interface. After, boundedness is a distinct capability:

```typescript
interface Stack<T> { push(value: T): void; pop(): T; }
interface BoundedStack<T> extends Stack<T> { remainingCapacity(): number; }
```

Only a caller that truly requires bounded storage depends on `BoundedStack`. Unsupported information is not represented as a plausible but false number.

**Check:** bounded implementations report capacity consistently around push/pop and their documented full/empty behavior. Generic consumers do not assume that capacity reporting exists.

**Limit:** reported free slots are not a guarantee that a future allocation succeeds or that a later concurrent push can claim one. Preserve atomic reservation semantics where needed.

### H04 — A closed state family can intentionally deploy together

Before, a high-level abstraction constructs arbitrary low-level providers. That blocks independent deployment. Compare a genuinely closed state machine:

```text
Connection = Disconnected | Connecting | Connected
transition(state, event) → one of these same states
```

The states and dispatcher may deliberately live in one module because the family is finite and evolves together. This differs from a stable policy importing every external provider.

**Check:** whether new states/providers are added independently, whether consumers must redeploy together, and whether all transitions remain covered.

**Limit:** do not use “state machine” to excuse an open provider list leaking into high-level code. The deployment and change boundary must be real.

### H06 — Data access does not settle responsibility

Two functions inspect an employee's hours:

```text
calculate compensation → applies pay policy to hours and rate
render hours report    → formats the employee's name and hours
```

Moving the pay operation nearer its domain state may reduce exposed representation. Moving report formatting into the employee would instead make the employee change whenever the report layout changes.

**Check:** a report layout change should not alter pay behavior, and a pay-policy change should not require rewriting the formatter. Expose only the stable data the report needs.

**Limit:** an independent pay-policy object can also be appropriate. “This method reads another object” is an investigation prompt, not a command to relocate it.

### H08 — Pure utilities and variable policies need different seams

It is reasonable to call a pure `maximum(a, b)` function without constructing an object. Pay computation might instead depend on a selected contract:

```python
amount = agreement.pay_for(work_log)
```

Create a replaceable policy when different supported agreements actually calculate pay differently. A pure function passed explicitly can supply that seam as well as an object.

**Check:** each real policy preserves required units and rounding; callers do not choose concrete algorithms through repeated hidden type checks.

**Limit:** do not add a hierarchy because a function might vary someday. Stateless functions remain suitable when they represent a stable operation.

### H09 — Make a stored running total an explicit effect

Before, `save_timecard` silently adjusts an aggregate. Readers cannot tell that retrying a save may double-count. After, choose and expose the required policy:

```text
read-side:  save timecard → compute total from cards when requested
write-side: save or replace timecard + update stored total atomically
```

For measured workloads that need a materialized total, name the operation accordingly and make its consistency boundary visible.

**Check:** insert, correction, deletion, retry, and partial failure keep the aggregate equal to its intended source records.

**Limit:** moving computation to reads is not automatically better. The original lesson about responsibility must not erase performance requirements or transaction semantics.

### H11 — Ask the formatter about the capacity it owns

Before, a reporter batches exactly 48 rows because the current formatter happens to fit 48. A replacement formatter fits 32 and silently overflows.

```python
capacity = formatter.rows_per_page()
if capacity <= 0:
    raise InvalidPageCapacity(capacity)
for page in partition(rows, capacity):
    formatter.write_page(page)
```

The dependency becomes explicit: pagination uses the selected formatter's contract. Alternatively, give the formatter ownership of the whole pagination operation.

**Check:** no rows, one row, exact capacity, capacity plus one, final partial page, and invalid capacity. Verify each row is emitted once.

**Limit:** this fragment assumes capacity stays fixed for the operation. If it changes by page or media, the owner must expose that richer contract.

### H14 — Validate assumptions at the boundary

“The first match should be the only match” needs a precise result contract:

```python
matches = repository.find_by_external_key(key)
if len(matches) == 0:
    raise RecordMissing(key)
if len(matches) != 1:
    raise DuplicateExternalKey(key)
return matches[0]
```

Likewise, represent currency with a domain-supported exact model and explicit rounding; handle legitimate absence distinctly from failure; protect possible concurrent updates with the database or runtime's actual atomic primitive.

Be equally precise about capabilities: accept a sequence interface when no array-specific operation is needed, and keep state private unless a real subclass contract requires broader access. Neither a concrete container everywhere nor `protected` everywhere expresses deliberate ownership.

**Check:** zero/one/multiple matches, relevant rounding boundaries, absent values, and the conflicting update interleaving.

**Limit:** the cardinality check alone does not prevent a concurrent insertion. Use a uniqueness constraint or suitable transactional operation where uniqueness must be enforced.

### H17 — Let a pipeline's outputs carry real dependencies

Before, three procedures mutate hidden fields and must be called in order. After, each stage receives the actual result it requires:

```python
plan = validate_request(request)
reservation = reserve_resources(plan)
result = execute_reserved(plan, reservation)
```

The names and values show why execution follows validation and reservation. A single public operation can own all three stages and their failure cleanup.

**Check:** invalid input never reserves resources; failed reservation never executes; failed execution releases or transfers ownership according to contract.

**Limit:** a parameter that is unused except as a ceremonial “ready” token does not establish safety. Real lifecycle enforcement may require private constructors, capability types, or one owning operation.

### H18 — Do not nest a general tool inside an unrelated feature

Before, unrelated renderers import `AliasWidget.VariableExpansion`. The expansion code does not use alias-widget state. After:

```text
AliasWidget.VariableExpansion → template.VariableExpansion
```

The new location reflects the dependency. Consumers no longer need to know about an alias feature merely to expand a template variable.

**Check:** imported/public names and class-loading or serialization behavior remain supported during migration. Confirm that the moved class had no hidden reliance on the former enclosing instance.

**Limit:** a private helper belonging solely to one feature can remain nested. File splitting is useful only when it clarifies a real ownership boundary.

### H21 — Resolve defaults where application policy lives

Before, a network helper translates zero into a default port. After, the entry point distinguishes omission from an explicit value:

```python
port = DEFAULT_PORT if arguments.port is None else arguments.port
server = start_server(port=port)
```

The lower-level operation receives the chosen value. It no longer duplicates application defaults across callers.

**Check:** omitted port uses the intended default, a specified port survives unchanged, and explicit zero retains its documented meaning. Also check environment/configuration precedence.

**Limit:** an API may intentionally define its own default. The goal is one clear owner for each policy, not moving every literal to the entry point.

### H22 — Hide an unstable collaborator route behind an operation

Before, callers navigate a project through a workspace into storage. Adding a storage router forces edits in every caller:

```text
project.workspace.storage.remove_artifact(id)
                     ↓
project.remove_artifact(id)
```

The project operation owns the internal collaboration and can preserve authorization and transaction boundaries when the route changes.

**Check:** the same artifact is removed, permission checks still happen, and failures retain useful context. Verify the operation does not silently expand its effects.

**Limit:** traversing intentional data records or a fluent builder is different from coupling to an internal service graph. Count leaked knowledge, not dots.
