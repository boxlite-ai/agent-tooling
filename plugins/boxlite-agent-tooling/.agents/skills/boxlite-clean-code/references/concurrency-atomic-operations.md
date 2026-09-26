## TL;DR

Atomicity must protect the complete state transition that callers rely on.

## How it works

The book supplies the scenarios below. Code is original pseudocode; atomicity,
publication, and fairness must come from the chosen runtime's actual contract.

## An increment reserves an ID

```text
Before: old = shared_id; shared_id = old + 1; return old + 1
After:  return counter.increment_and_get()
```

Two callers can read the same old value and return the same ID. One indivisible
read-modify-write fixes that invariant; a lock covering the complete operation is
another valid design. **Check:** two completed calls return distinct reservations
and advance the state twice. **Limit:** atomicity does not define overflow,
persistence, or cross-process uniqueness. Preserve pre-increment versus
post-increment return behavior rather than substituting a similarly named primitive.

## Constant assignment: count observable outcomes, not schedules

```text
Same writers:      reset(0) overlaps reset(0) → final value remains 0
Different protocol: reset(0) overlaps reserve_id() → contract needs a decision
```

The book contrasts identical constant stores with read-modify-write. Many
interleavings need not imply many results. **Check:** identify who can read and
write, and define allowed observations. **Limit:** a reset racing reservation can
reuse IDs even when each individual operation is atomic. Historical bytecode
counts do not establish a modern memory or visibility guarantee.

## Compare-and-swap: retries must not repeat external effects

```text
repeat within cancellation/deadline policy:
    observed = state.load()
    candidate = pure_update(observed)
    if state.compare_exchange(observed, candidate): return candidate
```

**Book scenario:** a supported atomic update can replace a lock for one suitable
state transition. **Modern adaptation:** explicitly reason about repeated
computation and progress. **Check:** failed attempts do not commit effects, and the
successful value satisfies the invariant. **Limit:** sending a payment or message
inside `pure_update` can repeat it. Do not build a multi-object invariant from
independent atomics or promise CAS is always faster; prefer a standard operation
when it already expresses the needed transition.

## Insert-if-absent: two safe calls can make an unsafe protocol

```text
Before: if not map.contains(key): map.put(key, candidate)
After:  winner = map.insert_if_absent(key, candidate)
```

Another caller can insert between the check and write. One owner must decide and
mutate together. **Check:** simultaneous candidates preserve one winner and each
caller receives the documented result. **Limit:** eager construction may still
happen twice; callback-based APIs may have different execution guarantees. Do not
put exactly-once side effects in value creation without verifying its contract.

## Iterator exhaustion: reserve, then work

```text
Before: if iterator.has_next(): item = iterator.next()
After:  item = source.take_if_available()
        if item is Exhausted: finish
        else: process(item)
```

The final item can disappear between two synchronized methods. The atomic API
returns a claimed item or explicit exhaustion. **Check:** compete for the last item;
exactly one caller receives it and the other terminates cleanly. **Limit:** avoid
holding the reservation lock through independent processing. Mutation plus a return
value is appropriate here; mechanically separating command and query breaks safety.

## Client locking versus server or adapter ownership

```text
Client protocol: every caller locks source around has_next + next
Owned protocol:  source.take_if_available() owns that complete transition
Adapter:         guarded_source.take_if_available() wraps the legacy pair
```

The book compares all three. An owner reduces the chance that one caller forgets
the rule. **Check:** every access to the underlying state uses the same protocol.
**Limit:** a new wrapper cannot protect against callers retaining raw access, nor
against another wrapper using an unrelated lock. Client locking can be necessary
for a third-party interface, but document the boundary and centralize it when useful.

## Ring-buffer pointer and count: repairing corruption is not prevention

```text
Before: update(pointer); publish; update(count)
        repair_job periodically resets contradictory state
After:  one owner commits pointer and count as one valid transition
```

**Book scenario:** an unguarded ring-buffer use made terminal state simultaneously
appear full and empty. Rebooting and periodic reset relieved symptoms while the
missing synchronization remained. **Check:** assert the pointer/count relation at
observable transitions, wraparound, full, and empty boundaries. **Limit:** a repair
may remain an explicit operational mitigation, but it can discard work and must not
be reported as proof that corruption cannot recur.
