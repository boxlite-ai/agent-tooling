## TL;DR

Concurrent servers need explicit capacity, completion, resource ownership, and shutdown contracts.

## How it works

These original pseudocode examples adapt the book's server, page-reader, and
future scenarios. Admission bounds, structured cleanup, deadlines, and explicit
outcomes are modern extensions; the historical tutorial does not fully supply them.

## Separate request work from scheduling

```text
Before: accept_connection() → spawn_thread() → read/process/write/close
After:  connection = accept_connection()
        admission.submit_or_reject(Request(connection))
```

The accepting component owns an unaccepted/rejected connection. A successful
handoff transfers ownership to the request task, which closes it on every exit.
The scheduler owns execution policy and the lifecycle of accepted tasks.
**Why:** changing worker policy need not rewrite request behavior.
**Check:** failure before, during, and after handoff has one cleanup owner.
**Limit:** separation does not make shared request dependencies safe, and a trivial
application may express these roles with functions instead of a class per role.

## A throughput test must observe correct responses

```text
Before: start clients; wait until their threads return; assert elapsed < budget
After:  results = run_clients_with_deadline()
        require every client completed successfully
        require every reply matches its request
        require elapsed < budget
```

The book uses a time budget to compare serial and overlapping requests. Unobserved
worker failures can make a test finish quickly. **Check:** deliberate server
failure makes the test fail; include connection teardown and task joins.
**Limit:** isolate or record load/runtime assumptions. A noisy shared runner may
support a correctness test without a stable tight performance threshold.

## A fixed worker count still needs an admission policy

```text
Before: every connection creates another thread
After:  at most W active tasks and Q queued tasks
        if admission unavailable by deadline:
            reject request using protocol; close connection
```

**Book scenario:** a scheduler facade allows a thread-per-request implementation
to become an executor. **Modern adaptation:** bound queued work as well as workers;
choose whether saturation blocks, rejects, or sheds work. **Check:** saturation,
submission failure, and shutdown reject new work without leaking connections.
**Limit:** a blocked accept loop or retained queued socket consumes resources too;
capacity must cover the entire path, not only the visible worker count.

## Futures express overlap and its join

```text
Before: remote = fetch(); local = calculate(); return combine(remote, local)
After:  within owned_task_scope(deadline):
            remote = start(fetch)
            local = calculate()
            return combine(await(remote), local)
```

The book overlaps an external call with independent local work. The scope here
means failures/cancellation are observed and remaining tasks are stopped or joined
according to an explicit policy. **Check:** remote failure, local failure, timeout,
and cancellation preserve error context and release resources.
**Limit:** side-effect order changes when work overlaps; independence must be real.
A deadline does not forcibly terminate an uncooperative external operation.

## Reserve a URL under the lock; fetch outside it

```text
Before: locked(source): url = source.next(); page = fetch(url)
After:  locked(source): reservation = source.take_if_available()
        if reservation is Item: page = fetch(reservation.url)
```

The book's prose advocates a small critical section; this adaptation repairs the
illustrative listing's placement of I/O inside synchronization.
**Check:** one stalled fetch does not prevent another worker reserving another URL;
no URL is unintentionally lost or duplicated at exhaustion.
**Limit:** reservation is not successful processing. If failures must be retried,
model acknowledgment/requeue explicitly, with duplicate-effect protection.

## Socket lifetime includes framing and failures

```text
Before: request = read(socket); send(reply(request)); close(socket)
After:  with owned_connection(socket):
            request = read_frame(deadline)
            send_frame(reply(request), deadline)
```

The tutorial's message utility writes/reads a framed string and flushes output.
Changing resource structure must preserve that protocol, including flush, encoding,
and stream-header expectations. **Check:** truncated input, peer disconnect,
processing failure, and output failure still close the connection and preserve the
primary error. **Limit:** closing a per-message wrapper may close the underlying
connection; pooling changes ownership and must not be introduced accidentally.

## Parent shutdown cannot rely on an unlimited join

```text
Before: tell children to stop; join every child without a deadline
After:  stop admission; signal the actual wait mechanisms
        await accepted tasks within shutdown policy
        report unfinished tasks; release only resources no task can still use
```

**Book scenario:** one stuck child prevents its parent from finishing shutdown.
**Modern adaptation:** define drain versus abandon, cancellation propagation,
time budgets, and escalation/containment. **Check:** active, queued, blocked, and
failed children; shutdown remains observable and never reports unfinished work as
success. **Limit:** timing out a join does not stop its task. Do not free a resource
while an uncooperative worker may still access it; escalate at a boundary that can
safely contain that work.
