---
name: clean-code
description: Apply Clean Code principles when implementing, refactoring, or reviewing maintainability.
---

# Clean Code

Improve the requested code by making its intent, contracts, and ownership easier
to follow. Treat principles as decision tools, not a reason to rewrite working
code or impose personal style.

## How it works

Start with a concrete source of confusion or risk, identify the behavior that must
survive, then choose the smallest change that makes that behavior easier to see.
Use the repository's instructions, conventions, and checks throughout.

## Establish the contract

- Inspect the relevant callers, implementation, nearby tests, and project docs.
  Record the inputs, outputs, failures, side effects, and ordering that matter.
- Distinguish a behavior change from a refactor. Preserve observable behavior
  during a refactor; surface ambiguities before changing a public contract.
- Keep review requests read-only unless edits are requested. Tie findings to a
  source location and consequence; offer a small remedy rather than style quotas.
- Stay within the requested change. Follow local research, design, review, and
  publication requirements; this skill grants no additional permissions.

## Choose the change

| Evidence in the code | Useful response | Trade-off to check |
| --- | --- | --- |
| A name hides intent or units | Name the domain value, predicate, or operation explicitly | Preserve public names unless changing callers is in scope |
| A function mixes parsing, policy, and I/O | Keep orchestration readable and separate distinct responsibilities | Extraction must clarify the flow, not scatter it across trivial wrappers |
| Callers coordinate shared state and helper order | Group state and behavior behind a cohesive operation | Keep stateless, independent helpers simple |
| A flag selects different workflows | Prefer named operations for distinct caller intentions | Ordinary predicates do not automatically need new APIs |
| Similar blocks enforce the same rule | Share the rule where its owner is clear | Similar syntax alone is insufficient; unrelated rules can evolve separately |
| Error handling hides failure or loses its cause | Preserve the cause and add operation-specific context | Exclude secrets and make intentional recovery explicit |
| Comments explain mechanics or contradict behavior | Improve names and structure; retain explanations of constraints and intent | Preserve non-obvious protocol or compatibility rationale |

Validate external inputs where they enter the system. Keep business decisions
separate from transport and persistence when that exposes a useful boundary.
Avoid adding abstractions, dependencies, or performance work without a concrete
need in the current task.

## Boundaries and resource ownership

- Make network calls, file writes, process execution, and mutations visible.
  A harmless-looking query should not conceal a state change.
- Identify who releases each acquired resource, including failure and
  cancellation paths. Keep cleanup in the owning scope.
- For external work, preserve explicit limits on time, retries, concurrency, and
  queued work. Establish idempotency before retrying a side effect.
- Use structured APIs and appropriate validation or encoding at shell, SQL, URL,
  path, and HTML boundaries. Keep credentials out of errors, examples, and fixtures.

## Example: reveal the operation without changing it

An existing function receives a client and a timeout measured in milliseconds:

```python
# Before
def run(c, t):
    if t <= 0:
        raise ValueError("timeout must be positive")
    return c.fetch(timeout_ms=t)

# After, when these names are internal and callers can be updated together
def fetch_with_timeout(client, timeout_ms):
    if timeout_ms <= 0:
        raise ValueError("timeout must be positive")
    return client.fetch(timeout_ms=timeout_ms)
```

The names expose the operation and units; validation, exception text, and the
single client call remain the same. Check callers, including keyword arguments,
before renaming. Adding a retry here would change the contract and needs separate
reasoning about repeated calls and their effects.

## Verify the result

- Inspect the diff for unintended API, ordering, error, or side-effect changes.
  Update affected documentation and remove explanations of superseded behavior.
- Check behavior through the production boundary: valid input, relevant failures,
  and observable effects. For the example, invalid timeouts must fail before the
  client is called; a valid timeout must reach it unchanged exactly once.
- For a defect fix, first demonstrate the defect with the production changes
  absent, then verify the complete fix. Do not substitute formatting assertions
  or test-built values for behavior exercised through project code.
- Run the narrow relevant checks and the project's required validation. Report
  what actually ran, remaining limitations, and the rationale for the change.

## Attribution

Adapted from the engineering principles in the
[published BoxLite workflow](https://github.com/boxlite-ai/agent-tooling/blob/a2c0deb388e36da035805f4115cb29a41e5af590/plugins/boxlite-agent-tooling/guidance/workflow.md),
which credits Robert C. Martin's *Clean Code* via the polygala-inc AGENTS.md
distillation. This is practical guidance in original wording, not book excerpts;
the published workflow also includes project-specific rules beyond the book.
