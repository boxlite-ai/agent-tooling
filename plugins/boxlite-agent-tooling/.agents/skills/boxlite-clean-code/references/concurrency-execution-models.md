## TL;DR

Safe access alone does not guarantee progress, fairness, or termination.

## How it works

The book develops producer/consumer, readers/writers, philosophers, and two-resource
pool scenarios. Snippets below are original pseudocode. Cancellation, deadlines,
and retry policies are explicit modern adaptations, not runnable library APIs.

## Producer exits while consumer is blocked

```text
Before: producer stops; consumer waits forever for producer's next message
After:  owner closes/cancels channel
        blocked consumer wakes with Closed/Cancelled and terminates
```

A parent-level stop flag does not necessarily reach a task blocked inside receive.
**Check:** consumer on an empty queue, producer on a full queue, several consumers,
and producer failure. **Limit:** one sentinel may wake only one consumer; sending it
can itself block on a full queue. Use a documented channel protocol that wakes all
relevant waiters and decide whether queued items drain or are abandoned.

## A bounded work queue coordinates producers and consumers

```text
Before: producers append without a capacity contract
After:  send(work, deadline) → Accepted | Overloaded | Closed
        receive(deadline)  → Work | Closed | Cancelled
```

The queue owns full/empty transitions and notifications. **Check:** capacity is
never exceeded; blocked parties wake after the relevant state change and on close.
**Limit:** removing work from a queue is not proof its effect happened exactly once.
Define acknowledgment/retry separately if processing can fail.

Primitive choice follows the contract: a lock protects an invariant; a semaphore
limits concurrent admission; a latch/barrier coordinates an event. None
interchangeably provides fairness, cancellation, or ownership of external effects.

## Readers and writers: throughput can hide starvation

```text
Before: admit every reader whenever no writer is active
After:  when a writer queues, use documented reader/writer admission policy
        admit eligible work without exposing a partial update
```

An endless stream of readers can prevent the update that would refresh their data.
**Check:** readers see valid snapshots and queued writers eventually make progress
under the supported load assumptions; also test readers under frequent writes.
**Limit:** writer priority can reverse the starvation problem. Use a supported
primitive whose fairness contract matches the requirement, or explicitly document
why progress is probabilistic rather than guaranteed.

## Philosophers: two individually available resources can form a cycle

```text
Before: each task holds its left fork while waiting for its right fork
After:  each task acquires its required forks in the same global order
```

The objects are resource handles, not necessarily mutexes. **Check:** a controlled
all-first-resource schedule exposes the old cycle; the new protocol completes and
releases both resources. **Limit:** the test must not insist that all fixed tasks
hold a first resource simultaneously when the new ordering forbids that state.
Ordering prevents the modeled cycle, not starvation or every possible deadlock.

## Database and message pools: locks can be resource limits

```text
Before: create acquires DB then MQ; update acquires MQ then DB
After:  every path acquires DB then MQ and releases on all exits
```

With exhausted finite pools, each group can hold what the other needs. The four
conditions to inspect are exclusion, holding while waiting, inability to reclaim a
held resource, and cyclic acquisition. **Check:** map every acquisition path,
including failure and shutdown; use tiny pool capacities to expose the boundary.
**Limit:** consistent order can retain a resource longer than use requires. If the
second resource is discovered dynamically, use a different complete strategy rather
than claiming the order is universal.

Other strategies may remove one condition: allow genuinely safe simultaneous use,
reserve the whole needed set atomically, or release held resources before retrying.
Checking that resources appear free and then taking them separately is still a race;
adding a few resources only postpones exhaustion unless demand is actually bounded.

## Retry can trade deadlock for livelock or starvation

```text
Before: acquire A; fail B; release A; immediately repeat in lockstep forever
After:  acquire all through bounded admission/retry policy
        on conflict: release owned resources, honor cancellation/deadline
```

The book shows that removing a wait cycle is not enough if tasks collide forever or
one task never succeeds. **Check:** multiple contenders finish within the promised
progress policy; retry metrics and exhaustion are observable; effects are not
repeated before successful acquisition. **Limit:** random delay/backoff may improve
progress but is not a fairness proof. Cooperative requests to release resources
need a protocol; forcibly stealing a live connection can corrupt its owner's work.
