## TL;DR

Retain audit findings across retries and require checked reflection after two failures.

## Problem and example

Audits can rediscover old defects or reverse earlier advice without accounting for prior decisions. Verdict and commit/push retries need shared history.

Example: run 1 finds missing lock F1; run 2 closes F1 but discovers an older cleanup leak F2. The auditor explains its missed check. Removing the lock later requires evidence against F1's closure.

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

## Contract

- Scope history by worktree, session, prompt epoch, branch, and gate. Bind code/command hashes to attempts so corrections retain history. New prompts revoke old authority; unscoped callers keep legacy behavior.
- Reconcile from the first retry. Count distinct FAIL/ERROR outcomes; duplicates are idempotent. ERROR describes runner failure, not a code defect. Cancellation, stale results, advisories, and IN_PROGRESS do not count.
- Preserve finding IDs, invariants, behaviors, and closure criteria. Disposition every open/not_assessed finding; justify reopened findings, reversed advice, and changed criteria with comparison evidence. Never suppress real defects to converge.
- Classify new findings as introduced, missed_earlier, or unknown. Earlier misses require the auditor's own coverage-gap explanation and performed review change. Unknown provenance must remain explicit; hashes alone cannot establish it.
- After two failures, require current reflection covering every failed ID: causal diagnosis, failed fixes, changed approach, auditor gaps, and executed checks with expected/observed results. Diagnose before correction; unresolved causes or disputes need a discriminating check.
- PASS requires complete coverage, resolved/retracted findings, and an independent sufficient reflection assessment when due. Another failure invalidates reflection. Guidance cannot inspect private thought or block arbitrary edits; auditors judge substance.

## Implementation and safety

The [state facade](../../.agents/lib/audit-reflection.sh) exposes `prepare`, `record`, `submit`, and `status` through [the CLI](../../scripts/audit-reflection.sh). [Gate adapters](../../.agents/lib/audit-reflection-gate.sh) preserve existing I/O, dossier, receipt, and pre-push bindings.

`prepare` reserves an attempt and freezes history/reflection inputs. `record` validates the bound dossier and reconciles findings. `submit` accepts reflection only between audits. Native and headless auditors share the [prompt](../../.agents/prompts/audit-reflection.md); completion shortcuts cannot bypass reconciliation.

- Serialize transitions under one lock, released before model execution. Reuse bounded regular-file reads and atomic writes; recheck epoch, input hashes, and file identity before acceptance. Never execute commands from reflection text.
- Limits: 8 FAIL/ERROR outcomes, 16 attempts, 64 KiB/dossier, 8 KiB/reflection, 1 MiB/cycle. Reflection failures count. Missing/corrupt evidence blocks; exhaustion requires human direction and reports INCOMPLETE, never PASS.
- Exhausted Stop audits use `continue:false`; Git operations remain denied. Existing explicit overrides stay visible and never fabricate PASS.
- Retain four closed cycles/context, four retired contexts/session, and only the latest immutable input/context. Identity-checked cleanup preserves active evidence. History remains local; no cross-request learning or automatic publication.

## Alternatives and validation

Prompt-only reminders lack persistent evidence. Reflecting after every failure adds routine cost; use two. Banning late findings hides defects. A separate reflection reviewer adds another failure loop; use the existing independent auditor.

Test duplicate delivery, missing/stale reflection, omitted findings/coverage, reopenings, earlier misses, reversals, false attribution, epochs, cancellation, unsafe snapshots, exhaustion, receipts, and summary shortcuts. Use deterministic barriers and fully reverted-production red/green checks for fixes.

Scripted producers verify contracts; real-model judgment and Claude/Codex smoke runs remain separate. Copilot is unverified. Run focused suites, architecture/host parity, shell checks, and broader plugin tests as applicable.

Delivery and acceptance: [issue #123](https://github.com/boxlite-ai/agent-tooling/issues/123), one combined PR. Release and consumer adoption remain pending.
