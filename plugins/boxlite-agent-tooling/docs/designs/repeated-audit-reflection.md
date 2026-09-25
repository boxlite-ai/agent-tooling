## TL;DR

Every audit rerun must reconcile prior findings and explain earlier misses; two unsuccessful attempts require evidence-backed reflection from the agent and auditor before continuing.

## Proposal and example

Status: implemented locally; release and consumer adoption remain separate. Applies to verdict and commit/push audits. **History reconciliation starts on the first rerun; deeper reflection starts after two distinct unsuccessful attempts.**

Illustrative example:

| Run | Finding | Required accounting |
| --- | --- | --- |
| 1 | F1: publication lacks a lock. | Record the violated invariant and closure check. |
| 2 | F1 fixed; F2: cleanup leaks a worker. | Close F1 with evidence. If F2 existed in run 1, label it an earlier audit miss and explain the skipped lifecycle check. |
| 3 | Auditor proposes removing the lock. | Reconcile the conflict with F1's closure evidence before requesting a reversal. |

A real regression may reopen F1 with new evidence. Merely restating F1 under a new title cannot create another issue.

The agent writes a concise diagnostic artifact: observed facts, failed assumptions, revised decisions, and verification. Depth is assessed through these outputs; prose length and elapsed thinking time grant no credit.

## Problem

The current verdict path carries one prior dossier and asks for another correction. Neither audit contract requires stable finding identities, explains late discoveries, or reconciles conflicting advice. A cycle can therefore reflect failures in the auditor as well as the implementation.

## Related work and lessons

Repository comparisons use inspected revision `15819052960ad81013bd0a524cef054c79af8576`.

| Source | Observed approach and proposed use |
| --- | --- |
| [Verdict retry, lines 1972–1993](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/hooks/preflight-verdict-check.sh#L1972-L1993); [prior snapshot, lines 750–776](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/hooks/run-verdict-audit.sh#L750-L776) | Retains a FAIL and supplies one prior dossier. Preserve retry deduplication; add complete bounded cycle history. |
| [Commit/push, lines 706–717](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/hooks/preflight-commit-push.sh#L706-L717) | Findings block the operation. Apply the same reflection policy through a gate-specific adapter. |
| [Existing REFLECT contract, lines 53–88](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/skills/adversarial-iteration/SKILL.md#L53-L88) | Links violated invariants, assumptions, missed checks, and repeated occurrences. Adapt these questions to cross-attempt diagnosis; leave its broader review orchestration outside this change. |
| [Reviewer adapter, lines 112–124](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/skills/adversarial-iteration/references/reviewer-receipt-adapter.md#L112-L124); [ledger, lines 17–26](https://github.com/boxlite-ai/agent-tooling/blob/15819052960ad81013bd0a524cef054c79af8576/plugins/boxlite-agent-tooling/.agents/skills/adversarial-iteration/references/iteration-ledger.md#L17-L26) | Reuses finding IDs, records introduction evidence, and retains original scope plus fix deltas. Adopt these contracts without importing the full adversarial workflow. |
| [Reflexion, abstract](https://arxiv.org/abs/2303.11366v4) | Carries textual feedback into subsequent trials. Adopt persistent feedback; its benchmark results do not establish this gate's reliability. |
| [Google SRE, Concrete action items and Repeating incidents](https://sre.google/workbook/postmortem-culture/) | Requires measurable prevention and revisits ineffective prior actions. Adapt this into executable checks and explicit explanations of failed fixes. |
| [Claude Stop control](https://code.claude.com/docs/en/hooks#stop-decision-control); [Codex Stop handler and precedence test](https://github.com/openai/codex/blob/c7c824dce4da186e5142af5d9a1587ae553efe46/codex-rs/hooks/src/events/stop.rs#L295-L305) | `continue:false` terminates the turn with a visible reason. Use this for exhausted Stop audits; another blocking continuation would itself create a loop. Git operations remain denied. |

## Trigger and lifecycle

A cycle is scoped to canonical worktree, host session, prompt epoch, branch, and gate (`verdict`, `commit`, or `push`). HEAD, tree, answer, and command hashes bind attempts, not the cycle: ordinary corrections must retain history.

| Event | Required behavior |
| --- | --- |
| First completed FAIL or runner ERROR | Record evidence; the next audit must reconcile this history. |
| Second distinct unsuccessful attempt | Mark reflection required; return the history reference and reflection instructions. |
| Repeated notification or reread of the same attempt | Return the existing decision; never increment or launch another auditor. |
| Missing, incomplete, or stale reflection | Block another audit launch and identify the missing requirement. |
| Complete current reflection | Permit the next audit with immutable history and reflection snapshots. |
| Further unsuccessful attempt | Preserve findings and decisions; update reflection for agent mistakes and auditor misses. |
| Repeated proposal or conflicting reversal without new evidence | Stop blind reruns; require a targeted check that resolves the disagreement. |
| Accepted PASS | Close the cycle. |
| New real prompt, branch change, cancellation, or explicit human override | Revoke old authority; retain diagnostic history without injecting old findings into unrelated work. |

FAIL means a validated auditor finding. ERROR means the runner could not produce a valid result; it is not evidence of defective implementation. Intentional cancellation, stale results, advisories, and IN_PROGRESS never increment failures. IN_PROGRESS does not erase active history.

Internal hook continuations keep the current epoch. Genuine new requests start a new cycle under existing cancellation semantics; cross-request learning is outside this version. Standalone callers must supply a stable session scope to receive this guarantee; unscoped invocations retain existing single-run behavior.

## Auditor continuity on every rerun

Each auditor receives the original scope and rules, all prior findings and closure evidence, review coverage, and changes since the preceding attempt. Review existing findings first, then changed behavior and affected contracts; retain the ability to expose a genuine overlooked defect.

| Result | Required evidence |
| --- | --- |
| Existing finding | Reuse its stable ID and mark `open`, `resolved`, `retracted`, or `not_assessed`; explain the disposition. |
| Fix introduced a defect | Identify the introducing change and failed invariant. |
| Previously present but missed | Cite the prior snapshot; explain the earlier coverage or reasoning gap and the additional audit check now needed. |
| Resolved finding reopened | Reuse its ID; show a regression, changed dependency/contract, or counterexample that invalidates the earlier closure evidence. |
| Prior advice reversed | Cite both decisions and a discriminating check; justify which invariant requires the change. |
| Introduction unknown | State the missing evidence; never blame the latest fix without proof. |

Every finding carries a specific invariant, affected behavior, evidence, and closure criterion. Allocate its ID once; matching uses the invariant and behavior, not wording or line numbers. Reclassification preserves provenance. Criteria changes require evidence and an explicit reason.

Prior judgments can be wrong. Real missed defects still block; the auditor must acknowledge the miss and improve its review coverage. Require coverage accounting from the first audit, including unread areas, and snapshot the evidence needed to compare attempts. Hashes alone cannot prove prior presence.

PASS requires every prior open finding resolved or explicitly retracted, no unresolved material finding, and coverage of required scope. `not_assessed` cannot disappear into success. Evidence for unchanged resolved findings may be reused; changed dependencies invalidate that reuse.

An A → B → A recommendation cycle, or an unchanged repeated correction with no new evidence, triggers reconciliation immediately. The agent continues targeted investigation but does not apply another reversal or launch an unchanged full audit. If evidence cannot resolve the conflict, report the exact blocker.

## Required reflection

The agent prepares its diagnosis before corrective work and attaches check results before another audit. The auditor records its own omissions and inconsistent judgments in its dossier; the parent cannot invent this account on its behalf.

| Field | What constitutes useful evidence |
| --- | --- |
| Attempt comparison | Every failure ID, observed signal, intervening change, and remaining/new finding. No failure may silently disappear. |
| Causal diagnosis | Violated invariant, unsupported assumption, and why the earlier correction or audit failed. Separate implementation, verification, audit, and infrastructure causes. |
| Uncertainty | Evidence for a shared pattern, or an explicit statement that failures have different causes. Unknown causes require a discriminating investigation step. |
| Revised approach | A concrete change in method, relevant alternatives, and why the new approach addresses the observed causes. |
| Prevention and execution | Smallest relevant executable check, expected signal, actual result, and the revision or artifact checked. Repeated defect classes require positive and negative cases. |

A disputed audit finding requires a resolving source or counterexample and independent adjudication. Generic promises such as “be more careful” do not satisfy the contract. Checks are never executed automatically from text supplied in a reflection.

The next auditor verifies reconciliation, causal support, changed review coverage, and execution of the promised checks. Missing follow-through creates a specific finding. The gate checks required records and bindings; evidence quality remains an independent auditor judgment.

## Implementation boundary

Keep reusable code under `plugins/boxlite-agent-tooling/`:

- `.agents/lib/audit-reflection.sh`: one facade for preparation, recording, status, and reflection submission; owns cycle state, attempt identity, validation, snapshots, and transitions.
- `scripts/audit-reflection.sh`: thin CLI for submitting a reflection and inspecting required work through that facade.
- `.agents/prompts/audit-reflection.md`: runtime-loaded instructions; both auditor specifications consume the same contract.
- Existing verdict and commit/push gates and producers: adapters preserving their current JSON, stderr, and exit conventions.

`prepare` reserves an attempt ID before producer execution and returns immutable inputs. `record` idempotently accepts its terminal outcome or a reflection submission. The gate records FAIL only after existing dossier binding checks; runner/setup failures use explicit ERROR records.

Use the verdict generation as its attempt identity. Commit/push needs a new request ID shared across native/headless execution and Git-hook handoff. A dossier hash alone cannot identify separate runs. Preserve pre-push stdin authority and commit receipt bindings.

Store an atomic manifest, stable finding registry, and immutable attempt artifacts in gitignored session state. Allocate IDs from first accepted occurrence and retain them across runs. Bind scope/rules, coverage, snapshots, deltas, dispositions, outcome, and reflection; never overwrite earlier judgments.

Extend both strict dossier contracts with `history_review`: history hash, finding dispositions, introduction/reopening evidence, coverage, and auditor corrections. Require it on reruns. Add `reflection_review` when triggered: reflection hash, assessment, and evidence references. Required sections and ordinary proof must agree before PASS.

Before launch, require complete history inputs and any due reflection submission. At result acceptance, require the matching history/reflection assessments. Completion shortcuts, cached PASS, and receipts cannot bypass these requirements. IN_PROGRESS and human override retain their semantics; direct producers use the same preparation boundary.

**Enforcement limit:** gate state enforces submission and freshness before audited retries; the existing auditor judges substance afterward. Reflecting before arbitrary shell/editor writes remains agent guidance. This design does not claim universal interception of edits or trustworthy private thought inspection.

## State safety and stopping conditions

- Reuse bounded regular-file reads and atomic publication from `verdict-audit-state.sh`. One cycle lock owns transitions; acquire after existing gate locks, never in reverse order, and release before model execution.
- Revalidate epoch, attempt, input hashes, and selected file identity before accepting results. Concurrent duplicate delivery records one outcome; revoked or replaced attempts cannot release a gate.
- Budget: eight unsuccessful attempts and sixteen total attempts, 64 KiB per dossier, 8 KiB per reflection, 1 MiB total cycle evidence including scoped snapshots. Missing comparison evidence blocks the affected judgment; never trim history to obtain PASS.
- At the budget limit or with missing/corrupt evidence, stop automatic retries and report incomplete verification with the exact recovery need. Successful state repair may resume; exhaustion requires human direction. No automatic PASS or newly invented override.
- Exhausted Stop audits return `continue:false` with an explicit INCOMPLETE reason; they cannot trigger another summary or audit continuation. Exhausted Git audits keep the operation denied. Neither path records PASS.
- Keep four closed cycles per context within its byte bound and four retired context files per session. Remove superseded auditor inputs and retired artifacts by checked identity. A real prompt change revokes old contexts; current-epoch history is never evicted.
- Reflection-only failures count toward the budget. Existing explicit override remains visible and does not record success. Runtime history stays local; no automatic memory, issue, or public publication.

## Alternatives and trade-offs

| Option | Decision |
| --- | --- |
| Add only “reflect deeply” to the retry prompt | Insufficient: no retained history, freshness, or verified follow-through. |
| Trigger after every failure | Adds diagnosis cost to routine corrections; use two distinct failures initially. |
| Match repeated finding text | Reuse stable invariant-based IDs and evidence-backed dispositions; wording changes cannot manufacture progress. |
| Prohibit new findings after the first audit | Would hide genuine missed defects; accept them with provenance and auditor accountability. |
| Separate reflection reviewer before every fix | Adds another model and failure loop; use the existing independent auditor. |
| Block all edits until reflection approval | Much broader tool policy with shell gaps; enforce the audited retry boundary and state its limits. |

## Validation and delivery

Decisive tests: second failure blocks launch without reflection; duplicates count once; stale/incomplete reflection blocks. Reworded F1 retains its ID; omitted dispositions block PASS; reopening needs evidence; a real regression reopens; an old missed defect requires auditor correction; conflicting reversals trigger reconciliation.

Also cover false attribution of a defect to the latest fix, scope drift, ERROR versus FAIL, new epochs, concurrency/cancellation, unsafe snapshots, exhaustion, summary shortcuts, direct producers, commit receipts, and pre-push inputs. Use deterministic barriers.

Use scripted producers for state transitions and curated good/bad reflection cases for semantic evaluation. Test evidence coverage and decisions rather than exact prompt prose. Native and headless smoke runs on Claude/Codex are needed before claiming host behavior; Copilot remains unverified.

For implementation, observe reproducer failures against fully reverted production code, then passes with each fix restored. Run focused suites, shell syntax/lint, architecture and host parity, then broader plugin checks as required by shell-engineering guidance.

Delivery uses sequential native PR dependencies; sizes include tests and docs against the immediately preceding branch:

| Slice | Acceptance | Changed lines |
| --- | --- | --- |
| 1. Design | Publish the specification and research. | 156 |
| 2. Cycle history | Deduplicate outcomes and preserve snapshots. | 220 |
| 3. Finding registry | Validate stable identities, dispositions, provenance, and conflicts. | 181 |
| 4. Reflection contract | Reject missing/stale submissions; assess auditor omissions. | 169 |
| 5. Gate adapter | Bind immutable inputs and repeated result delivery. | 160 |
| 6. Shared contracts | Expose the native CLI and bounded auditor instructions. | 172 |
| 7. Verdict integration | Enforce reflection and terminate exhausted Stop loops. | 301 |
| 8. Commit/push integration | Reconcile native/headless reviews and exact push bindings. | 275 |
| 9. Lifecycle safety | Bound retention, reject revoked epochs, protect receipt shortcuts. | 200–230 |

Track acceptance and PR links in [issue #123](https://github.com/boxlite-ai/agent-tooling/issues/123). All slices stay below 400 changed lines. Local validation does not establish release, consumer adoption, or live model behavior.
