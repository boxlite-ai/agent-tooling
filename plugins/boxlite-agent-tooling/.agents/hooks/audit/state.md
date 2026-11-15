# Audit and gate state

## TL;DR

Audit records bind evidence to the current action. Prompt, Git, and PR records track the corresponding authority.

See [audit architecture](architecture.md) and [system boundaries](../../../ARCHITECTURE.md#gate-to-state). Paths in code spans are relative to the plugin root.

## State files

All `.agents/state/` artifacts are ignored and session-scoped where checkouts can be shared; worktree Git records are noted separately.

| Owner | Responsibility |
| --- | --- |
| `scripts/audit-reflection.sh`, `.agents/lib/audit-reflection.sh`, `.agents/lib/audit-reflection.jq` | Bounded serialized transitions, immutable bindings, deduplication, atomic regular-file writes. |
| `.agents/lib/audit-reconciliation.jq` | Finding IDs/dispositions/provenance/coverage/reopening; reject unresolved PASS. |
| `.agents/lib/audit-loop.jq` | Pure bounded progress classification; normalized history/design adapters, without action authority. |
| `.agents/lib/audit-reflection-contract.jq` | After two failures require complete current reflection; independent sufficient assessment for PASS; freeze active reflection. |
| `.agents/lib/audit-loop.jq` | Reduce failed attempts to rounds and classify the loop: converging, stalled, churning, infra, or none. |
| `scripts/audit-reflection-gate.sh`, `.agents/lib/audit-reflection-gate.sh` | Snapshot evidence, bind launch/acceptance, check epochs, reconcile dossiers. |
| `.agents/prompts/audit/audit-reflection.md`, `.agents/prompts/audit/git-audit-history.md` | Shared reconciliation/native history procedure. |
| `.agents/lib/git-audit-decision.sh` | Human checkpoint for a non-converging loop from its third failure, through timed requests, preserving original failures. |

### Validation and deadlines

`scripts/validate-audit-dossier.sh` reads verdict/commit/push plus immutable history (`-` when absent) and dossier/stdin without writes, locks, or approval.

- Reuse verdict normalization, `.agents/lib/audit-dossier.jq`, record-request builder, and pure record transition; report missing/unexpected/duplicate coverage keys.
- Tasks load `.agents/prompts/audit/dossier-validation.md` with JSON-encoded validator paths; correct candidates before delivery; read-only hosts return the same validated JSON.
- Validation reports `scope:history` for captured input or `scope:shape` for shape; neither replaces live binding/freshness/lease/publication acceptance.
- Headless prompts preview four changed paths within 6 KiB; full sanitized diff stays readable; design agents use their recorder.
- The runner suite measures the complete composed prompt, including metadata, deadline rules, and validation instructions; formatting changes consume this same budget.

Runtime derives `outcome.deadline_review = {deadline, recorded_at}` only after captured `attempt.input.deadline`; auditor-supplied markers reject.

| Acceptance | Deadline qualification |
| --- | --- |
| Unread coverage / unchecked reflection | Qualified PASS may retain both with advisories. |
| Unresolved findings / insufficient reflection | Still block; expiry cannot resolve evidence. |
| Known unverified verdict claim | Keep `proof.status: blocked` and deadline reason. |
| Replay | Persist qualification before cleanup, reuse first marker; never rewrite old FAILs. |

Design recording uses matching task/content predecessor metadata.

### Progress diagnostics

History `inspect` and design status return `recovery` diagnostics from the same classifier.
The existing reflection, stop, and permission rules remain authoritative.

| Latest rounds | Pattern | Meaning |
| --- | --- | --- |
| Fewer findings between the last two FAILs | `converging` | Blocking count decreased. |
| Same or greater count, overlapping IDs | `stalled` | A blocking finding repeats. |
| Same or greater count, disjoint IDs | `churning` | New findings replaced previous ones. |
| Two consecutive ERRORs | `infra` | The runner failed twice. |
| First FAIL, one ERROR, IN_PROGRESS, canceled, PASS, override | `initial`, `error`, `partial`, `canceled`, `complete`, `overridden` | No two-FAIL comparison applies. |

Example: FAIL(F1), ERROR, FAIL(F1) is `stalled`; FAIL(F1), ERROR, ERROR is `infra`, retaining F1's severity.
Two ERRORs still require the existing reflection; `infra` grants no continuation.
Pending attempts appear separately as `pending:true`; progress compares completed outcomes.

- `blocking_count` and `critical_ids` describe the latest reconstructed findings, including findings retained through ERROR or cancellation.
- `compared_failures` counts up to two FAILs; `history_complete` describes reconstruction, never review coverage or permission.
- Canonical views contain at most sixteen rounds and 144 unique IDs per round, allowing 128 registry entries plus sixteen opaque gaps; malformed views reject.
- New history dossiers require explicit `critical` or `high`; absent legacy severity defaults to critical and cannot downgrade an open critical finding.
- Accepted dispositions close findings; a justified reopening starts a new severity assessment.
- Opaque legacy FAILs remain critical reconstruction gaps; truncated or unavailable design rounds set `history_complete:false`.
- Design identities are exact finding lines; only `high:` prefixes denote high severity, and design worker startup ERRORs are outside this progress record.

### History acceptance

Context: `repo_root`, `session`, `epoch`, `branch`, `gate`; limits: eight failures, sixteen attempts, 10 MiB, plus 512 KiB reserved preparation capacity.

- `.agents/lib/git-audit-decision.sh` pauses a non-converging commit/push loop from its third FAIL/ERROR round; five-minute **Reflect again** / **Stop** binds context/latest failure, defaulting to reflection.
- Preserve choices across canceled preparation/native-headless handoff; each further non-converging failure asks again; PASS closes the cycle.
- Check preparation under history → timed-request lock order, never across human/model waits; native/headless use the same guard.
- Terminal readiness uses `audit_reflection_ready` without demanding new reflection after PASS changes the history hash; Git still checks/consumes fresh bindings.
- Record outcomes once; replay differing only in advisories succeeds without replacing the first result; runner failure is ERROR, cancellation separate.
- Exhausted Stop returns `continue:false`/INCOMPLETE; Git remains denied; shortcuts/receipts cannot bypass unresolved history.

### History retention

- Keep four closed cycles/context, four retired contexts/session, latest immutable input/context; identity-checked cleanup preserves current-epoch evidence.
- Snapshots contain bounded transcripts, sanitized headless diffs, or immutable native Git trees; auditors read relevant chunks.
- IDs are `F1`–`F9999`; only new findings use `NEW`; dispositions/conflicts name registry IDs.
- Partition snapshot keys exactly once into `reviewed`/`unread`; reject missing/invented/duplicated keys, and unread PASS before qualified deadline.
- Inspection/preparation share capacity checks; exhausted completed cycles stop before launch while pending results may still record.

### Verdict records

- `last-verdict.json`: consumed turn dossier.
- `last-verdict.prev.json`: parked FAIL for fresh review.
- `last-verdict-index.json`: session-scoped checkpoint written after PASS consumption. Stores the generation, message ID, optional host turn ID, and optional native range from the accepted attempt.
- `verdict-decisions.log`: elapsed time, rung, outcome.
- `audit-diagnostics.jsonl`: bounded execution diagnostics, never approval.

The [index reader](../../../scripts/read-verdict-index.sh) returns an offset only for a valid checkpoint on the same transcript with bytes beyond it. Missing, malformed, stale, or unwritable state leaves verdict decisions independent of the checkpoint.

### Prompt state

- `verdict-last-uuid`: last judged message.
- `verdict-prompt-epoch`: current prompt epoch.
- `verdict-request-context.json`: origin epoch/Git binding managed by `.agents/lib/audit-request.sh`.
- `verdict-stop-message.jsonl`: Codex fallback transcript shape.

### Git and PR state

- `last-audit.json`: Git dossier.
- `last-audit-handoff.json`: auditor request.
- `commit-audit-receipt.json`: commit-msg approval spent by pre-push.
- `pr-review-request.json`: bound review request, acceptance time, and consumption.
- `pr-size-request.json`: diff/choice lifecycle; renewal archives use `<state>.expired-<request-id>.json`.

### Runtime state

- `auditor-control`: escalation/completion/grants/events.
- `last-api-failure.json`: error kind.
- `api-resume`: bounded resume/wake records.

### Verdict retry handoff

Requests bind origin epoch, claim checksum, branch, HEAD, full tree; human prompts rotate epoch and revoke grants.

- Preserve running work only while bounded context/Git binding remain valid; history can finish it, but only the original turn consumes approval.
- Later auditors may use unchanged completed dossiers as prior evidence with preserved freshness; later claims need new generations.
- Retry captures same-generation FAIL JSON/inode under leases; reconcile/validate replacement, then recheck captured identity/request before retiring it.
- No-clobber publication preserves competing files; revocation/final lease checks still cancel; unchanged-tree retries retain both history outcomes.
