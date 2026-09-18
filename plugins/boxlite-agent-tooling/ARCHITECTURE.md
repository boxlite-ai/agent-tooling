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
| Ends a turn | `Stop` | `.agents/hooks/preflight-verdict-check.sh` | Nothing on PASS. The findings on FAIL. See the decision table below. |
| Loses a turn to an API error, Claude Code only | `StopFailure` | `.agents/hooks/record-api-failure.sh` | A terminal notice. `scripts/resume-on-network-error.sh` reads the record to decide whether to restart. |

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
| The branch tip carries `UNREVIEWED.md` | Reports `Author reviewed the PR` as failing. |
| The tip lacks it and the pull request carries a valid marking commit | Passes: the file was added and then deleted. |
| The tip lacks it and the pull request lacks that commit | Commits the file, then reports the gate as failing on that commit, since a commit made with the workflow's own token starts no run. |
| The head branch lives in a fork | Reports unreviewed: that token cannot write a fork's branch. |

Both reads are of current state, never the event's own sha, so a queued run cannot pass a
tip that still carries the file. A valid marking commit uses the marker subject, carries the
canonical marker content, and has this workflow's failing gate status on that same commit. A
pull request merged unreviewed carries the file onto the default branch. The workflow names
this repository's script path, so a consumer copies the script with it.

## State files

All under `.agents/state/`, gitignored, and suffixed by session scope wherever more
than one session can share a checkout.

- `last-verdict.json`: the turn dossier the Stop gate consumes.
- `last-verdict.prev.json`: a FAIL parked when the fix moved the tree, so the next audit re-checks its findings.
- `verdict-decisions.log`: one line per Stop-gate decision, rung and outcome.
- `verdict-last-uuid`: the id of the message the gate last judged.
- `verdict-prompt-epoch`: the current prompt epoch.
- `verdict-stop-message.jsonl`: Codex's Stop message preserved in transcript shape when no transcript exists.
- `last-audit.json`: the commit or push dossier. `last-audit-handoff.json` carries the gate's request to the auditor.
- `commit-audit-receipt.json`: the receipt commit-msg publishes and pre-push spends.
- `pr-reviewed.json`: the typed PR-review acknowledgment, bound to branch and HEAD.
- `auditor-control`: a directory of escalation, completion, grant and event records for running auditors and overrides.
- `last-api-failure.json`: the kind of API error that ended a turn.

## Boundaries

- Host to hook: the host injects its own plugin-root name, `PLUGIN_ROOT` on Codex and `CLAUDE_PLUGIN_ROOT` on Claude Code, and every wired command resolves `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`. `.agents/lib/hook-host.sh` answers which host is calling from that name alone. Session variables such as `CLAUDECODE` name whatever launched the process tree and are never used for routing.
- Hook to agent: a hook is a bash process and cannot spawn a subagent. It emits text naming the route the calling host has, and the agent takes it. `.agents/lib/subagent.sh:8`
- Agent to auditor: the auditor spec is the only writer of a dossier. Gates read verdicts and never write them.
- Gate to state: each artifact is bound to what it judged. Turn dossier: branch, HEAD, tree hash, generation, session scope, prompt epoch; a mismatch is discarded and the Stop gate falls through to fresh detection (`.agents/hooks/preflight-verdict-check.sh:28`). Commit and push dossier: branch, HEAD, the staged or pushed diff, the command, and for a commit the subject; a mismatch denies until a fresh audit (`.agents/hooks/preflight-commit-push.sh:672`). Receipt: parent, tree, subject.
- Consumer to tooling: consumers float on `tooling.ref`, run only the adopted revision recorded in `.git/agent-tooling/current`, and reach the network only from bootstrap and refresh. `templates/install.sh:11`, hold at `:15`

## Invariants

Often stated as an absence. Each names the line that states or enforces it.

- A gate never produces the verdict it checks. `.agents/hooks/preflight-commit-push.sh:6`
- A PASS never reaches the model: a consumed PASS emits nothing the model sees, and any advisories go to the human only. `.agents/hooks/preflight-verdict-check.sh:17`
- A stale or mismatched turn dossier is discarded, never blocked on. `.agents/hooks/preflight-verdict-check.sh:28`
- A turn the gate cannot read ends unjudged under `blind-allow`, never blocked. `.agents/hooks/preflight-verdict-check.sh:52`
- A message is never judged twice. `.agents/hooks/preflight-verdict-check.sh:61`
- A parked FAIL serves only the next audit of the same round. `.agents/hooks/preflight-verdict-check.sh:210`
- The prompt hook never signals a PID chosen from workspace state. `.agents/hooks/cancel-verdict-audit.sh:13`
- A hook emits text; only the agent spawns a subagent. `.agents/lib/subagent.sh:8`
- Humans are not gated; named harness variables gate, never prefix wildcards. `.githooks/pre-commit:9`
- A receipt names a commit by parent and tree, never by a diff hash. `.agents/lib/commit-audit-receipt.sh:10`
- An override is recorded as `OVERRIDDEN BY USER`, never PASS, and expires within an hour. `.agents/hooks/auditor-control.sh:686`, `.agents/lib/auditor-override-state.sh:55`
- The StopFailure hook cannot block or resume; it records and notifies. `.agents/hooks/record-api-failure.sh:7`
- Codex's hook-event set is closed; an unknown key loads no hooks at all. `host-parity.test.sh:24`
- Every wired command resolves the plugin root as `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`. `host-parity.test.sh:30`
- A malformed hold fails closed. `templates/install.sh:15`
- `.agents/state/` is never committed. `.gitignore:1`

## Stop gate decisions

Every decision is logged as a rung and an outcome, in this evaluation order. Line
numbers are in `.agents/hooks/preflight-verdict-check.sh`; a pair logged at more than
one line cites the first.

| Rung | Outcome | When | Line |
| --- | --- | --- | --- |
| override | overridden-allow | A valid `OVERRIDDEN BY USER` grant exists for this prompt epoch; the use is logged and the gate opens. | 708 |
| extract | truncated-block | The bounded final-turn snapshot exceeded its byte limit; an independent FAIL dossier is required. | 1775 |
| extract | blind-allow | The transcript has content but no assistant text after a 2 second wait; the turn ends unjudged. | 1782 |
| extract | empty-allow | No transcript, or nothing in it; there is nothing to judge. | 1785 |
| cancellation | discard-generation | A cancellation record exists for the requested generation; a newer prompt revoked it. | 1799 |
| dossier | discard-generation | The dossier's generation is not the requested one. | 1877 |
| dossier | discard-stale | Branch, HEAD, tree hash or age no longer match; the dossier is discarded and triage runs. | 1883 |
| dossier | PASS-allow | A fresh, matching PASS; consumed, and any advisories are shown to the human only. | 1916 |
| dossier | discard-revoked | A matching dossier whose request could not be consumed because its generation was revoked or replaced. | 1926 |
| dossier | IN_PROGRESS-allow | Proof deferred while the parent pauses or asks the user; allowed with a note. | 1934 |
| dossier | FAIL-block | Findings block the turn; advisories stay out of the reason; unchanged text reuses this FAIL instead of re-running the model. | 1947 |
| audit | inflight-allow | A live runner holds the lock for this session; its verdict gates the next turn end. | 2074 |
| race | stale-allow | The newest message id is the one already judged; a message is never judged twice. | 2087 |
| harness | noise-allow | Every non-empty assistant line is harness text such as an API error; no model call. | 2119 |
| assertion | match-block | An assertion-only form such as "173/173 tests pass"; audited with no classifier call. | 2128 |
| triage | oversized-block | The turn text exceeds the classifier byte cap; sent straight to the file-backed auditor. | 2135 |
| triage | NO-allow | The fast model found nothing taken on trust; allowed and announced to the human. | 2144 |
| triage | YES-block | The model found a conclusion the reader must take on trust; the audit runs inside this Stop. | 2148 |
| regex | none-allow | No model reachable and no fallback pattern matched. | 2156 |
| regex | match-block | No model reachable and a fallback pattern matched. | 2160 |

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
- **stale**: a binding that no longer matches. A stale turn dossier is discarded; a stale commit or push dossier denies until a fresh audit.
- **blind-allow**: the rung under which a turn ends unjudged because the gate could not read its text.
- **hold**: `.agent-tooling/hold`, one full lowercase SHA that freezes adoption; a malformed hold fails closed.
- **tooling.ref**: the branch or tag consumers float on; the validated revision they run is recorded in `.git/agent-tooling/current`.
- **guidance block**: the hash-marked splice of `guidance/workflow.md` into a consumer's `AGENTS.md`; missing or edited fails the gates, behind only warns.
- **twins**: `hooks/hooks.json` and `hooks/codex-hooks.json`, behaviourally identical except `asyncRewake` against `async` and the events only one host has.
- **watch**: one run of `.agents/watch/pr-watch.sh` after a push, streaming CI and PR events as JSON lines under one watch id.
- **unreviewed file**: `UNREVIEWED.md`, committed by CI to a new pull request; a person deletes it after reading the diff, and a PR merged without that brings it onto the default branch.

## Code map

```text
hooks/                  the twin host hook manifests
.agents/hooks/          one script per gate or producer, listed above
.agents/lib/            shared state, receipt, host and rendering libraries; sourced, never run
.agents/watch/          the pr-watch producer and its stream and attach consumers
.agents/skills/         shell-engineering, boxlite-diagrams, adversarial-iteration
.claude/agents/         the two auditor specs
.githooks/              the universal Git gates
scripts/                profile validation, installation verify/sync/refresh, setup, guidance splice, unattended-run supervisor, unreviewed-PR file
guidance/workflow.md    the canonical guidance spliced into consumers
host-parity.test.sh     what keeps the three hosts loading the same assets
architecture.test.sh    what keeps this map honest
```
