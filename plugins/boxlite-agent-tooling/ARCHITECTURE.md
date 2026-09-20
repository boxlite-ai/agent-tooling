# Architecture

- One plugin, three hosts: Claude Code, Codex, Copilot.
- Fail-closed gates around the moments a coding agent acts on a repository: the end of a turn, a commit, a push, a pull request.
- A gate never produces the verdict it checks. An independent auditor writes a dossier under `.agents/state/`, bound to what it judged, and the gate reads it back.
- A turn dossier whose binding no longer matches is discarded, never blocked on; a commit or push dossier that no longer matches denies until a fresh audit.
- Humans are not gated: the Git gates bind only when a harness variable such as `CLAUDECODE` is in the environment.
- This file is a map, not an atlas: entry points, boundaries, invariants, vocabulary. How a script works is in its own header comment.
- `architecture.test.sh` fails when the map names a script, state file, decision or term the code no longer has.

## Entry points

Host hook events, wired for both hosts in `hooks/hooks.json` and
`hooks/codex-hooks.json` unless noted. One script per row.

| A person or host does this | Event | Script | What they see |
| --- | --- | --- | --- |
| Submits a prompt | `UserPromptSubmit` | `.agents/hooks/cancel-verdict-audit.sh` | Nothing. An audit still running for the abandoned turn is revoked. |
| Submits a prompt in a consumer that opted in | `UserPromptSubmit` | `.agents/hooks/rule-recency.sh` | One compact reply-shape reminder. Not wired by the plugin manifests. |
| Starts or finishes an auditor subagent | `SubagentStart`, `SubagentStop` | `.agents/hooks/auditor-control.sh` | After 30 seconds, one Keep waiting or Force pass card on Claude Code, a typed status elsewhere. |
| Runs `git commit` or `git push` from the agent's shell | `PreToolUse` | `.agents/hooks/preflight-commit-push.sh` | A denial naming the route to `commit-push-auditor`, or the command runs on a fresh PASS. Delegates to the Git gates when they are installed. |
| Runs `gh pr create`, `gh pr edit` or `gh pr ready` | `PreToolUse` | `.agents/hooks/preflight-pr-review.sh` | A denial naming the required description shape, then a request for the human's typed `reviewed:` acknowledgment. |
| Completes a remote write | `PostToolUse` | `.agents/hooks/post-remote-write-watch.sh` | Context telling this session how to attach to the pr-watch stream. |
| Ends a turn | `Stop` | `.agents/hooks/stop-gate.sh` | Nothing on PASS, unless the last reply runs over 60 words of prose: then one request using the reply-summary prompt template. The findings on FAIL. See the decision table below. |
| Loses a turn to an API error, Claude Code only | `StopFailure` | `.agents/hooks/record-api-failure.sh` | Nothing. `scripts/resume-on-network-error.sh` reads the record to decide whether to restart. |
| Loses a turn to a dropped stream or an overloaded API in an interactive session, Claude Code only | `StopFailure`, wired with `asyncRewake` | `.agents/hooks/resume-after-api-failure.sh` | The turn resumes where it stopped, at most three times per session in ten minutes. |

Git gates. They run for any process and bind only when `CLAUDECODE`, `CODEX_SANDBOX`
or `AGENT_GATED=1` is in the environment.

| A person or agent does this | Gate | What happens |
| --- | --- | --- |
| Runs `git commit` | `.githooks/pre-commit` | Verifies the installation with `scripts/verify-installation.sh` and the guidance block with `scripts/sync-guidance.sh` in check mode, runs the chained framework hook, then checks the staged index against the audit. |
| The commit message is final | `.githooks/commit-msg` | Binds the audited subject, then publishes a receipt naming the commit by parent and tree. |
| Runs `git push` | `.githooks/pre-push` | The same installation and guidance checks; spends the receipt to skip re-auditing an identical commit, otherwise audits the pushed range; arms `.agents/watch/pr-watch.sh`. |
| Checks out, merges or rewrites | `.githooks/post-checkout`, `.githooks/post-merge`, `.githooks/post-rewrite` | `scripts/sync-installation.sh`, then the chained hook. |

Producers for callers with no agent runtime.

| Who needs a verdict | Producer | What it does |
| --- | --- | --- |
| The Stop gate, synchronously | `.agents/hooks/run-verdict-audit.sh` | Feeds `.claude/agents/verdict-auditor.md` to a model CLI with Read, Bash and Write, which writes the turn's dossier. |
| A Git gate, CI or a plain shell | `.agents/hooks/run-commit-push-audit.sh` | Runs `codex exec` read-only with hooks disabled and writes the same `last-audit.json` the `commit-push-auditor` subagent writes. |

An agent with a built-in spawns the auditor itself, `Task` on Claude Code and
`collaboration.spawn_agent` on Codex, from the specs in `.claude/agents/`.

GitHub events, in a repository whose `.github/workflows/unreviewed-pr.yml` runs
`scripts/pr-unreviewed-file.sh` from a trusted base-branch checkout (`pull_request_target`).
Independent of every hook above.

| On `opened`, `reopened`, `synchronize` or `ready_for_review` | The step does |
| --- | --- |
| The head carries `UNREVIEWED.md` | Converts the pull request to a draft and fails. |
| The head lacks it and the pull request carries a valid marking commit | Passes: the file was added and then deleted. |
| The head lacks it and the pull request lacks that commit | Commits the file, reports `Author reviewed the PR` as failing on that commit, converts to a draft and fails. |
| No such commit among the 250 GitHub lists, the most it returns | Fails closed: one past that end would be invisible, and marking again would loop. |
| The head branch lives in a fork, opened by an owner, member or collaborator | Converts to a draft and fails: that token cannot mark a fork, and opening from one would otherwise be the way around this gate. |
| The head branch lives in a fork, opened by anyone else | Passes, unmarked and undrafted: they cannot merge it either, so whoever merges it is reading it. |

The verdict reaches the pull request as this job's own check run, which GitHub attaches to
the head under `pull_request_target` as under `pull_request`. The marking commit is the one
thing that never gets a run, because a commit made with the workflow's token starts none, so
the step posts a status on it under the job name; one required check covers both. Draft is
the enforcement that needs no branch protection. The step only ever converts to draft: a
person marks the pull request ready. A fork is the one head this token cannot mark at all,
so the gate reads who opened it: refusing every fork would close the contribution route of
any repository that asks people to fork, and passing every fork would let anyone with push
access walk around the gate by opening from one. Require approvals on the base branch to
hold the side this cannot.

A valid marking commit names this pull request in its subject, is authored by
`github-actions[bot]`, is committed by `web-flow`, verifies, and its own diff added the
file. Those five are tamper-evidence, not access control: both logins come from commit
email addresses anyone can set, and they mean something only alongside the signature, which
GitHub verifies against the committer. What they rule out is a typed subject, a real marker
minted for another pull request and merged in on a stacked branch, a locally signed commit
wearing the bot's author email, an unsigned commit, and an empty one. What they cannot rule
out is someone with write access adding a workflow, whose token makes a real marking commit.
Draft is the block that does not rest on any of it; branch protection and review of
`.github/workflows` are the controls.

Every read is of current state, the pull request's head sha and its commits, never the
event's own sha, so a queued run cannot pass a head that still carries the file. A pull
request merged unreviewed carries the file onto the default branch. The workflow names this
repository's script path, so a consumer copies the script with it.

## State files

All under `.agents/state/`, gitignored, and suffixed by session scope wherever more
than one session can share a checkout.

- `last-verdict.json`: the turn dossier the Stop gate consumes.
- `last-verdict.prev.json`: a FAIL parked when the fix moved the tree, so the next audit re-checks its findings.
- `verdict-decisions.log`: one line per Stop-gate decision, rung and outcome.
- `verdict-last-uuid`: the id of the message the gate last judged.
- `verdict-prompt-epoch`: the current prompt epoch.
- `reply-summary-ask`: the previous Stop's request for the result in few words, which the next Stop takes.
- `verdict-stop-message.jsonl`: Codex's Stop message preserved in transcript shape when no transcript exists.
- `last-audit.json`: the commit or push dossier. `last-audit-handoff.json` carries the gate's request to the auditor.
- `commit-audit-receipt.json`: the receipt commit-msg publishes and pre-push spends.
- `pr-reviewed.json`: the typed PR-review acknowledgment, bound to branch and HEAD.
- `auditor-control`: a directory of escalation, completion, grant and event records for running auditors and overrides.
- `last-api-failure.json`: the kind of API error that ended a turn.
- `api-resume`: the recent resumes and the unspent wake hashes of the API-failure resume.

## Boundaries

- Host to hook: the host injects its own plugin-root name, `PLUGIN_ROOT` on Codex and `CLAUDE_PLUGIN_ROOT` on Claude Code, and every wired command resolves `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`. `.agents/lib/hook-host.sh` answers which host is calling from that name alone. Session variables such as `CLAUDECODE` name whatever launched the process tree and are never used for routing.
- Hook to agent: a hook is a bash process and cannot spawn a subagent. It emits text naming the route the calling host has, and the agent takes it. `.agents/lib/subagent.sh:8`
- Agent to auditor: the auditor spec is the only writer of a dossier. Gates read verdicts and never write them.
- Gate to state: each artifact is bound to what it judged. Turn dossier: branch, HEAD, tree hash, generation, session scope, prompt epoch; a mismatch is discarded and the Stop gate falls through to fresh detection (`.agents/hooks/preflight-verdict-check.sh:28`). Commit and push dossier: branch, HEAD, the staged or pushed diff, the command, and for a commit the subject, for 5 hours after it is written; a mismatch or an older dossier denies until a fresh audit (`.agents/hooks/preflight-commit-push.sh:677`). Receipt: parent, tree, subject. Reply-summary ask: prompt epoch, how the request went out, and the judged turn's tool count (`.agents/lib/reply-summary.sh`).
- Stop gate to verdict check: `.agents/hooks/stop-gate.sh` hands the payload unchanged to `.agents/hooks/preflight-verdict-check.sh` and passes its output, stderr and exit status through. It learns which rung decided from the `VERDICT_DECISION_OUT` file it names.
- Summary wording: edit `.agents/prompts/reply-summary.md` in the active plugin checkout. `.agents/lib/reply-summary.sh` reads it on each request through `subagent_prompt`, substituting `{{max_words}}` with the gate's word threshold. Edits take effect on the next request without changing the hook; the threshold and restatement checks remain in code. A missing, empty, or unrenderable prompt reports stderr and leaves the verdict check's result intact, without recording an ask.
- Consumer to tooling: consumers float on `tooling.ref`, run only the adopted revision recorded in `.git/agent-tooling/current`, and reach the network only from bootstrap and refresh. `templates/install.sh:11`, hold at `:15`. One refresh runs at a time, held by `.git/agent-tooling/.refresh.lock` (`scripts/refresh-installation.sh:31`), and a refresh that finds it held skips. Breaking that lock would race its holder, so one left behind by a killed run is reported rather than cleared: `scripts/verify-installation.sh:22`, which every commit and push runs, names it once it is an hour old. Without that, the automatic refresh is dead and only a log nobody reads would say so.

## Invariants

Often stated as an absence. Each names the line that states or enforces it.

- A gate never produces the verdict it checks. `.agents/hooks/preflight-commit-push.sh:6`
- A PASS never reaches the model: nothing of a consumed PASS or its advisories is shown to the model, and advisories go to the human only. After a long reply the model sees only the request for the result in few words. `.agents/hooks/preflight-verdict-check.sh:17`
- A stale or mismatched turn dossier is discarded, never blocked on. `.agents/hooks/preflight-verdict-check.sh:28`
- A turn the gate cannot read ends unjudged under `blind-allow`, never blocked. `.agents/hooks/preflight-verdict-check.sh:52`
- A message is never judged twice. `.agents/hooks/preflight-verdict-check.sh:61`
- A parked FAIL serves only the next audit of the same round. `.agents/hooks/preflight-verdict-check.sh:212`
- The Stop gate asks for the result only after the verdict check judged and allowed the turn, or a user's override let it end, and never twice in a row. `.agents/hooks/stop-gate.sh:178`
- An answer to that ask ends unjudged only at 120 words or fewer, code included, with no tool call since the ask. `.agents/hooks/stop-gate.sh:115`
- The prompt hook never signals a PID chosen from workspace state. `.agents/hooks/cancel-verdict-audit.sh:13`
- A hook emits text; only the agent spawns a subagent. `.agents/lib/subagent.sh:8`
- Humans are not gated; named harness variables gate, never prefix wildcards. `.githooks/pre-commit:9`
- A receipt names a commit by parent and tree, never by a diff hash. `.agents/lib/commit-audit-receipt.sh:10`
- An override is recorded as `OVERRIDDEN BY USER`, never PASS, and expires within an hour. `.agents/hooks/auditor-control.sh:686`, `.agents/lib/auditor-override-state.sh:55`
- A StopFailure hook's result is ignored. A turn resumes only through an `asyncRewake` exit 2, at most three times per session in ten minutes, each resume recorded before it is announced. `.agents/hooks/resume-after-api-failure.sh:125`
- An `asyncRewake` wake is internal only while its one-time nonce is unspent, and its owner spends it on first acceptance; a copy of a spent wake, or text riding after one, is a real prompt. `.agents/lib/hook-wake.sh:19`
- Codex's hook-event set is closed; an unknown key loads no hooks at all. `host-parity.test.sh:24`
- Every wired command resolves the plugin root as `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`. `host-parity.test.sh:30`
- A malformed hold fails closed. `templates/install.sh:15`
- `.agents/state/` is never committed. `.gitignore:1`

## Stop gate decisions

Every decision is logged as a rung and an outcome, in this evaluation order.
`.agents/hooks/stop-gate.sh` logs the two `summary` rows, first and last, and runs
`.agents/hooks/preflight-verdict-check.sh` for every row between them. Line numbers
are in the script that logs the row; a pair logged at more than one line cites the
first.

| Rung | Outcome | When | Line |
| --- | --- | --- | --- |
| summary | restatement-allow | The previous Stop asked for the result, this answer is 120 words or fewer counting code, and no tool ran since the ask; it ends the turn and the verdict check does not run. | 128 |
| override | overridden-allow | A valid `OVERRIDDEN BY USER` grant exists for this prompt epoch; the use is logged and the gate opens. | 715 |
| extract | truncated-block | The bounded final-turn snapshot exceeded its byte limit; an independent FAIL dossier is required. | 1782 |
| extract | blind-allow | The transcript has content but no assistant text after a 2 second wait; the turn ends unjudged. | 1789 |
| extract | empty-allow | No transcript, or nothing in it; there is nothing to judge. | 1792 |
| cancellation | discard-generation | A cancellation record exists for the requested generation; a newer prompt revoked it. | 1806 |
| dossier | discard-generation | The dossier's generation is not the requested one. | 1884 |
| dossier | discard-stale | Branch, HEAD, tree hash or age no longer match; the dossier is discarded and triage runs. | 1890 |
| dossier | PASS-allow | A fresh, matching PASS; consumed, and any advisories are shown to the human only. | 1923 |
| dossier | discard-revoked | A matching dossier whose request could not be consumed because its generation was revoked or replaced. | 1933 |
| dossier | IN_PROGRESS-allow | Proof deferred while the parent pauses or asks the user; allowed with a note. | 1941 |
| dossier | FAIL-block | Findings block the turn; advisories stay out of the reason; unchanged text reuses this FAIL instead of re-running the model. | 1954 |
| audit | inflight-allow | A live runner holds the lock for this session; its verdict gates the next turn end. | 2081 |
| race | stale-allow | The newest message id is the one already judged; a message is never judged twice. | 2094 |
| harness | noise-allow | Every non-empty assistant line is harness text such as an API error; no model call. | 2126 |
| assertion | match-block | An assertion-only form such as "173/173 tests pass"; audited with no classifier call. | 2135 |
| triage | oversized-block | The turn text exceeds the classifier byte cap; sent straight to the file-backed auditor. | 2142 |
| triage | NO-allow | The fast model found nothing taken on trust; allowed and announced to the human. | 2151 |
| triage | YES-block | The model found a conclusion the reader must take on trust; the audit runs inside this Stop. | 2155 |
| regex | none-allow | No model reachable and no fallback pattern matched. | 2163 |
| regex | match-block | No model reachable and a fallback pattern matched. | 2167 |
| summary | ask-continue | The verdict check ended on overridden, PASS, IN_PROGRESS, NO or none, the last reply runs over 60 words of prose, and the previous Stop did not ask. The turn continues once: `additionalContext` on Claude Code, `decision: block` elsewhere. | 205 |

Dossier shape, from `.claude/agents/verdict-auditor.md`: `branch`, `head`, `tree_hash`,
`generation`, a `verdict` of `PASS`, `FAIL` or `IN_PROGRESS`, and `findings`. The
commit and push dossier in `.claude/agents/commit-push-auditor.md` carries `PASS` or
`FAIL` and is `FAIL` exactly when `findings` is non-empty. Both kinds may carry
non-blocking `advisories`, which never decide the verdict.

## Glossary

- **dossier**: the JSON verdict an auditor writes, bound to what it judged; the bindings per kind are under Boundaries.
- **generation**: the id of one audit request. A revised turn gets a new generation and a new audit; a dossier from another generation is discarded.
- **session scope**: the per-session suffix that keeps one session's state files apart from another's in the same checkout.
- **prompt epoch**: a counter advanced by each real user prompt. Grants, cancellations and dossiers bind to it, so a new prompt revokes what the old one authorised.
- **rung**: the stage of the Stop gate that made a decision, logged with its outcome.
- **triage**: the three-tier decision of whether a turn asserts something the reader must take on trust.
- **marker**: the typed `reviewed:` acknowledgment persisted for the PR gate, bound to branch and HEAD and consumed on the allow path.
- **receipt**: proof that a commit passed its own audit, published by commit-msg and spent by pre-push.
- **override**: a prompt-scoped grant that bypasses both auditor gates, recorded as `OVERRIDDEN BY USER`.
- **revoke**: what a newer prompt does to an audit or override the previous prompt owned.
- **parked**: a FAIL dossier kept after the tree moves so the next audit re-checks its findings.
- **restatement**: the answer to the Stop gate's request for the result in few words; it ends the turn without the verdict check when it holds 120 words or fewer and no tool ran since the request.
- **stale**: a binding that no longer matches. A stale turn dossier is discarded; a stale commit or push dossier denies until a fresh audit.
- **blind-allow**: the rung under which a turn ends unjudged because the gate could not read its text.
- **hold**: `.agent-tooling/hold`, one full lowercase SHA that freezes adoption; a malformed hold fails closed.
- **tooling.ref**: the branch or tag consumers float on; the validated revision they run is recorded in `.git/agent-tooling/current`.
- **guidance block**: the hash-marked splice of `guidance/workflow.md` into a consumer's `AGENTS.md`; missing or edited fails the gates, behind only warns.
- **twins**: `hooks/hooks.json` and `hooks/codex-hooks.json`, behaviourally identical except `asyncRewake` against `async` and the events only one host has.
- **watch**: one run of `.agents/watch/pr-watch.sh` after a push, streaming CI and PR events as JSON lines under one watch id.
- **wake**: the turn Claude Code starts when an `asyncRewake` hook exits 2; its prompt carries the hook's stderr in a reminder after the host's envelope, and it is internal only while its one-time nonce is unspent.
- **unreviewed file**: `UNREVIEWED.md`, committed by CI to a new pull request, which it also drafts; a person deletes the file after reading the diff and marks the pull request ready, and a PR merged without that brings the file onto the default branch.

## Code map

```text
hooks/                  the twin host hook manifests
.agents/hooks/          one script per gate or producer, listed above
.agents/lib/            shared state, receipt, host, wake and rendering libraries; sourced, never run
.agents/prompts/        editable Markdown prompt templates, read when a request is built
.agents/watch/          the pr-watch producer and its stream and attach consumers
.agents/skills/         shell-engineering, boxlite-diagrams, adversarial-iteration
.claude/agents/         the two auditor specs
.githooks/              the universal Git gates
scripts/                profile validation, installation verify/sync/refresh, setup, guidance splice, unattended-run supervisor, unreviewed-PR file
guidance/workflow.md    the canonical guidance spliced into consumers
host-parity.test.sh     what keeps the three hosts loading the same assets
architecture.test.sh    what keeps this map honest
```
