## TL;DR

Concurrency tests should control critical interleavings and observe worker failures, completion, and cleanup.

## How it works

The book compares ordinary tests, rare-race loops, manually inserted scheduling
points, randomized instrumentation, and platform/load variation. These examples
adapt that reasoning. Pseudocode is illustrative; use supported runtime/test tools.

## Establish domain behavior before testing scheduling

```text
Domain test:  parse_request(input) → expected operation or explicit error
Task test:    schedule(real_handler, competing_inputs) → observed completions
```

Testing thread-aware orchestration separately narrows failure causes and makes
worker counts and dependencies substitutable. **Check:** test the actual domain
code synchronously, then exercise the real task boundary with concurrent work.
**Limit:** a synchronous pass does not establish atomicity, shutdown, or failure
propagation. A fake scheduler can test a caller's decision without proving the real
scheduler's contract.

## Rare lost updates: turn a demonstration into a regression

**Book scenario:** many pairs of threads try to expose an increment race. Its
illustrative test succeeds when broken behavior is found; machine-dependent
iteration counts make it an unreliable maintained regression.

```text
Old implementation under controlled schedule:
    task A reads 8; task B reads 8; A writes 9; B writes 9
Regression assertion on production results:
    both tasks completed; reserved IDs are distinct; final counter is 10
```

**Modern adaptation:** a known-race test controls the real conflicting boundary,
fails the old invariant, and passes with the whole fix present. A test seam may
control scheduling but must not implement missing synchronization. **Check:**
remove every production fix, observe the intended invariant failure, restore all
changes, and observe success. Capture returned results and worker errors as well
as final shared state. **Limit:** the fixed atomic operation may exclude the old
internal schedule; do not create a barrier that requires entering its critical
section twice and deadlocks the corrected code.

## Manual scheduling points: yield is not a lock or a proof

```text
Before: add sleep(10ms); hope the competitor reaches the desired instruction
After:  test waits for "reservation reached" from the real task
        test releases a specific competing operation
```

The book inserts yield points to change interleavings. **Modern adaptation:** use
explicit events/barriers for a known dependency and a deadline for every wait.
**Check:** the event signals the state being tested, not merely that a thread was
created. Ensure instrumentation does not create the defect.
**Limit:** yielding while holding a lock does not let a competitor acquire that
same lock. A waiting primitive may release it, changing semantics rather than just
timing. Do not substitute arbitrary calls without understanding those contracts.

## Automated instrumentation: explore, retain, reproduce

```text
for bounded schedule in campaign(seed, configurations):
    outcome = run_real_scenario(schedule, deadline)
    if invariant_failed(outcome): save_schedule_and_inputs(); fail
```

The book's automated jiggle points choose timing perturbations and reports that
instrumentation exposed a known race more frequently. **Modern adaptation:** use
appropriate supported schedule exploration/race tooling; retain enough evidence to
reproduce a discovered failure. **Check:** include the actual invariant, process
exit, uncaught worker errors, and cleanup status.
**Limit:** a thousand passes are evidence about the tried schedules, not proof of
race freedom. Historical tool names and failure-frequency anecdotes are not current
recommendations or performance guarantees. Keep exploration hooks out of production
unless their overhead and semantics are intentionally part of the design.

## Vary worker count, platform, and dependency timing

```text
Configuration set:
    one worker; contention; saturation; fast/slow/failing dependencies
    each supported deployment environment; cancellation and shutdown boundaries
```

Known-broken examples in the book fail at different rates on different systems.
Separating scheduling from work makes these configurations easier to exercise.
**Check:** campaigns are bounded; record runtime/platform, seed, worker counts,
capacity, and the exact failure. Investigate a failure even if later runs pass.
**Limit:** more workers than processors can perturb scheduling, but is not a
universal production tuning rule. Timing changes may expose unrelated defects;
retain the evidence and establish causality rather than labelling every intermittent
failure a race.

**Shared test contract: completion includes cleanup**

Every worker must produce an observed success, failure, or cancellation outcome.
A timeout should identify unfinished work and trigger safe cleanup or isolation,
not leave background workers altering later tests. For deadlock tests, observe the
resource wait cycle; for performance tests, count valid responses. Sleep duration,
quiet logs, and a test function returning are insufficient completion evidence.
