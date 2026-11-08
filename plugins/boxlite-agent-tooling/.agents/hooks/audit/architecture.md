# Audit architecture

## TL;DR

Auditors produce bound dossiers. Gates validate those dossiers against the live action before granting authority.

See [runner usage](README.md), [state files](state.md), and the [system map](../../../ARCHITECTURE.md). Paths in code spans are relative to the plugin root.

## Audit producers

| Caller | Producer | Contract |
| --- | --- | --- |
| Stop, synchronously | `.agents/hooks/audit/run-verdict-audit.sh` | Load verdict skill into the current host's model CLI; publish turn dossier. |
| Git/CI/plain shell | `.agents/hooks/audit/run-commit-push-audit.sh` | `codex exec`, private writable scratch, read-only repository/evidence, hooks/user config disabled. |
| Native agent | `.claude/agents/` specs via `.agents/lib/subagent.sh` | Parent dispatches `Task` on Claude or `collaboration.spawn_agent` on Codex. |

Headless commit reconstruction uses captured index tree; push uses verified outgoing trees; verify reconstruction before tests and recheck tree/diff/subject before publication.

- On macOS and Linux, a controller sends TERM and KILL to its own audit group, even after the leader exits.
- On these platforms, unverified cleanup blocks accepting the auditor's dossier. Stop ends its diagnostic read even when a surviving process holds stderr open.
- Scratch owns `TMPDIR`; exclude generic temp/additional write roots; network permits design retrieval.
- Scratch `bin/mktemp` adapts default invocations only; prepend after shell initialization; explicit options/templates pass through.
- `commit-push-tests.md` requires candidate-bound receipts, complete native execution records, or safe reruns; sandbox denial needs another route or unchecked finding.
- Follow continuation IDs to terminal results; wrapper completion, prior summaries, transcript paths, and current-tree inference cannot certify execution.
- [Workflow proof rules](../../../guidance/workflow.md#test) distinguish existing defects, new contracts, and mixed changes; reuse alone is not a fix, and setup/compile failures do not reproduce defects.

### Provider selection

Manifests set `BOXLITE_HOOK_HOST`, replacing inherited identity; `.agents/lib/hook-host.sh` validates it before legacy single-root inference.

| Host | Routing |
| --- | --- |
| Known Claude/Codex | Use that provider only; explicit command overrides win. |
| Known-provider failure | Classifier falls back to regex; auditor failure blocks. |
| Generic | `unknown`; legacy availability remains Claude-first. |
| Both legacy roots | Ambiguous; compatibility aliases cannot override declared identity. |

`.agents/lib/codex-cli.sh` resolves `CODEX_BIN`, PATH, then desktop binary without choosing host.

- Classification runs read-only in scratch with hooks, shell tools, subagents, user config, and project instructions disabled; global instructions may load.
- Lookup and execution share bounded capture/deadline; `.agents/lib/audit-network.sh` reads trusted user proxy data, respecting inherited choices without evaluating repository/PAC text.
- `.agents/lib/audit-diagnostics.sh` retains bounded masked execution metadata/stderr; child failure overrides even a written PASS.
- Counts such as `60/60 tests passed` and `60 passed, 0 failed` trigger classification; independent evidence establishes proof.

## Timed subagents

Shared policy: `.agents/prompts/audit/deadline-policy.md`; advisor stays advice-only.

| Runtime state | Result |
| --- | --- |
| Deadline, confirmed blockers | FAIL. |
| Deadline, no confirmed blockers | Valid PASS, even with zero checks; unfinished work becomes explicit advisories. |
| Missing report, cancellation, crash, hard kill | Execution error; no automatic PASS. |
| Past deadline | Stop investigating; record and clean up owned tasks; block one record-less stop. |

`.agents/lib/subagent.sh` owns budgets, recording windows, and delivery; `.agents/lib/subagent-identity.sh` shares identity; `.agents/lib/commit-push-stop.sh` records Git stops.

| Auditor | Deadline source | Post-deadline operation |
| --- | --- | --- |
| Design/advisor | Content-bound task, default 900 seconds | `design-doc.sh verdict` / `advice`. |
| Commit/push | Attempt link, default 900 seconds | Write naming `dossier_path`; owned cleanup. |
| Native verdict | Immutable attempt initialized from live request | Bound dossier write/validation and owned cleanup. |
| Headless verdict | `VERDICT_AUDITOR_TIMEOUT`, default 180 seconds | Recording window; default hard stop at 240 seconds. |

Matching re-entry preserves deadlines; headless recording gets `min(60, budget)` seconds within the 3540-second ceiling; startup/cleanup add elapsed time.

- Claude explicitly grants four tools with `--allowedTools` because safe/print mode supplies no hook permissions or approver.
- Stream-json sends `.agents/prompts/subagent/timed-subagent.md` once at expiry, interrupts after 30 seconds only if undelivered, then stops at record-window expiry.
- Default: record 180s, interrupt 210s, stop 240s; delivered messages are never resent/interrupted; incomplete records deny; Win32 Perl lacks this record turn.
- Codex/custom commands receive absolute deadline/policy initially; Codex accepts no later input; tool-matcher tests exclude hosted-search bypasses.

### Native verdict initialization

`.agents/lib/verdict-audit-task.sh` initializes synchronously at start, with idempotent tool fallback requiring matching task/control ownership.

- Validate request, generation, epoch, Git binding; store host identity separately and link immutable history/dossier.
- Missing/revoked requests grant no deadline; old events cannot take over replacement tasks; cleanup compares ownership records.
- Stop records a valid result or ERROR; parent-consumed results survive cleanup/replay.

## Commit/push attempts

| Phase | Owner / behavior |
| --- | --- |
| Prepare | Preflight binds attempt/history; cancels differently bound open work; writes scoped task link with deadline and empty host identity. |
| Start | `SubagentStart` binds worker generation under control lock. |
| Stop | Matching worker records once; old events cannot close replacements. |
| Resume | Block once for missing dossier or pre-deadline `high: unchecked:` / legacy `unchecked:`; otherwise record dossier/ERROR. |
| Handoff | Headless cancels/prepares its own attempt only after checking unfinished same-scope workers. |

Native auditors do not prepare/record history themselves; deadline hooks enforce timing rather than prompt-only timers.

Every Git denial includes next action, owner, step, and completion condition in `permissionDecisionReason`.

The audit task and a FAIL's findings travel by claim check ([design #407](https://github.com/boxlite-ai/agent-tooling/issues/407)), keeping the reason under its 8,192-byte cap:

| Part | Behavior |
| --- | --- |
| Store | `.agents/lib/audit-task-file.sh` writes `.agents/state/audit-tasks/<sha256>.md` (mode 600) per request, refreshing its age; prunes files older than 5 hours; needs no session or attempt. |
| Pointer | The reason carries `AUDIT_TASK_FILE_JSON` (path, SHA-256, size) and a `scripts/read-audit-task.sh` command. |
| Read | The script prints only a regular, non-symlinked file of that exact size and hash; otherwise the auditor writes no dossier. |
| FAIL | The reason gives finding/advisory counts and the saved copy's path, since a relaunch replaces `last-audit.json`; the headless runner builds its own prompt. |

| Action | Parent responsibility |
| --- | --- |
| `audit` | Launch bound review, then retry; unchanged FAIL needs no cosmetic change/new receipt. |
| `recover` | Repair prerequisite and verify; unscoped FAIL returns through a real session-bound route. |
| `reflect` | Run discriminating check, submit validated reflection, retry. |
| `wait` | Finish worker/choice or repair unverifiable state; preserve history/links/timers. |
| `stop` | End retry chain; no prepare, launch, or history reset. |

- `audit-reflection.sh next-action` returns locked structured outcomes; legacy `checkpoint` retains stderr/exit 2.
- `inspect-scope` distinguishes prepared/active/pending-stop/unresolved ownership; preflight/headless check exclusion before replacement and launch.
- Allow one local reselection; persistent conflicts need intervention; consumed PASS never returns; changed candidates require new invocation.
- Native admission relies on a cooperative parent; arbitrary independent Agent calls are outside it.

## Commit/push review criteria

Both routes load [shared criteria](../../../.agents/prompts/audit/commit-push-criteria.md); missing/invalid delivery blocks dispatch; operation inputs remain untrusted.

- Apply scoped rules/design first; investigate bugs, performance, and maintainability by risk; verify findings and reconcile complete coverage even after blockers.
- Critical/high findings FAIL; low/nit stay advisory; deadline policy governs unfinished proof; entries require anchors and pass conditions within 1024 bytes.
- `google-code-review` loads attributed, pinned CC BY 3.0 guidance beneath repository contracts; Claude defaults to high effort, Codex retains its default.

Prompt tests establish delivery, not model compliance or recall.

## Evidence

### Auditor transcript

`boxlite-verdict-audit` owns discovery/proof/output; thin native specs and all runner routes load it explicitly; missing skill/discovery guide denies.

- Supply `parent_session_id`, `parent_host`, `audit_started_at`, repository/dossier binding; no transcript path or claim JSON required.
- Verify parent/repository/turn, then review only the selected turn. Look up older records for identity, specific claims, or required retry checks.
- File proof rechecks identity and the digests of used ranges. API proof rechecks complete ordered records and their content or immutable version.
- Native snapshots with a user boundary supply exact byte ranges to the auditor. A consumed PASS attempts to persist the session's last index as a discovery hint.
- Unresolved identity/completeness FAIL; native records use ≤64 KiB outputs without cumulative read cap, subject to deadline.

### Final-turn bookkeeping reader

`.agents/lib/verdict-audit-state.sh` decodes from transcript end to last real user message, at most 64 MiB, with a 15-second alarm.

Earlier history contributes only `source_sha256`; runner keeps/cleans a private bounded snapshot, with `-` meaning explicitly incomplete; bookkeeping never substitutes execution proof.

### Bookkeeping snapshot selection

After preview reduction, binary search retains the largest earliest-tool prefix fitting the cap, final LF included; claims stay whole or use existing fallback.

Monotonic fixed-preview growth supports logarithmic selection; byte/UTF-8 behavior remains unchanged; [checks/benchmark](../../../tests/snapshot_selection/README.md) cover the assumption.

### Stop gate to verdict check

After TL;DR, structure, and confirmation checks, `.agents/hooks/stop-gate.sh` executes `.agents/hooks/audit/preflight-verdict-check.sh` with unchanged payload, preserving output/status/signals; missing dependencies deny.

## Incomplete evidence

Failed/empty refresh preserves the failed snapshot; re-entry validates it before consuming evidence, so source loss cannot become `empty-allow`.

Initially absent/empty transcripts still contain nothing to judge.

## Test-run receipts

| Host result | Receipt |
| --- | --- |
| Direct signed 32-bit integral `exit_code` | Zero PASS, nonzero FAIL; explicit interruption records interrupted. |
| Non-null process/session ID | Pending, even with exit code; no completion receipt. |
| Claude successful result without code | Recognized string stdout/stderr and optional boolean interrupted/isImage; failure event handled separately. |
| Unknown envelope/fields, invalid code, background/output-only | No receipt; printed JSON/status cannot establish completion. |

Some native Codex output lacks exit metadata and stays unobserved; recorder remains silent with working-tree-bound receipts.

## Wake and auditor lifecycle

`.agents/lib/hook-wake.sh` accepts internal wakes only once; spent/copied wakes or extra human text rotate normal prompt authority.

- Interactive API resumes record budget before announcement; only async exit 2 wakes, at most three/session in ten minutes.
- Auditor wakes last 300 seconds after escalation or stop; foreground delivery may wait for stop.
- Closed escalations survive 3660 seconds for late stops; later session prompts retire them after expiry within the three-second lock.
- Claude completion gets two credits for 300 seconds (`agent-message` and `task-notification`), or one after a pre-stop hand-back.
- Claude Bash completions preserve the epoch when the [native module](../../../hooks/claude-prompt-origin.mjs) verifies their origin. A spent dispatch tag may appear in the synthetic transcript and model input.
- If the host skips the module or its classic callback, the shell hook revokes on Bash notices. A pasted notice also revokes.
- Replays, uncredited senders, and column-zero frame lines count as real prompts; prompt cancellation never signals workspace-selected PIDs.

## Stop gate decisions

After timed confirmations and writing checks, `.agents/hooks/audit/preflight-verdict-check.sh` logs these rung/outcome pairs. `architecture.test.sh` checks exact coverage.

| Rung | Outcome | Condition |
| --- | --- | --- |
| override | overridden-allow | Valid prompt-scoped user grant; log use. |
| history | exhausted-stop | Failure/attempt/capacity exhaustion; INCOMPLETE, no model launch. |
| extract | truncated-block | Unreadable/oversized final turn; independent FAIL required. |
| extract | blind-allow | Transcript exists, no assistant text after two seconds; unjudged. |
| extract | empty-allow | Initially absent/empty transcript. |
| cancellation | discard-generation | New prompt revoked generation. |
| dossier | discard-generation | Dossier generation differs. |
| dossier | discard-stale | Branch/HEAD/tree/age differs; fresh triage. |
| dossier | PASS-allow | Consume fresh matching PASS; human-only advisories. |
| dossier | discard-revoked | Consumption loses to revocation/replacement. |
| dossier | IN_PROGRESS-allow | Parent pauses/asks user; note deferred proof. |
| dossier | FAIL-block | Findings block; unchanged text reuses FAIL. |
| audit | inflight-allow | Session runner active; next turn end checks result. |
| race | stale-allow | Message already judged. |
| harness | noise-allow | Only harness/API-error text. |
| assertion | match-block | Whole-line completion/initial confirmation; audit without classifier. |
| runner | ERROR-block | Runner incomplete; safe metadata/diagnostic path. |
| triage | oversized-block | Classifier cap exceeded; file-backed audit. |
| triage | NO-allow | Model finds no trust-dependent conclusion; announce. |
| triage | YES-block | Model finds conclusion requiring proof; synchronous audit. |
| regex | none-allow | No classifier, no fallback match. |
| regex | match-block | No classifier, fallback assertion matched. |

Turn dossiers carry branch/HEAD/tree/generation, PASS/FAIL/IN_PROGRESS, findings, and optional advisories; Git dossiers use PASS/FAIL, with FAIL iff findings.
