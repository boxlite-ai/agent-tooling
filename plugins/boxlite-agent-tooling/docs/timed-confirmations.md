# Human confirmations

## TL;DR

Human confirmations bind a response to a specific request, action, and deadline.

## Timed confirmations

`.agents/lib/timed-user-prompt.sh` and `scripts/timed-user-prompt.sh` serialize context-bound, random-ID, single-consumption requests without waiting under locks.

| Prefix | Human response | Five-minute fallback |
| --- | --- | --- |
| `pr-size-exception:` | Bypass limit / Split PR | Split. |
| `reviewed:` | Typed review acknowledgment | Keep draft/uncreated. |
| `design-decision:` | Redesign / Reflect again / Overrule | Keep edits blocked; matching explicit replies remain valid later. |
| `commit-audit-decision:`, `push-audit-decision:` | Reflect again (Recommended) / Stop | Reflect again; fresh audit still required. |

New/renewed requests receive 300 seconds; legacy 180-second requests keep their deadlines; retries never extend them.

### Response authority

| Choice | Authority |
| --- | --- |
| Size | CLI/native exact labels; legacy reasons remain readable; never authorize review. |
| Review | Bind checkout/branch/HEAD/session/request; timely reply consumed on successful publication; late answers reject. |
| Design | `.agents/hooks/design-decision-prompt.sh` accepts human first-line directives/correlated Codex replies, including late replies; CLI `respond` cannot relay them. |
| Git retry | Managed native or standalone prefix/request/choice; validate session/epoch/branch/HEAD/latest failure; no CLI relay/consume/renew. |

Codex design replies require the exact generated title/directives and one string-valued `questionItemId`/`question`/`answer` item; opaque host IDs authenticate nothing.

Malformed/mixed/stale/replayed/legacy-unbound answers retain ordinary cancellation; design writers recheck live content/history before mutation without consuming changed replies or serializing independent writers.

### Renewal

Explicit human instruction permits PR-size renewal after expiry/split; remeasure/show current diff first; ordinary requests cannot renew, nor can review/design requests.

Archive prior state/instruction/successor under lock, then atomically replace with fresh ID/deadline and empty response/question ID; old answers cannot affect the successor.

Unsafe paths/collisions deny; replacement is the commit point; earlier failure retains old authority and archive, later lost results retain the successor.

CLI human-text relays trust the agent rather than authenticating identity.

### Presentation and continuation

Old uncorrelated cards require fresh questions or typed directives.

Questions are agent-opened through `.agents/prompts/questions/timed-user-prompt.md`; request creation starts deadlines; templates receive JSON-escaped values while code owns transitions.

`scripts/continue-timed-prompts.sh` delivers pending/expiry/split continuations once; the agent waits/splits; Git expiry permits reflection, fixes/tests, and fresh review, never PASS; timely Stop persists.

Size templates: `.agents/prompts/pr/pr-size-exception.md`, `.agents/prompts/pr/pr-size-expired.md`, `.agents/prompts/pr/pr-size-declined.md`.

`scripts/claude-with-timed-prompts.sh` loads the plugin, enables 300-second idle dismissal, and disables startup/in-session Remote Control without editing settings files.

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

| Session | Route |
| --- | --- |
| Supported local interactive Claude | Require launcher marker `BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1` and bounded timeout; exact generated `AskUserQuestion`. |
| Remote Control, custom settings, print/background/cloud | Preserve arguments, clear inherited marker, ask nonblocking plain text. |
| Missing marker/timeout or overriding managed policy | Plain-text fallback; custom `--settings '{}'` can select it. |
| Codex | Async input. |

The marker is configuration, not authority; hooks bind tool ID/deadline, reject prefilled/`afkTimeoutMs` answers, and write valid review markers.

- Interaction resets idle timeout only; busy UI, Remote Control, screen-reader, or terminal focus can delay dismissal, never extend authorization.
- Outside this lifecycle, ask once without waiting; API skip/redesign/watch escalation retain safe defaults until explicit reply.
- Auditor cards require native availability; dismissal keeps waiting without reopening; other sessions receive typed status.
