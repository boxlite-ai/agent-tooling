# Human confirmations

## TL;DR

Timed confirmations use one typed reply and one saved request per decision.

## Timed confirmations

`.agents/lib/user-question.sh` renders and parses questions. The host prompt hook checks the checkout and session, then the state machine validates the request ID under its lock.

| Decision | Exact reply format | Five-minute fallback |
| --- | --- | --- |
| PR size | `pr-size-exception: <request-id> Bypass limit` or `Split PR` | Split. |
| PR review | `reviewed: <request-id> <what changed>` | Keep draft or uncreated. |
| Design | `design-decision: <request-id> <choice> <reason>` | Keep edits blocked. A matching explicit decision can arrive later. |
| Git retry | `commit-audit-decision: <request-id> <choice>` or `push-audit-decision:` with the same arguments | Reflect again. A fresh audit is required. |

Submit the line in the checkout that opened the question. For example, `reviewed: 0123456789abcdef0123456789abcdef Check the retry` applies only to that request.

The PR review gate rechecks the target before consuming the request. It allows one retry within 600 seconds of acceptance. Size approval never grants review authority.

Git retry matches the session, epoch, branch, head, and latest failure. A recorded **Stop** keeps Git blocked. Silence never approves.

### Renewal

Only explicit human instruction renews an expired or declined size request. Remeasure and show the current diff before renewal.

The state machine archives the old record and instruction under lock, then publishes a fresh ID and 300-second deadline. A reply to the archived ID cannot answer the new request.

### Upgrade recovery

Resolve outstanding requests before upgrading, then shut down old sessions. The new version reads only version-two state. Unsupported records block at the reported path and keep their original bytes.

For a still-bound request, restore the matching repository tooling revision and host plugin. Use the repository hold and installer for tooling, then reload the old host plugin and resume the original checkout and session. [Installation and holds](../../../README.md#updates-and-troubleshooting)

Resolve the request through its original flow. Keep an explicit Git **Stop** in effect until the human authorizes a fresh audit.

After deciding explicitly to restart an abandoned request, stop all affected sessions and archive only the reported request file. Return to matching new runtime revisions and open a fresh request with a new ID.

### Presentation and continuation

Both hosts display managed questions as nonblocking text. `scripts/continue-timed-prompts.sh` reports pending requests and delivers expiry or split instructions once.

Native Force pass keeps its own auditor lifecycle. The launcher enables its Claude card with a five-minute idle timeout and disables Remote Control for that session.

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

Card dismissal leaves the auditor running. Interaction can reset the idle timer. The auditor override retains its existing eligibility and expiry checks.
