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
| Calls an editor, notebook editor, or patch tool | `PreToolUse` | `.agents/hooks/preflight-design-doc.sh` | Blocks without a live, readable design doc bound to the worktree and branch; shell commands are outside this gate. |
| Runs `git commit` or `git push` from the agent's shell | `PreToolUse` | `.agents/hooks/preflight-commit-push.sh` | A denial naming the route to `commit-push-auditor`, or the command runs on a fresh PASS. Delegates to the Git gates when they are installed. |
| Publishes GitHub text, or runs `gh pr create`, `gh pr edit` or `gh pr ready` | `PreToolUse` | `.agents/hooks/preflight-pr-review.sh` | Blocks recognizable private context or requests shorter text. PRs over 400 changed lines require a timed exception or splitting. Non-draft PR operations also require the human's typed `reviewed:` acknowledgment. |
| Opens or answers a managed Claude question | `PreToolUse`, `PostToolUse` on `AskUserQuestion`, Claude only | `.agents/hooks/claude-timed-question.sh` | Validates the exact question and records a timely typed answer; idle expiry and selected options never authorize a PR. |
| Completes a remote write | `PostToolUse` | `.agents/hooks/post-remote-write-watch.sh` | Context telling this session how to attach to the pr-watch stream. |
| Ends a turn | `Stop` | `.agents/hooks/stop-gate.sh` | Requires a leading TL;DR under 40 words, then resumes pending timed confirmations or checks the verdict. A dense reply gets one shortening request. See the decision table below. |
| Loses a turn to an API error, Claude Code only | `StopFailure` | `.agents/hooks/record-api-failure.sh` | Nothing. `scripts/resume-on-network-error.sh` reads the record to decide whether to restart. |
| Loses a turn to a dropped stream or an overloaded API in an interactive session, Claude Code only | `StopFailure`, wired with `asyncRewake` | `.agents/hooks/resume-after-api-failure.sh` | The turn resumes where it stopped, at most three times per session in ten minutes. |

The PR description contract in `CONTRIBUTING.md` requires every PR to explain how
the change produces its intended result, using the form best suited to the PR.
Before code is written, a 1–3 page design doc must exist; every PR must link it,
preferably in a GitHub issue, then Notion, then a Linear issue.
`scripts/design-doc.sh` binds the URL with `.agents/lib/design-doc.sh` after a
provider read; the gate rechecks existence, nonempty content, and the shared
paragraph/list limits, with a leading TL;DR under 40 words. No total-word cap applies.
Bindings live in the worktree Git directory as `agent-tooling-design-doc.json` and
match its canonical root and branch (or detached HEAD). State reads and replacement
reuse `.agents/lib/verdict-audit-state.sh`; no success cache survives a failed read.
Notion child blocks fail closed; list items and code retain their density semantics.
Page length and design quality remain review criteria. The pre-edit gate covers
native editor, notebook, and patch tools on both hosts. Shell commands, other clients,
and arbitrary MCP writers are outside it; shell-created code still requires a design
under the workflow guidance. Shell commands retain host permissions and the separate
commit/push and PR gates, without a research-command allowlist.
`.agents/lib/pr-design-doc.sh` checks `gh pr create`, `edit`, and `ready` before
review acknowledgment handling. Literal bodies must link the registered canonical
URL, including drafts; body-preserving operations fetch the published body and
match its branch and HEAD. GitHub renders the body; an exact anchor target outside
code must match the document. The render call is bounded to 20 seconds and 64 KiB;
failures block publication. Hidden source URLs do not count as links. Direct API
and browser PR writes remain outside this CLI check.
The same hook checks PR bodies (including drafts), issue/discussion bodies, comments,
reviews, close/reopen comments, release notes, and REST body/description fields.
`.agents/lib/github-writing.sh` applies `.agents/lib/reply-summary.sh`'s shared
limits: at most 120 words total, paragraphs at most 80 and list items at
most 40. Fences and tables still count toward the total; Chinese/Japanese characters
count individually. Empty text and inputs over 8000 shell characters fail closed.
Denials reuse `.agents/prompts/concise-writing.md`; clarity remains a reviewer judgment.
Every inspected body also needs a TL;DR heading and summary prose, including short
comments, design documents, and published PR bodies checked on ready/metadata edits.
The author-review publisher checks its rendered bot comment for privacy indicators
and a summary before POST or PATCH.

`github_writing_check_privacy` in `.agents/lib/github-writing.sh` also inspects literal
CLI titles and REST title fields. It rejects conversation/memory markup, explicit
private-message attribution, personal home paths, and local agent context paths.
It scans raw text even inside comments or fences, bounds input to 8000 characters,
fails closed on scanner errors, and never echoes rejected content. Denials occur
before consuming PR acknowledgments. There is no automatic disclosure exception.
This is a heuristic against accidental copies, not a provenance verifier or secret
scanner: paraphrases, unrecognized languages, arbitrary private facts, attachments,
and external publishing routes require separate controls. Credentials and host
permissions are unchanged. Shared guidance requires public evidence or explicit
authorization for the exact outgoing content and destination.

The existing shell scanner supplies literal argv without executing it. Inline bodies
are inspectable; body files, stdin, editors, generated text and GraphQL text mutations are
rejected because their final published text is outside this check. Read-only commands
and body-preserving operations, including close/reopen without comments, pass through.
Visible writes behind unsupported launchers fail closed. GraphQL detection skips
comments and quoted strings and recognizes all ignored token separators.
This is a hook on recognized `gh`
commands, not a GitHub server policy: other clients, script files, browser edits and
later bot additions are outside it. Writing denials never consume an acknowledgment.
`guidance/workflow.md` carries the same writing rules into consumer instructions.

The 400-line policy in `guidance/workflow.md` is enforced for supported direct
`gh pr create/edit/ready` commands by `.agents/lib/pr-size.sh`. It reads GitHub's
published comparison (additions + deletions, including tests and generated text).
Unknown or truncated comparisons fail closed. Creation requires a published branch;
Base-changing edits, fork creation, and opaque invocations are unsupported.
Git pushes, direct API calls, and browser writes are outside this size check;
it is not a repository-wide enforcement boundary.

Dependent slices use native GitHub stacks as described in `guidance/workflow.md`.
Stack commands are not recognized by the per-PR publication checks: agents publish
each layer through the guarded commands, then use `gh stack link` with verified
existing PR URLs and matching bases. This is workflow guidance, not a new hook boundary.

`.agents/lib/timed-user-prompt.sh` provides the reusable three-minute confirmation
lifecycle through `scripts/timed-user-prompt.sh`. Requests bind to caller-supplied
context and a random ID; retries preserve the deadline, late replies are rejected,
and acceptance can be consumed once. Callers select `split` or `keep-draft` as the
timeout fallback for `pr-size-exception:` or `reviewed:` respectively. The library
serializes state transitions; its prompt renderer describes an agent-opened,
non-blocking question. It never waits or opens a host dialog inside the state lock.

Size exceptions bind to repository, base/head, measured size, and session. A reason
needs at least 12 words; the agent must judge whether it names a concrete constraint.

The local PR gate uses this lifecycle for `reviewed:` acknowledgments, bound to
checkout, branch/head, session, and request ID. A retry cannot restart the deadline;
expiry leaves the PR draft or uncreated, and a successful operation consumes the reply.

The question UI is **agent-opened**, through the instruction in
`.agents/prompts/timed-user-prompt.md`; no command hook opens a native dialog.
The deadline starts when the gate records the request. Before normal Stop checks,
`scripts/continue-timed-prompts.sh` resumes pending requests or delivers their timeout
fallback once: split oversized work, or leave an unreviewed PR draft/uncreated.
The agent performs the wait, issue creation, and splitting; these are not background
jobs. `.agents/prompts/pr-size-exception.md` carries the size-specific wording.

Local interactive sessions launched through `scripts/claude-with-timed-prompts.sh`
load this plugin with `--plugin-dir`, enable 180-second native idle dismissal, and
disable Remote Control for that session through `--settings` (`remoteControlAtStartup:false`
and `disableRemoteControl:true`). No settings files are edited. The launcher exports
`BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1`; routing and PreToolUse require that marker plus
a bounded timeout through `timed_user_prompt_native_available`. The marker describes
launcher configuration, not runtime host attestation or authority to approve.
The agent invokes the exact `AskUserQuestion` payload generated
by the shared library. The Claude-only hook binds presentation and response to its
tool call ID and original deadline, rejects prefilled answers and `afkTimeoutMs`
auto-responses, and writes a valid `reviewed:` marker itself. Explicit Remote Control,
custom `--settings`, print, background, and cloud invocations retain their arguments,
clear any inherited native marker, and use plain-text, non-blocking questions.
Missing marker or timeout setup also uses that fallback. Codex retains async input.
Existing requests gain an empty native question ID without changing their deadline.

Remote Control kept native questions open despite the idle timeout in Claude 2.1.278
([issue #83](https://github.com/boxlite-ai/agent-tooling/issues/83)). Startup disabling
alone allows later reconnection, so the native launcher also disables the in-session
toggle. Custom settings conservatively use the fallback rather than being merged or
replaced. Environments whose managed policy overrides the session configuration must
use the fallback, for example by supplying `--settings '{}'` to the launcher.
Claude's idle timer resets on interaction; the shared deadline never does.
An active dialog may remain visible past that deadline, but cannot grant a late
exception. Splitting resumes when the dialog returns; this is not a hard deadline
for dismissing a busy UI. The launcher affects other questions in that session too.
Sources: [question timeout](https://code.claude.com/docs/en/tools-reference#question-auto-continue-timeout),
[timeout override](https://code.claude.com/docs/en/env-vars).
PR prompts are runtime-loaded through `subagent_prompt`: `.agents/prompts/pr-review-question.md`
supplies the shared explanation check, `.agents/prompts/pr-review-ack.md` supplies both
normal and bounded local acknowledgment instructions, `.agents/prompts/pr-description-guidance.md`
supplies body-writing guidance, and `.agents/prompts/pr-author-review.md` supplies the
GitHub comment. Missing, empty, or unrenderable prompts fail closed before consuming
a local acknowledgment or publishing GitHub acknowledgment success. A local recovery
prompt over 1200 bytes also fails closed. No embedded fallback copy is kept in Bash.

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

GitHub events run `.github/workflows/author-review.yml` from trusted base/default-branch
code. `scripts/pr-author-review.sh` checks dependencies and calls the single facade
`pr_author_review_run` in `.agents/lib/pr-author-review.sh`. This gate is independent of
all local hooks above.
Both review prompts ask whether the description explains the mechanism in the diff;
acknowledgment remains bound to the commit SHA and does not certify description quality
or expire on body edits.

| Current PR state | Gate result | Contributor action |
| --- | --- | --- |
| No author acknowledgment for the current head | Pending; convert to draft | Read the diff, post `/reviewed <full-head-SHA>` as a new comment, then click **Ready for review** after the check succeeds. |
| An unedited comment from the PR author's GitHub user id names the current head | Success; preserve the current draft state | Mark ready when you want reviews, then merge after other required checks and approvals pass. |
| The head changes, or the only acknowledgment is edited or deleted | Pending; convert to draft | Read the current diff and post a fresh acknowledgment before marking ready. |
| Another open PR shares the acknowledged head SHA | Pending; convert to draft | Push a distinct commit so one PR's status cannot satisfy another's gate. |
| A GitHub read or write fails, state is malformed, or a scan reaches 1000 comments/associated PRs | Pending when it could be published; handler fails | Resolve the error and rerun the workflow. |
| The PR is closed, or a comment belongs to an ordinary issue | No write | None. |
| A merge queue requests checks on its temporary commit | Success, carried forward from queue admission | None; the PR status must be required before admission. |

The workflow subscribes to `pull_request_target` (opened, reopened, synchronize,
ready_for_review, closed) and `issue_comment` (created, edited, deleted). It serializes
runs per PR without canceling the active run, with a five-minute job limit. A human can
post `/recheck-author-review` to initialize an existing PR or retry; any new non-bot PR
comment recomputes live state without granting acknowledgment by itself. Rechecks use
the default-branch `issue_comment` workflow rather than a caller-selected workflow ref.
The script ignores newly created bot comments, but reconciles edits and deletions so
modified or deleted instruction comments are repaired. The workflow routes all PR comment
events to that script; idempotent prompt updates avoid repeated writes.
`merge_group` runs use their temporary SHA as the concurrency key and publish a success
carried forward from the required PR admission check. GitHub may
replace queued runs; every run therefore recomputes from live PR/comments, never the
event's SHA, comment text, or author association. Head changes during evaluation retry
at most three times. A matching comment is fetched again before granting success.
Only new, unedited comments count because maintainers can edit other users' comments.
Bots are not exempt and cannot acknowledge on a human author's behalf.

The gate revokes a previous success to pending before scanning. Once live state confirms
the acknowledgment is missing or cannot pass, it converts a ready PR to draft using
GitHub's `convertPullRequestToDraft` mutation and verifies the returned identity and draft
state. Existing drafts need no mutation. A later acknowledgment preserves the draft until
a person chooses **Ready for review**; trying that before acknowledgment drafts it again.
It maintains one bot instruction comment, updates it when necessary, and never writes
repository contents. Forks follow the same path. The comment is the acknowledgment record;
there is no signature file, database, personal token, or separate GitHub App.

Require the commit status `Author reviewed the PR`, sourced from GitHub Actions, in every
target branch's rules. The workflow job is named `Update author review status` so its own
check cannot substitute for the acknowledgment. Comment-triggered jobs run on the default
branch; the script explicitly posts the status on the PR's live head in the base repository.
Exit 0 means acknowledged/irrelevant, 1 means awaiting acknowledgment, and 2 means an error;
the workflow treats 1 as a handled event. Failure to write to GitHub cannot revoke a remote
success, so the failed handler must be investigated rather than treated as proof of review.
An acknowledgment records an assertion of review, not proof that a human read the diff.
Branch rules and review of privileged workflows remain the enforcement boundary.
Merge queues must require this same status on PRs before admission; the queue-generated
commit adds no new author acknowledgment. See the equivalent queue carry-forward in
[514-labs/cla-bot](https://github.com/514-labs/cla-bot/blob/main/SPEC.md#10-additional-scenarios-commonly-missed).

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
- `pr-reviewed.json`: the typed PR-review acknowledgment, bound to branch, HEAD, and request ID.
- `pr-review-request.json`: the review deadline and response lifecycle.
- `pr-size-request.json`: the size exception deadline, diff binding, and exact reason.
- `auditor-control`: a directory of escalation, completion, grant and event records for running auditors and overrides.
- `last-api-failure.json`: the kind of API error that ended a turn.
- `api-resume`: the recent resumes and the unspent wake hashes of the API-failure resume.

## Boundaries

- Watcher to commands: `.agents/watch/pr-watch.sh` owns the external command group
  and its timeout/output monitors. Monitor cancellation uses KILL and wait because
  those observers have no shutdown work; command groups retain TERM then KILL.
  The launch-cleanup test has an independent deadline and reports owned processes
  before forced teardown, preserving the original cleanup assertion.
- Host to hook: the host injects its own plugin-root name, `PLUGIN_ROOT` on Codex and `CLAUDE_PLUGIN_ROOT` on Claude Code, and every wired command resolves `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`. `.agents/lib/hook-host.sh` answers which host is calling from that name alone. Session variables such as `CLAUDECODE` name whatever launched the process tree and are never used for routing.
- Hook to agent: a hook is a bash process and cannot spawn a subagent. It emits text naming the route the calling host has, and the agent takes it. `.agents/lib/subagent.sh:8`
- Agent to auditor: the auditor spec is the only writer of a dossier. Gates read verdicts and never write them.
- Gate to state: each artifact is bound to what it judged. Turn dossier: branch, HEAD, tree hash, generation, session scope, prompt epoch; a mismatch is discarded and the Stop gate falls through to fresh detection (`.agents/hooks/preflight-verdict-check.sh:28`). Commit and push dossier: branch, HEAD, the staged or pushed diff, the command, and for a commit the subject, for 5 hours after it is written; a mismatch or an older dossier denies until a fresh audit (`.agents/hooks/preflight-commit-push.sh:677`). Receipt: parent, tree, subject. Reply-summary ask: prompt epoch, how the request went out, and the judged turn's tool count (`.agents/lib/reply-summary.sh`).
- Incomplete evidence: a missing or empty source during refresh retains the published failed snapshot. Audit re-entry reads and validates that bounded snapshot before consuming the dossier; loss of the original source cannot become `empty-allow`. An initially absent or empty transcript still has nothing to judge.
- Stop gate to verdict check: after checking TL;DR, `.agents/hooks/stop-gate.sh` hands the payload unchanged to `.agents/hooks/preflight-verdict-check.sh`. It learns which rung decided from `VERDICT_DECISION_OUT`. Missing dependencies fail closed.
- Mandatory summary: `.agents/lib/concise-writing.sh` checks for an ATX TL;DR heading and summary prose outside fences, quotes, and comments. Replies must start there; the entire section has at most 39 words using the shared Unicode-aware counter. Repeated continuations cannot bypass it. Missing Stop text falls back to a bounded transcript snapshot; unreadable or truncated snapshots fail closed. Sentence simplicity remains a writing instruction.
- Enforcement scope: Stop checks the final reply after generation; it cannot retract streamed commentary. GitHub checks cover recognized CLI calls, not browser or connector writes. Design checks cover fetched GitHub, Linear, and Notion content; native Notion headings retain their structure. Shared guidance applies to every human-facing output across these surfaces.
- Shared writing prompt: `.agents/prompts/concise-writing.md` is loaded through `subagent_prompt` for Stop and GitHub reminders. `{{max_words}}` remains the 60-word follow-up budget; TL;DR itself stays under 40 words. Dense paragraphs over 80 words or list items over 40 still trigger shortening. A broken prompt reports stderr without recording an ask or changing the verdict result; it cannot bypass the independent TL;DR check.
- Consumer to tooling: consumers float on `tooling.ref`, run only the adopted revision recorded in `.git/agent-tooling/current`, and reach the network only from bootstrap and refresh. `templates/install.sh:11`, hold at `:15`. One refresh runs at a time, held by `.git/agent-tooling/.refresh.lock` (`scripts/refresh-installation.sh:31`), and a refresh that finds it held skips. Breaking that lock would race its holder, so one left behind by a killed run is reported rather than cleared: `scripts/verify-installation.sh:22`, which every commit and push runs, names it once it is an hour old. Without that, the automatic refresh is dead and only a log nobody reads would say so.

- Offline installation repair: `templates/install.sh` routes the recorded cache through
  the installation lock, cache revision check, and `scripts/setup.sh`, then runs
  `scripts/verify-installation.sh` before success. This repairs worktree-local hooks
  without changing the shared record, adoption history, or last-check stamp. An invalid
  cache or profile fails closed. `templates/codex-plugin-bootstrap.sh` and
  `templates/claude-plugin-bootstrap.sh` keep the initial validity probe quiet, but
  report verifier and installer diagnostics if repair or pre-upgrade refresh fails.

## Invariants

Often stated as an absence. Each names the line that states or enforces it.

- A gate never produces the verdict it checks. `.agents/hooks/preflight-commit-push.sh:6`
- A PASS never reaches the model: nothing of a consumed PASS or its advisories is shown to the model, and advisories go to the human only. After a dense reply the model sees only the request for the result in few words. `.agents/hooks/preflight-verdict-check.sh:17`
- A stale or mismatched turn dossier is discarded, never blocked on. `.agents/hooks/preflight-verdict-check.sh:28`
- A readable snapshot with no assistant text ends unjudged under `blind-allow`; a failed or truncated snapshot requires an audit. `.agents/hooks/preflight-verdict-check.sh:53`
- A message is never judged twice. `.agents/hooks/preflight-verdict-check.sh:62`
- A parked FAIL serves only the next audit of the same round. `.agents/hooks/preflight-verdict-check.sh:213`
- The Stop gate asks for the result only after the verdict check judged and allowed the turn, or a user's override let it end, and never twice in a row. `.agents/hooks/stop-gate.sh:187`
- An answer to that ask ends unjudged only at 120 words or fewer, code included, with no tool call since the ask. `.agents/hooks/stop-gate.sh:124`
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

Timed confirmations run first and persist their own lifecycle. The normal verdict
and summary decisions below are logged as a rung and an outcome, in this order.
`.agents/hooks/stop-gate.sh` logs the two `summary` rows, first and last, and runs
`.agents/hooks/preflight-verdict-check.sh` for every row between them. Line numbers
are in the script that logs the row; a pair logged at more than one line cites the
first.

| Rung | Outcome | When | Line |
| --- | --- | --- | --- |
| summary | restatement-allow | The previous Stop asked for the result, this answer is 120 words or fewer counting code, and no tool ran since the ask; it ends the turn and the verdict check does not run. | 137 |
| override | overridden-allow | A valid `OVERRIDDEN BY USER` grant exists for this prompt epoch; the use is logged and the gate opens. | 716 |
| extract | truncated-block | The bounded final-turn snapshot is unreadable or exceeds its byte limit; an independent FAIL dossier is required. | 1802 |
| extract | blind-allow | The transcript has content but no assistant text after a 2 second wait; the turn ends unjudged. | 1809 |
| extract | empty-allow | No transcript, or nothing in it; there is nothing to judge. | 1812 |
| cancellation | discard-generation | A cancellation record exists for the requested generation; a newer prompt revoked it. | 1826 |
| dossier | discard-generation | The dossier's generation is not the requested one. | 1904 |
| dossier | discard-stale | Branch, HEAD, tree hash or age no longer match; the dossier is discarded and triage runs. | 1910 |
| dossier | PASS-allow | A fresh, matching PASS; consumed, and any advisories are shown to the human only. | 1943 |
| dossier | discard-revoked | A matching dossier whose request could not be consumed because its generation was revoked or replaced. | 1953 |
| dossier | IN_PROGRESS-allow | Proof deferred while the parent pauses or asks the user; allowed with a note. | 1961 |
| dossier | FAIL-block | Findings block the turn; advisories stay out of the reason; unchanged text reuses this FAIL instead of re-running the model. | 1974 |
| audit | inflight-allow | A live runner holds the lock for this session; its verdict gates the next turn end. | 2101 |
| race | stale-allow | The newest message id is the one already judged; a message is never judged twice. | 2114 |
| harness | noise-allow | Every non-empty assistant line is harness text such as an API error; no model call. | 2146 |
| assertion | match-block | An assertion-only form such as "173/173 tests pass"; audited with no classifier call. | 2155 |
| triage | oversized-block | The turn text exceeds the classifier byte cap; sent straight to the file-backed auditor. | 2162 |
| triage | NO-allow | The fast model found nothing taken on trust; allowed and announced to the human. | 2171 |
| triage | YES-block | The model found a conclusion the reader must take on trust; the audit runs inside this Stop. | 2175 |
| regex | none-allow | No model reachable and no fallback pattern matched. | 2183 |
| regex | match-block | No model reachable and a fallback pattern matched. | 2187 |
| summary | ask-continue | The verdict check ended on overridden, PASS, IN_PROGRESS, NO or none, the last reply has a paragraph over 80 words or a list item over 40, and the previous Stop did not ask. The turn continues once: `additionalContext` on Claude Code, `decision: block` elsewhere. | 214 |

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
- **author review acknowledgment**: a new, unedited `/reviewed <full-head-SHA>` PR comment from the PR author; the CI gate publishes its verdict on that commit.

## Code map

```text
hooks/                  the twin host hook manifests
.agents/hooks/          one script per gate or producer, listed above
.agents/lib/            shared state, receipt, host, wake and rendering libraries; sourced, never run
.agents/prompts/        editable Markdown prompt templates, read when a request is built
.agents/watch/          the pr-watch producer and its stream and attach consumers
.agents/skills/         shell-engineering, boxlite-diagrams, boxlite-examples, adversarial-iteration
.claude/agents/         the two auditor specs
.githooks/              the universal Git gates
scripts/                profile validation, installation verify/sync/refresh, setup, guidance splice, unattended-run supervisor, author review acknowledgment
guidance/workflow.md    the canonical guidance spliced into consumers
host-parity.test.sh     what keeps the three hosts loading the same assets
architecture.test.sh    what keeps this map honest
```
