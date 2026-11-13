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

Only explicit human instruction renews an expired review request or an expired or declined size request.
Show the current diff and description before renewing review; remeasure the diff before renewing size.

For example, expired review R1 becomes pending R2; R1's late reply cannot approve R2.

```sh
bash <plugin-root>/scripts/timed-user-prompt.sh renew STATE REQUEST_ID 'VERBATIM_HUMAN_INSTRUCTION'
```

The state machine archives the old record and instruction under lock, then publishes a fresh ID and 300-second deadline. A reply to the archived ID cannot answer the new request.

Renewal preserves the target binding and grants no approval; the replacement requires a fresh timely reply.
Ordinary retries retain the pending ID and deadline; pending, accepted, and consumed requests cannot be renewed.
The publishing gate checks the current target and description before consuming acceptance.

After a write error, inspect the active request and `STATE.expired-REQUEST_ID.json` before retrying.
An archive with the original active ID means publication failed; an active ID matching `successor_id` means the replacement was published.
Keep both records intact; neither outcome grants approval, and an existing archive blocks another renewal of its original ID.

### Unsupported records

A request record in another format blocks at the reported path and keeps its bytes. To restart it, stop the affected sessions, archive only that file, and open a fresh request. An explicit Git **Stop** stays in effect until the human authorizes a fresh audit.

### Presentation and continuation

Both hosts display managed questions as nonblocking text. `scripts/continue-timed-prompts.sh` reports pending requests and delivers expiry or split instructions once.

Native Force pass keeps its own auditor lifecycle. The launcher enables its Claude card with a five-minute idle timeout and disables Remote Control for that session.

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

Card dismissal leaves the auditor running. Interaction can reset the idle timer. The auditor override keeps its eligibility and expiry checks.
