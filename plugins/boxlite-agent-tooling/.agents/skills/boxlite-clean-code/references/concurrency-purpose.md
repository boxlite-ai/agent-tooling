## TL;DR

Choose independent work and explicit ownership before choosing threads.

## How it works

These examples adapt the book's scenarios. Snippets are original pseudocode, not
runnable implementations; use the target runtime's verified primitives. The
before/after changes describe intended behavior, not measured speedups.

## Daily aggregation: overlap independent waiting

**Book scenario:** a daily job visits sites one at a time until it misses its daily
window. The bottleneck includes socket waiting.

```text
Before: fetch A → parse A → fetch B → parse B → merge
After:  bounded workers fetch/parse A and B independently → ordered merge
```

**Modern adaptation:** cap active requests and queued work, apply per-request and
whole-job deadlines, and retain each site's success/failure. The book's idealized
one-second fetch and half-second parse illustrates overlap, not a performance
promise. **Check:** same required results, deliberate partial-failure policy,
provider limits, measured completion time. **Limit:** shared bandwidth, CPU, and
rate limits can dominate; concurrency may make them worse.

## A queue of users: latency differs from throughput

**Book scenario:** a request needing one second can wait behind many other users.

```text
Before: request 151 waits behind 150 serial requests.
After:  requests use bounded concurrent capacity;
        excess requests wait within a deadline or receive overload feedback.
```

**Why:** executing independent waiting work together can reduce queue delay.
**Check:** successful completions, queue time, service time, and rejection behavior
at saturation. **Limit:** increasing threads cannot create an unavailable database
connection or additional CPU capacity. A faster rejected request is not success.

## Large data sets: partition before merging

**Book scenario:** independent data sets can be processed on separate computers.

```text
Before: shared_total += evaluate(each_record) from many workers
After:  partials = bounded_map(partition → evaluate_partition(partition))
        result = merge_in_required_order(partials)
```

**Why:** independent ownership removes shared accumulator races.
**Check:** every input belongs to one partition; empty/failed partitions are handled;
results match the required ordering and numerical contract. **Limit:** floating
point and other non-associative merges may change when regrouped. Distribution
adds failure and retry semantics; local parallelism is not a transparent substitute.

## Servlet state: local references can still share objects

**Book scenario:** a container schedules requests while handlers operate on request
parameters. It does not make application fields or external resources independent.

```text
Before: handler.current_user = request.user
        answer = render(handler.current_user)
After:  user = request.user
        answer = render(user)
```

**Why:** one request cannot replace another request's local binding.
**Check:** overlap requests for different users and verify isolation, including
shared cache/database interactions. **Limit:** `user` can still refer to mutable
shared data; moving a reference into a local variable does not copy its object.

## Copies and one merge owner: name snapshot semantics

**Book scenario:** workers use read-only copies or private results, then one thread
merges them instead of synchronizing every mutation.

```text
Before: workers mutate shared_report.rows
After:  snapshot = freeze_required_input()
        rows = bounded_map(worker → worker.build_rows(snapshot))
        report = merge_rows(rows)
```

**Why:** ownership narrows the places where the result can change.
**Check:** snapshot depth, stable inputs, duplicate handling, failure policy, and
memory use. **Limit:** shallow copies can still share mutable children; a snapshot
may intentionally become stale. Measure allocation and lock costs for the actual
workload instead of adopting the book's broad performance predictions.
