## TL;DR

Every blocked commit or push gets an explicit recovery, audit, wait, or stop action while preserving approval and retry limits.

## Problem

`preflight-commit-push.sh` uses the same denial output for failed reviews, broken prerequisites, pending decisions, and terminal stops.
A matching FAIL without a newer test receipt returns findings without preparing another audit.
Other exits can report a storage or ownership failure without a concrete recovery procedure.

Baseline: [preflight at 60bd2e5](https://github.com/boxlite-ai/agent-tooling/blob/60bd2e5a420967685beee33d7e8a645380a5cbfe/plugins/boxlite-agent-tooling/.agents/hooks/preflight-commit-push.sh).
Its `deny`, `deny_with_audit`, `validate_audit`, and final history guards own these exits.
[PR #232](https://github.com/boxlite-ai/agent-tooling/pull/232) added the receipt exception; [PR #241](https://github.com/boxlite-ai/agent-tooling/pull/241) moved attempt preparation into hooks.
Neither makes all denials actionable.

Example: an unchanged candidate has a FAIL for unavailable evidence; retrieving that evidence should permit another bounded review without a cosmetic code change.
This changes retry eligibility, not verdict acceptance or test-evidence requirements.

## Scope

- Cover every denial in the commit/push preflight, including request-preparation failures and oversized output; inventory early infrastructure errors too.
- Preserve Claude Code and Codex hook JSON, Git-hook propagation, stdin, exit behavior, candidate binding, history, and approval requirements.
- Automatically perform bounded deterministic recovery; otherwise instruct the parent to perform the specific recovery and resume without another permission question.
- Preserve reflection, pending human choices, explicit Stop, and exhausted audit budgets; never reset history to obtain another attempt.
- Keep receipt production, deadline-verdict policy, final-response/design gates, Git-hook installation, and unrelated working changes outside this change.
- Add no runtime dependency; preserve Bash 3.2 compatibility and report unverified host/OS combinations.

## Related work and lessons

| Evidence | Lesson and disposition |
| --- | --- |
| [AWS: retries and backoff](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) | Adapt one retry owner and bounded attempts; do not add nested recovery loops or network backoff to a local gate. |
| [backoff v5.0.3 retry implementation](https://github.com/cenkalti/backoff/blob/v5.0.3/retry.go) | Adapt distinct cancellation, permanent-error, and attempt-limit outcomes; do not add a Go dependency. |
| [client-go workqueue](https://pkg.go.dev/k8s.io/client-go/util/workqueue#TypedRateLimitingInterface) | Adapt explicit requeue versus completion and task deduplication; retain this repository's existing history owner. |
| [Retry Amplification, sections VII–VIII](https://arxiv.org/html/2608.25403v1) | Recent counterevidence against unconstrained retries; simulation does not establish an optimal local audit limit. Retain current limits. |
| [Agent Mesh, conclusion and limitations](https://arxiv.org/html/2608.26225v1) | Adapt task-identity and evidence attribution; the observational study does not prove a new recovery algorithm. |
| [Existing retry policy](https://github.com/boxlite-ai/agent-tooling/commit/3e584af) | Reuse reflection, the three-failure choice, and terminal history budgets instead of creating a second audit counter. |

Alternatives: keeping only messages preserves the dead ends; unconditional re-auditing violates stop semantics; a new scheduler duplicates lifecycle ownership.
Use an explicit action contract with the existing lifecycle instead.

Research log, 2026-11-05; known items named before searching: Bash exit status, jq argument encoding, client-go workqueue, cenkalti/backoff, AWS retry guidance.

| Source | Tool and exact queries | Result and stop |
| --- | --- | --- |
| arXiv | Web, 2: `site:arxiv.org retry policies bounded retries permanent failures idempotent`; `site:arxiv.org "Retry Amplification" "Agent Mesh" retry idempotence` | Opened both recent papers and their original HTML; retained limitations, not performance claims. |
| OpenAlex | Web, 3: `site:openalex.org retry fault tolerance idempotent failures`; `site:openalex.org "Reliable Actors with Retry Orchestration"`; `site:openalex.org "bounded retry"`; API, 1: `search=failure retry orchestration idempotent&per-page=5` | No useful web results; API returned HTTP 429. Limitation recorded, not treated as a negative literature result. |
| Semantic Scholar | Web, 1: `site:semanticscholar.org "Reliable Actors with Retry Orchestration"` | No useful result; no additional mechanism retained. |
| GitHub projects | Web, 2: `site:github.com cenkalti backoff Permanent WithMaxTries Retry`; `site:github.com/cenkalti/backoff "Retry" "Permanent"` | Known implementation found; opened pinned source. Other wrappers added no needed mechanism. |
| Go package registry | Web, 2: `site:pkg.go.dev k8s.io client-go util workqueue AddRateLimited Forget NumRequeues`; `site:pkg.go.dev "cenkalti/backoff" "Permanent"` | Opened first-party API references; pinned workqueue page failed, so no version-specific claim is based on it. |
| Web and specifications | Opened AWS retry guidance and [jq 1.7 invocation rules](https://jqlang.org/manual/v1.7/#invoking-jq); GNU Bash manual requests timed out | jq 1.7.1 and Bash 3.2 are the validation baseline; use installed Bash help for the unavailable manual sections. |
| Citation chase | Opened Agent Mesh reference [17], [Why Do Multi-Agent LLM Systems Fail?](https://arxiv.org/abs/2503.13657); searched `"2608.26225" "cites"` and `"2608.25403" "cites"` | Backward source opened; forward searches found no results. These searches do not prove absence of citations. |
| Repository/upstream | Read preflight, Git-hook consumers, attempt/history/decision code and tests; inspected #232, #241, #361, #362, and design #371 | #371 explicitly excludes retry scheduling; this needs its own design. Existing receipt-only recovery and abandoned open attempts informed the failure cases. |

The final three-query round (the two forward-citation queries plus OpenAlex `bounded retry`) added no mechanism; research stopped after source checks.
The two 2026 preprints are recent research, not proof of a best production algorithm; adapt their failure cautions only.
The libraries are implementation examples; current activity and two adoption signals were not established, so no project is claimed as SOTA.

## How it works

Replace reason-only denial calls with one explicit action formatter: action, reason, owner, next step, and completion condition.
Keep `permissionDecision: deny`; put the action in the existing reason field so both native hosts and Git-hook stderr receive it.
No undocumented top-level hook fields or executable command strings are added.
Each reason starts with `Next action: <audit|recover|reflect|wait|stop>`, followed by the responsible actor, required step, and success condition.
Missing action metadata is a formatting failure, not permission to run Git.

| Current exit family | Action and owner | Completion condition |
| --- | --- | --- |
| Missing, invalid, stale, mismatched, or matching FAIL dossier | `audit`: gate prepares a bound attempt; parent starts the appropriate existing auditor route | A valid result passes existing acceptance checks; prior findings remain reconciled. |
| Same-scope auditor still active | `wait`: parent waits for that auditor and its terminal lifecycle delivery; this excludes overlapping producers without asserting attempt ownership | Existing lifecycle closes the worker; no cancel, replacement, headless launch, or new launch instruction occurs while it remains active. |
| Reflection due | `reflect`: parent runs a discriminating check, records reflection, then requests review automatically | Existing reflection validator accepts the current history. |
| Human choice pending | `wait`: present the existing managed question and preserve its timer | Existing choice/fallback resolves; this change does not alter the choice window. |
| User selected Stop or budget exhausted | `stop`: parent reports unresolved findings and ends this retry chain | No task preparation, model launch, or automatic history reset. |
| Dossier/handoff consumption raced | `recover`: gate reselects and revalidates once using existing identity primitives | A fresh valid selection is safely consumed; an already-consumed PASS is never restored or reused. |
| Missing push ref-update binding | `recover`: parent retries through the existing Git pre-push route | Git supplies the real ref-update input; no synthetic reconstruction. |
| Version, launcher, origin, or missing session binding | `recover`: parent uses the supported reload/install/host-entry procedure and rechecks identity | Valid live host/process/session binding; unscoped calls cannot gain unlimited new retries. |
| API compatibility failure | `recover`: parent performs the checker-specific fix and reruns it | Compatibility checker passes; review cannot bypass this prerequisite. |
| Unreadable history, persistence failure, or audit preparation failure | `recover`: one bounded reread/reselection for transient failure, then preserve evidence and diagnose the named failing prerequisite | Valid history/ownership and writable required state; unverifiable history is never erased or guessed. |
| Oversized reason or task instruction | `recover`: preserve action and the bounded existing command-shortening procedure | A bounded equivalent invocation can be rendered; Stop remains Stop even when details are omitted. |

Automatic means the hook performs safe deterministic retries, or the parent follows the supplied recovery instruction without asking whether to continue.
It does not mean starting a second background controller inside every hook.
If recovery requires unavailable credentials, filesystem access, or a host restart, return the exact required intervention and wait; never report recovery as completed.

Recovery instructions name the failing resource and the verification to rerun; a generic instruction to inspect the environment is insufficient.
The gate performs at most one local reread/reselection per invocation, without recursion, and rechecks the original bindings before accepting its result.
If that recovery fails, return `wait` with the required intervention; do not tell the parent to retry unchanged conditions indefinitely.
For an install mismatch, identify both versions and the supported reload/install action; a required session restart becomes explicit host intervention.
For unreadable history, preserve the record and report its path and read/validation failure; restoration requires verified evidence, never a fresh empty history.
For a compatibility failure, retain the checker's diagnostic and required check; the parent fixes the evidenced problem before retrying Git.

Use structured checkpoint outcomes from the existing decision owner; do not infer Stop or waiting from human-readable error substrings.
The history lock remains the only owner of attempt preparation and the choice checkpoint.
No lock spans model execution or a human wait; no recursive preflight invocation or arbitrary command evaluation is introduced.
Remove `test_runs_after` as a retry-eligibility condition, while retaining receipts as audit evidence.

Race order: select identity → validate bindings/history → perform one identity-checked consume → reselect once on conflict → validate again.
A changed prompt or candidate invalidates the old action; a prepared attempt is not proof that a worker started.
The [active-task record](https://github.com/boxlite-ai/agent-tooling/blob/60bd2e5a420967685beee33d7e8a645380a5cbfe/plugins/boxlite-agent-tooling/.agents/hooks/auditor-control.sh#L87-L101) is a scope-level orchestration index, not an attempt-to-worker ownership proof.
Before canceling an attempt, preparing its replacement, rewriting the task link, or invoking the delegated headless runner, inspect the same-scope auditor state.
An active auditor blocks those transitions even when the candidate has changed; wait for its terminal lifecycle delivery before replacing the shared link.
Unknown or invalid active state requires explicit recovery and cannot authorize another launch.
Recheck that exclusion before returning a launch instruction; preparation alone remains deduplicated by history.
This ordering protects the [shared task link](https://github.com/boxlite-ai/agent-tooling/blob/60bd2e5a420967685beee33d7e8a645380a5cbfe/plugins/boxlite-agent-tooling/.agents/lib/commit-push-stop.sh#L14-L27) from an old worker's delayed Stop.
Do not infer that a reported host completion has already finished hook teardown.
If implementation cannot preserve this ordering, add an explicit generation-bound claim before permitting replacement.
Preparation deduplication is enforced by history; waiting for a native task also requires the parent to follow the host-specific instruction.
Do not claim that a hook prevents an independently issued native Agent call; verify cooperative parent behavior separately from hook output.

Intended changes: preflight action handling, its cohesive helper/prompt if needed, checkpoint result adapter, focused tests, architecture and hook documentation.
Estimate 200–400 production lines; measure the actual diff before any PR operation.
No release or PR publication is included in this implementation request.

## Validation

Planned; implementation and behavioral tests have not run for this design.

| Claim/risk | Check | Expected result |
| --- | --- | --- |
| All exits are actionable | Exercise every inventory row through the public preflight, including early failures and oversized payloads | Deny JSON or the existing fail-closed exit plus a concrete action, owner, and completion condition. |
| Same FAIL can recover | Keep candidate and receipt directory unchanged; retry a closed FAIL with valid history | New bound audit request, old finding IDs retained; no Git approval yet. |
| Request deduplication | Interleave preparation, active worker, candidate replacement, repeated invocation, terminal delivery, and prompt change; cover native and delegated headless paths | Active scope produces `wait`; no cancel, link replacement, or model launch precedes teardown, and a delayed old Stop cannot close a replacement attempt. |
| Native task reuse | Exercise the returned action through a live supported parent/worker route | Parent waits for the existing task; report unavailable routes instead of inferring behavior from fixture output. |
| Terminal stops | Replay user Stop and exhausted histories on both hosts and headless producer | No new attempt or model execution; explicit stop action survives oversized output. |
| Automatic recovery | Inject a recoverable selection race; separately inject persistent storage, version, and binding failures | Transient case revalidates and completes once; persistent cases give the exact recovery procedure without weakening guards. |
| No destructive reset | Use malformed JSON, checksum mismatch, symlink, FIFO, directory, stale generation, and unreadable history | Preserve evidence and limits; never fabricate a clean history or PASS. |
| Host contract | Test Claude/Codex reason delivery, Git stderr propagation, stdin preservation, exit codes, and unscoped invocation | Existing host decisions remain compatible; no unbounded legacy retry path. |

Before the first production edit, add focused tests and run them against the captured pre-change production baseline.
For each defect claim, fully revert every production change in isolated scratch, leave the tests, and observe the intended assertion fail.
Restore the complete implementation and rerun; setup or compilation failures do not count as defect proof.
Keep pre-existing unrelated working changes in that baseline; never revert the shared checkout.

Run focused preflight, attempt, history, decision, and Git-hook consumer suites; Bash syntax; ShellCheck; all plugin suites; guidance consistency; `make test:writing test:parity test:architecture`.
Exercise supported host routes and report macOS/Linux/Windows and live-host gaps separately; fixture success does not establish live agent compliance.
