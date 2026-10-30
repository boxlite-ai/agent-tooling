# Architecture

- One plugin, three hosts: Claude Code, Codex, Copilot.
- Fail-closed gates around the moments a coding agent acts on a repository: the end of a turn, a commit, a push, a pull request.
- A gate never produces the verdict it checks. An independent auditor writes a dossier under `.agents/state/`, bound to what it judged, and the gate reads it back.
- A turn dossier whose binding no longer matches is discarded, never blocked on; a commit or push dossier that no longer matches denies until a fresh audit.
- Humans are not gated: Git gates recognize harness variables or a live ancestor recorded by PreToolUse.
- This file is a map, not an atlas: entry points, boundaries, invariants, vocabulary. How a script works is in its own header comment.
- `architecture.test.sh` fails when the map names a script, state file, decision or term the code no longer has.

## Entry points

Host hook events, wired for both hosts in `hooks/hooks.json` and
`hooks/codex-hooks.json` unless noted. Generic consumers use
`hooks/generic-hooks.json`, with the same events as the Codex manifest. One script per row.

Registered entry points stay at `.agents/hooks/`; host manifest paths are stable.
Helper runners, schemas, tests, and fixtures use purpose directories beneath it:
`audit`, `design`, `pr`, `resume`, `session`, and `watch`. Entry points resolve
helpers from the plugin root. The standalone reminder keeps its companion beside it.

| A person or host does this | Event | Script | What they see |
| --- | --- | --- | --- |
| Submits a prompt | `UserPromptSubmit` | `.agents/hooks/cancel-verdict-audit.sh` | Nothing. Old authority is revoked; unchanged audit work may finish as prior evidence. |
| Submits a prompt in a consumer that opted in | `UserPromptSubmit` | `.agents/hooks/rule-recency.sh` | Names boxlite-writing and points to the workflow. Not wired by the plugin manifests. |
| Starts or finishes an auditor subagent | `SubagentStart`, `SubagentStop` | `.agents/hooks/auditor-control.sh` | After 30 seconds, one Keep waiting or Force pass card on Claude Code, a typed status elsewhere. A commit/push auditor without a bound dossier is resumed once, and every stop closes its attempt. |
| Calls an editor, notebook editor, or patch tool | `PreToolUse` | `.agents/hooks/preflight-design-doc.sh` | Blocks without a live, readable design doc bound to the worktree and branch, or without a `design-research-auditor` PASS for its exact content, unless every target resolves outside every repository; shell commands are outside this gate. |
| Runs `git commit` or `git push` from the agent's shell | `PreToolUse` | `.agents/hooks/preflight-commit-push.sh` | A denial naming the route to `commit-push-auditor`, or the command runs on a fresh PASS. Delegates to the Git gates when they are installed. |
| Publishes GitHub text, or runs `gh pr create`, `gh pr edit` or `gh pr ready` | `PreToolUse` | `.agents/hooks/preflight-pr-review.sh` | Blocks recognizable private context or requests shorter text. Above 400 added code lines, asks the user to bypass the guideline or split. Non-draft PR operations also require the human's typed `reviewed:` acknowledgment. |
| Opens or answers a managed Claude question | `PreToolUse`, `PostToolUse` on `AskUserQuestion`, Claude only | `.agents/hooks/claude-timed-question.sh` | Validates the exact question and records a timely size choice or typed review answer. Idle expiry never authorizes; size choices cannot satisfy review acknowledgment. |
| Completes a remote write | `PostToolUse` | `.agents/hooks/post-remote-write-watch.sh` | Context telling this session how to attach to the pr-watch stream. |
| Finishes a plain `make test...` command | `PostToolUse`; `PostToolUseFailure` on Claude Code | `.agents/hooks/record-test-run.sh` | Nothing. A supported completion result creates a receipt in `.agents/state/test-runs/` for `commit-push-auditor`. |
| Ends a turn | `Stop` | `.agents/hooks/stop-gate.sh` | At most one TL;DR correction per turn; a reply that leads with a TL;DR is never asked to shorten. Continued replies still reach timed confirmations and verdict checks. See the decision table below. |
| Loses a turn to an API error, Claude Code only | `StopFailure` | `.agents/hooks/record-api-failure.sh` | Nothing. `scripts/resume-on-network-error.sh` reads the record to decide whether to restart. |
| Loses a turn to a dropped stream or an overloaded API in an interactive session, Claude Code only | `StopFailure`, wired with `asyncRewake` | `.agents/hooks/resume-after-api-failure.sh` | The turn resumes where it stopped, at most three times per session in ten minutes. |

### Runtime prompts

Templates live one directory below `.agents/prompts/`, grouped by purpose.
Callers use qualified names such as `audit/commit-push-task`; the loader resolves
that exact relative path without searching by basename.

Auditor choice text and escalation instructions live in `.agents/prompts/audit/auditor-*.md`.
The interactive renderer loads `.agents/prompts/questions/interactive-question.md` after
validating the question payload; option commands stay JSON data generated by code.

Watcher attachment prose uses `.agents/prompts/watch/watch-attach*.md`, including host,
compact, and oversized variants. Rendering keeps the 1400-byte checks and exact
claim command; template failure leaves cleanup/retry authority with the existing
lease owner.

The optional standalone reminder reads `.agents/hooks/rule-recency.md` beside its
script, without loading plugin libraries; copy both files into the consumer.
The shared writing reminder and network-resume turn use normal prompt templates.
The writing skill remains the canonical writing policy.

[PROMPTS.md](PROMPTS.md) lists runtime prompt locations and editing contracts.
Design-gate instructions and API-resume turns also use the shared loader; resume
instructions load before the wake budget is recorded.

### Design documents

Research and design policy lives in `boxlite-design-doc`; registration
and publishing steps live in [CONTRIBUTING.md](CONTRIBUTING.md#pull-request-descriptions).

`scripts/design-doc.sh` accepts `register <URL>` and binds it with `.agents/lib/design-doc.sh`
after a provider read; `bind` remains a compatibility alias. The preferred verb avoids
Claude Code's reported worktree command refusal ([#207](https://github.com/boxlite-ai/agent-tooling/issues/207));
both verbs share validation and state.

The gate rechecks existence, nonempty content, and a leading TL;DR
under 40 words. Details after that TL;DR may be dense; no total-word cap applies.
Bindings live in the worktree Git directory as `agent-tooling-design-doc.json` and
match its canonical root and branch (or detached HEAD). State reads and replacement
reuse `.agents/lib/verdict-audit-state.sh`; no success cache survives a failed read.
Notion child blocks fail closed; list items and code keep their block structure, so
literal text inside a block cannot forge a TL;DR.
Workflow and tracking issues invoke `boxlite-design-doc` by name.

Research is verified before code, not at commit or PR time
([design #253](https://github.com/boxlite-ai/agent-tooling/issues/253)):

- The pre-edit gate also requires `agent-tooling-design-research.json` beside the
  binding: a PASS bound to the root, branch, URL, and SHA-256 of the live content.
  Any edit to the design needs a new review.
- Missing or stale: the denial names the `design-research-auditor` route with
  `.agents/prompts/audit/design-research-task.md` and its criteria. A FAIL for
  unchanged content: the denial lists its findings.
- The auditor reads the design through `design-doc.sh show` and records through
  `design-doc.sh research`, which accepts one `{content_sha256, verdict, findings}`
  object for the live content only: PASS without findings, FAIL with one-line findings.
- It has no override card: it blocks only edits, never a turn's end or a commit, so
  the user can always redirect it. `host-parity.test.sh` names it as the one exception.

Commit-push auditors read the bound design through `design-doc.sh show`, which rechecks
the binding and prints the same authenticated provider read, so Linear and Notion
designs need no browser login. `.agents/prompts/audit/commit-push-criteria.md` checks
the diff against the design; neither it nor the PR question re-audits research.
Page length and design quality remain review criteria.
Every PR requires substantive project docs; reviewers assess their quality.
The design-doc gate does not inspect documentation diffs.
The pre-edit gate covers native editor, notebook, and patch tools on both hosts.
`.agents/lib/edit-scope.sh` passes edits whose targets all lie outside every work
tree and Git directory, both where they are named and where their links lead, such
as host scratch, memory, and plan files; a work tree without a `.git` entry counts
as outside. Relative working directories, `~` paths, dot segments, dangling
intermediate links, and missing or unparseable targets keep the gate.
Shell commands, other clients,
and arbitrary MCP writers are outside it; shell-created code still requires a design
under the workflow guidance. Shell commands retain host permissions and the separate
commit/push and PR gates, without a research-command allowlist.
`.agents/lib/pr-description.sh` checks `gh pr create`, `edit`, and `ready` before
review acknowledgment handling. Literal bodies must link the registered canonical
URL, including drafts; body-preserving operations fetch the published body and
match its branch and HEAD. GitHub renders the body; an exact anchor target outside
code must match the document. The same rendered HTML must contain a level-two
**How it works** section with content before the next peer or higher heading.
Each matching section is checked independently; any qualifying section suffices.
Nested headings alone, comments, quoted sections, example headings, and placeholder-only
text, including repeated or mixed placeholders, cannot satisfy it; prose, lists,
tables, and diagrams can. This applies to
drafts, replacement descriptions, ready operations, and metadata-only edits.
The render call is bounded to 20 seconds and 64 KiB;
failures block publication. Hidden source URLs do not count as links. Direct API
and browser PR writes remain outside this CLI check. Structural failures leave
the author-review acknowledgment untouched. Other peer-review artifacts follow the shared writing
rule; their classification and explanation accuracy remain review responsibilities.
PR authoring follows the [instruction owners](CONTRIBUTING.md#instruction-ownership).
The structural checker does not judge example relevance or accuracy.

### GitHub writing

The PR-review hook checks PR bodies (including drafts), issue/discussion bodies, comments,
reviews, close/reopen comments, release notes, and REST body/description fields.
`.agents/lib/github-writing.sh` reuses `.agents/lib/reply-summary.sh`'s block
limits: paragraphs at most 80 words and list items at most 40. Text that starts with a
valid TL;DR skips them, since readers already have the short version; complete
documents have no total-word cap.
Fences and tables are excluded from block limits; Chinese/Japanese characters
count individually. Empty text and inputs over 8000 shell characters fail closed.
The shared word counter recognizes table delimiters in linear time: each optional
outer pipe is grouped with its following whitespace, so an absent pipe cannot make
two runs compete for the same spaces. It retains Unicode whitespace, alignment
colons, escaped header pipes, and matching header/delimiter cell counts. Table words
still count toward the total. `.agents/lib/reply-summary.test.sh` checks these
semantics and rejects delimiter-shaped failures taking two seconds or more
([#259](https://github.com/boxlite-ai/agent-tooling/issues/259)).
Denials reuse the `boxlite-writing` skill; clarity remains a reviewer judgment.
Every inspected body also needs a TL;DR section of at most 39 words, including design
documents and published PR bodies checked on ready/metadata edits. A comment, close or
reopen text, or review body of 80 words or fewer is exempt once its blocks fit the
density limits ([#265](https://github.com/boxlite-ai/agent-tooling/issues/265)).
Only a peer or higher heading ends that section; nested headings do not reset it.
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
permissions are unchanged. Disclosure policy lives in the
[shared workflow](guidance/workflow.md#workflow).

The existing shell scanner supplies literal argv without executing it. Inline bodies
are inspectable; body files, stdin, editors, generated text and GraphQL text mutations are
rejected because their final published text is outside this check. Read-only commands
and body-preserving operations, including close/reopen without comments, pass through.
Visible writes behind unsupported launchers fail closed. GraphQL detection skips
comments and quoted strings and recognizes all ignored token separators.
This is a hook on recognized `gh`
commands, not a GitHub server policy: other clients, script files, browser edits and
later bot additions are outside it. Writing denials never consume an acknowledgment.
`scripts/sync-guidance.sh` splices `guidance/workflow.md`, which names the
`boxlite-writing` skill without embedding its body. The hash and dirty-revision
stamp depend only on workflow text; skill edits do not change generated instructions.
Agents load the skill through host discovery. Hooks and synchronization do not read
its body, so a missing local skill file does not prevent emitting the reference.

The repository's [Writing ownership workflow](../../.github/workflows/writing-ownership.yml)
runs `scripts/check-writing-ownership.sh`, the reference-delivery tests, and
`.agents/lib/concise-writing.test.sh` for the TL;DR summary rules on Linux.
`.agents/lib/reply-summary.test.sh` covers word counts and delimiter performance there.
The gate uses
`sync-guidance.sh --check-current` to reject stale output; ordinary consumer
`--check` keeps its warning behavior. It scans tracked and untracked Markdown for
eight-word matches or complete five-to-seven-word rules from the `boxlite-writing` skill,
ignoring case, punctuation, and wrapping. Only verified root instruction blocks
and fenced examples are exempt. Diagnostics name the copied passage's file and line;
paraphrased rules remain a review responsibility. This is repository CI wiring;
requiring its status before merge is a separate GitHub ruleset setting.
CI permits `/usr/bin/unshare` through AppArmor and probes user/PID namespace
creation before tests; Stop fixtures require the hook's process containment.

### PR size and stacks

PR preflight resolves the shell checkout from `tool_input.workdir`,
`tool_input.cwd`, event `cwd`, then the hook process directory. Explicit directory
metadata binds GitHub comparisons, design lookup, and review state to that
checkout; invalid or unavailable directories fail closed. Without metadata,
the existing `CLAUDE_PROJECT_DIR` review-state location remains supported.
Hosts without tool directory metadata can use `env -C /absolute/checkout gh pr …`
(`--chdir` also works where supported). The guard binds that literal directory
to the same checks. Relative, dynamic, repeated, and other environment overrides
remain unsupported; the wrapper does not waive size, design, or review checks.

The size policy in [the shared workflow](guidance/workflow.md#workflow) is enforced for supported direct
`gh pr create/edit/ready` commands by `.agents/lib/pr-size.sh`. It reads GitHub's
published comparison for creation, editing, and readiness, summing code additions
through `.agents/lib/pr-size.jq`. Source, scripts, configuration, and generated
code count, including comments and blank lines within those files.
Creation requires a published branch. Literal `--repo`/`-R` options support
`[HOST/]OWNER/REPO` before or after the subcommand. Creation also accepts
`--base`/`-B` and `--head`/`-H`, including `owner:branch`; separated,
equals, and attached short forms work. Duplicate or dynamic target options,
URL selectors, base-changing edits, and environment overrides remain unsupported.
Git pushes, direct API calls, and browser writes are outside this size check;
it is not a repository-wide enforcement boundary.

`.agents/lib/pr-target.sh` resolves one target for size, description, and review.
For creation, GitHub resolves the selected head across its fork network;
the hook requires it to match local HEAD, then compares pinned base/head SHAs.
Base selection follows the explicit option, the selected head branch's
`gh-merge-base` setting, then the repository default.
It does not infer a fork's repository name. For edit/readiness, the resolved PR
supplies its refs, repository, number, and body. Omitted selectors stay omitted
so GitHub CLI can use branch tracking; remote and local branch names may differ
when their commits match.

Size exceptions and review requests bind the host, repository, refs, commits,
and PR identity. Changing the target, including creation becoming an existing PR,
requires a new approval. Targets are rechecked after authorization and before
allowing publication. This narrows ref-movement races; it cannot make the later
GitHub write atomic with the hook. See [the target-resolution design](https://github.com/boxlite-ai/agent-tooling/issues/269).

The classifier excludes `*.spec.ts`, `*_test.go`, files under `tests` directories,
recognized prose names/formats, assets, tabular/log data, and dependency lockfiles.
Other paths are classified by filename: `docs/example.py` counts, and JSON/YAML
configuration and unfamiliar extensions count conservatively.
Build/dependency text manifests (`CMakeLists.txt`, `requirements*.txt`, and
`constraints*.txt`) also count.
Executable Markdown variants such as MDX count. A rename into a test path is excluded;
otherwise it counts if either name is code. The filter owns the exact exclusion list;
repository attributes cannot override it.

All filenames and statistics are validated before filtering. Comparisons with 300
or more returned files fail closed because GitHub may truncate the list, including
documentation-only comparisons. Exceptions retain the exact base/head binding;
excluded file changes still move HEAD and invalidate approval. For example, 400
added code lines plus 2,000 Markdown lines pass the size check; 401 prompt for a
choice. **Bypass limit** accepts the current diff without a written justification;
**Split PR** records a declined request. Retrying preserves that decision, and
changing the diff invalidates bypass. Other publication checks still run.

The workflow owns decomposition and stack requirements; the
[tracking-issue template](.agents/prompts/pr/split-pr-tracking-issue.md) supplies the plan structure.
There is no issue-creation gate.
Stack commands are not recognized by the per-PR publication checks: agents publish
each layer through the guarded commands, then use `gh stack link` with verified
existing PR URLs and matching bases. This is workflow guidance, not a new hook boundary.

### Timed confirmations

`.agents/lib/timed-user-prompt.sh` provides the reusable five-minute confirmation
lifecycle through `scripts/timed-user-prompt.sh`. Requests bind to caller-supplied
context and a random ID; retries preserve the deadline, late replies are rejected,
and acceptance can be consumed once. Callers select `split` or `keep-draft` as the
timeout fallback for `pr-size-exception:` or `reviewed:` respectively. The library
serializes state transitions; its prompt renderer describes an agent-opened,
non-blocking question. It never waits or opens a host dialog inside the state lock.

New requests and explicit renewals receive 300 seconds. Existing 180-second records
remain readable and keep their original deadlines; retries cannot extend them.

Size choices bind to repository, base/head, measured size, and session. The exact
label `Bypass limit` is accepted without a reason; `Split PR` records `declined`.
The same labels work through the CLI and native Claude replies. Existing prefixed
reasons remain readable for compatibility. Neither label authorizes a review request.

After an explicit human instruction, `renew STATE REQUEST_ID USER_REQUEST` creates a
new pending PR-size attempt after expiry or a split choice, with an empty response, new ID/deadline, and no native
question ID. The agent first remeasures through the guarded PR operation and shows
the current diff and split. Ordinary `request` calls cannot renew expired or declined attempts;
review requests cannot be renewed. Like `respond`, the CLI trusts the agent to relay
verbatim human text; it does not authenticate human identity.

Renewal exclusively writes an archive containing the expired or declined record, human instruction,
successor ID, and renewal time before atomically replacing the active state, all under
the existing request lock. Archive collisions and unsafe paths fail closed. If publication
fails after archival, the archive remains for inspection; no approval was granted.
Active-state replacement is the commit point. A failure before it leaves the old
attempt authoritative and blocks another renewal at the existing archive. A lost
result after it leaves the new pending ID/deadline intact; use normal `request` or
`status` to inspect it. Old IDs and late native replies cannot affect the successor.

The local PR gate uses this lifecycle for `reviewed:` acknowledgments, bound to
checkout, branch/head, session, and request ID. A retry cannot restart the deadline;
expiry leaves the PR draft or uncreated, and a successful operation consumes the reply.

The question UI is **agent-opened**, through the instruction in
`.agents/prompts/questions/timed-user-prompt.md`; no command hook opens a native dialog.
The deadline starts when the gate records the request.

Native question payloads and host routes are Markdown templates named `timed-question-*`
and `timed-route-*`. Question values are JSON-escaped before rendering. The
`timed-continue-*` templates own pending and expiry instructions; deadlines and
one-shot delivery remain state transitions in code.

Before normal Stop checks, `scripts/continue-timed-prompts.sh` resumes pending requests or delivers their timeout
fallback once: split oversized work, or leave an unreviewed PR draft/uncreated.
A declined size request delivers its splitting continuation once too, without asking again.
The agent performs the wait, issue creation, and splitting; these are not background
jobs. `.agents/prompts/pr/pr-size-exception.md` carries the size-specific wording;
`.agents/prompts/pr/pr-size-expired.md` describes splitting and human-requested renewal.
`.agents/prompts/pr/pr-size-declined.md` handles the user's split choice in both PR and Stop gates.

Local interactive sessions launched through `scripts/claude-with-timed-prompts.sh`
load this plugin with `--plugin-dir`, enable 300-second native idle dismissal, and
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
PR prompts are runtime-loaded through `subagent_prompt`: `.agents/prompts/pr/pr-review-question.md`
supplies the shared explanation check, `.agents/prompts/pr/pr-review-ack.md` supplies both
normal and bounded local acknowledgment instructions, `.agents/prompts/pr/pr-description-guidance.md`
directs authors to read and apply `boxlite-pr-preparation` and `boxlite-writing`, and
`.agents/prompts/pr/pr-author-review.md` supplies the GitHub comment. The renderer
substitutes placeholders; it does not
inline linked Markdown. Entry points explicitly instruct agents to load required
guidance. Missing, empty, or unrenderable prompts fail closed before consuming
a local acknowledgment or publishing GitHub acknowledgment success. A local recovery
prompt over 1200 bytes also fails closed. No embedded fallback copy is kept in Bash.
Writing denials deliver the checker diagnostic and skill reference directly;
they never substitute acknowledgment recovery text for writing instructions.

### Git gates

They run for any process. Auditing activates for nonempty `CLAUDECODE`,
`CODEX_SANDBOX`, or `AGENT_GATED`, or a live ancestor recorded by PreToolUse.
`.agents/lib/git-agent-origin.sh` shares classification across all three audit hooks.

For markerless shells, the manifests retain the launcher with `; exit $?` and pass
`--launcher-pid "$$"`. PreToolUse verifies that PID against its actual parent, then
records the launcher's parent and process-start token. Missing launcher metadata,
failed process lookup, older installed hooks, or failed writes block delegation.
Reload the plugin after updating; custom wiring must preserve the same launcher.

Records live under `agent-tooling-agent-shells/<PID>` in the worktree Git directory.
They activate audits without granting a PASS. Git checks at most 64 ancestors;
malformed or unreadable consulted records fail closed. Separate owners cannot
overwrite each other; stale start tokens cannot identify reused PIDs. Records
survive audit consumption and require no cleanup to stop matching after owner exit.
For example, a Codex shell without `CODEX_SANDBOX` still reaches the Git audit;
an unrelated human terminal in that worktree remains exempt.

| A person or agent does this | Gate | What happens |
| --- | --- | --- |
| Runs `git commit` | `.githooks/pre-commit` | Verifies the installation with `scripts/verify-installation.sh` and the guidance block with `scripts/sync-guidance.sh` in check mode, runs the chained framework hook, then checks the staged index against the audit. |
| The commit message is final | `.githooks/commit-msg` | Binds the audited subject, then publishes a receipt naming the commit by parent and tree. |
| Runs `git push` | `.githooks/pre-push` | The same installation and guidance checks; spends the receipt to skip re-auditing an identical commit, otherwise audits the pushed range; arms `.agents/watch/pr-watch.sh`. |
| Checks out, merges or rewrites | `.githooks/post-checkout`, `.githooks/post-merge`, `.githooks/post-rewrite` | `scripts/sync-installation.sh`, then the chained hook. |

New refs use the closest merge-base among the destination's remote-tracking refs,
measured by commits to the outgoing tip; default branches have no priority.
For `main -> stack-1 -> stack-2`, with `stack-1` already pushed, the audit starts at
`stack-1`. Existing refs use Git's advertised old SHA. Without a common ancestor,
the hook emits full history and an empty-tree diff.

Selection depends on local remote-tracking refs being current. A single-base range
can still include published side-branch history after merges.

### Audit producers

Producers for callers with no agent runtime.

| Who needs a verdict | Producer | What it does |
| --- | --- | --- |
| The Stop gate, synchronously | `.agents/hooks/audit/run-verdict-audit.sh` | Loads `boxlite-verdict-audit` into a model CLI with audit and native timer tools, which writes the turn's dossier. |
| A Git gate, CI or a plain shell | `.agents/hooks/audit/run-commit-push-audit.sh` | Runs `codex exec` with private writable scratch, read-only repository/evidence, and hooks/user configuration disabled; writes the same `last-audit.json` as the native auditor. |

Headless commit reviews bind scratch test reconstruction to the captured Git index
tree; an unstaged fix cannot validate a broken staged candidate. Push reconstruction
uses the verified ref-update context's new commit trees. The reviewer verifies each
reconstructed tree before using its tests. The parent rechecks commit tree, diff, and
subject before publishing. Scratch owns `TMPDIR`; general temporary directories and
additional write roots are excluded. Network access permits bound-design retrieval.
The private `bin/mktemp` adapter adds a scratch template only for default invocations;
explicit templates/options pass through. Reviewer commands prepend that bin directory
after shell initialization, covering Darwin's default-temp and login-shell behavior.
The design reader accepts `show [repo-root]`, so Bash redirections run in writable
scratch while the original target's branch and design binding remain authoritative.
Both commit-review routes use `commit-push-tests.md`: host receipts, complete native
execution records, or safe reruns must bind commands/results to the tested candidate.
Optional parent identity/host/time hints guide independent transcript discovery;
no transcript path or prior summary supplies proof. Sandbox-denied checks require
another verified evidence route or an unchecked finding.

Verification chooses proof per behavioral claim using base/source evidence. The
[workflow](guidance/workflow.md#test) owns full-revert defect proof for fixes to existing
behavior, including through a new API or wrapper. Wholly new contracts require no prior
equivalent and positive, negative, and boundary tests against the implementation;
new security boundaries need allowed/denied checks. Mixed changes apply both standards.
New entry points over unchanged, correct dependencies use new-contract tests; reusing
an existing backend or authorization helper alone does not require defect proof.
Missing APIs and compilation/setup failures do not establish the defect. The verdict
skill and commit-review instructions use this distinction without changing gate
decisions or dossier schemas. Contract suites verify shipped text and distribution;
native-host model behavior needs separate evaluation.

Native retrieval covers ordinary and custom tool calls, including content-item arrays
and nested orchestration results. Wrapper completion cannot certify a running command;
reviewers follow emitted continuation IDs to its terminal result. Initial session cwd
may precede a verified worktree transition. Command/subject and design checks precede
long reruns; denied sandbox capabilities send the reviewer to authentic execution records.

An agent with a built-in spawns the auditor itself, `Task` on Claude Code and
`collaboration.spawn_agent` on Codex, from the specs in `.claude/agents/`.

Stop classification and synchronous verdict auditing reuse that dispatch library's
`hook_host_kind` detector. Codex hooks use Codex; Claude Code hooks use Claude.
Each manifest command sets `BOXLITE_HOOK_HOST`, replacing inherited markers.
Generic hooks set `unknown`. Without a marker, legacy callers use single-root
inference; both roots remain ambiguous. Codex's compatibility aliases therefore
cannot redirect a declared Codex hook to Claude.
Explicit command overrides remain first. A known host never falls through to the
other provider; classifier failure uses regex and auditor failure blocks completion.
Unknown callers retain Claude-first availability behavior. The shared
`.agents/lib/codex-cli.sh` resolves `CODEX_BIN`, PATH, and the desktop binary without
deciding host identity. Codex classification runs read-only in scratch space with
hooks, shell tools, subagents, user config, and project instructions disabled;
global Codex instructions may still load. Its lookup probes and execution share the
existing bounded-capture deadline and output limit. See [design #287](https://github.com/boxlite-ai/agent-tooling/issues/287).

Host dispatch prose lives in `.agents/prompts/subagent/subagent-*.md`. The library selects
routes and JSON-encodes values, then renders all selected blocks before publishing
instructions. Missing, empty, or unresolved templates stop dispatch without partial
output; editing Markdown takes effect on the next invocation.

Runner delivery overrides, evidence-reading instructions, verdict triage, and audit
recovery tasks also load from `.agents/prompts/`. The hooks retain protocol errors,
classifier dispatch, verdict validation, and output limits; prompt edits do not
change those controls.

The classifier and both headless runners load trusted user proxy data through
`.agents/lib/audit-network.sh`; inherited environment choices win. Configuration
never comes from repository files or evaluated shell/PAC text. See
[network setup](.agents/hooks/audit/README.md#configuration).
`.agents/lib/audit-diagnostics.sh` retains bounded, masked stderr and execution
metadata. Verdict completion preserves the child exit status before considering
its dossier; a child that writes PASS and then exits nonzero cannot approve work.
Both count formats (`60/60 tests passed`, `60 passed, 0 failed`) use the classifier.
Counts and citations locate proof; the independent auditor verifies it.

### Shared finish reminders

`subagent_timed_prompt` in `.agents/lib/subagent.sh` renders
`.agents/prompts/subagent/timed-subagent.md` with an absolute deadline: 85 percent of the
timeout, capped at 510 seconds after rendering. Only the two headless audit runners use
it; native dispatch carries no reminder (see [commit/push attempts](#commitpush-attempts)).
Verdict and commit/push audits both default to 900 seconds, so each requests a report
by 510 seconds and keeps 390 seconds to write it; a 120-second audit requests one by
102. A 600-second verdict default left 90 seconds, too few for a retry's history and
reflection reviews: every reflection retry hit the hard timeout
([#234](https://github.com/boxlite-ai/agent-tooling/issues/234)).

The runner's model starts one native Monitor, stops new checks on its notice, and cancels
an unused timer with TaskStop. Each auditor owns its result schema. Existing hard timeouts
and publication checks remain in the runners; the reminder is cooperative. Hosts without
Monitor skip it, including the current isolated Codex CLI route. No scheduler or polling
fallback is installed. See [design #174](https://github.com/boxlite-ai/agent-tooling/issues/174)
and [Monitor limits](https://code.claude.com/docs/en/tools-reference#monitor-tool).

### Commit/push attempts

Native commit/push auditors no longer prepare or record history, and their prompt has no
timer: no Monitor event reached a Claude subagent in about 80 audits, and auditors cited
a timeout that never fired ([#240](https://github.com/boxlite-ai/agent-tooling/issues/240)).

- **Prepare.** On each deny, `preflight-commit-push.sh` prepares the attempt for the
  current binding, cancels an open attempt with another binding, and passes `attempt_id`
  and `history_path` to the auditor. It writes
  `auditor-control/audit-task.<scope>.commit-push-auditor.json` with the context, dossier
  path, and a deadline of `COMMIT_PUSH_AUDITOR_TIMEOUT` seconds.
- **Close.** On `SubagentStop` in Claude Code or Codex, `.agents/lib/commit-push-stop.sh` records a
  dossier bound to the attempt. Before the deadline it blocks once when the dossier is
  missing or has an `unchecked:` finding; otherwise it records `ERROR`. A check failure
  allows the stop, since the Git gate still holds.
- **Hosts.** Claude Code 2.1.296 and Codex CLI 0.162.1 both resumed a blocked subagent and
  then set `stop_hook_active`. The headless runner cancels the preflight's open attempt,
  then prepares and records its own.

The procedure is embedded literally into each task. Agent specs reference the supplied
procedure instead of duplicating it; prompt tests verify delivery, not live model compliance.
The reminder is cooperative: a shorter runner timeout also reduces the reporting
margin. A live smoke test must distinguish early completion with TaskStop from
notice-triggered reporting before the hard cutoff; neither proves the other.

Both commit/push paths render `.agents/prompts/audit/commit-push-criteria.md` into their
task through `subagent_prompt`; missing, empty, or unresolved criteria block dispatch.
The native spec owns task-input validation; the task template supplies its JSON record
and shared criteria. Verdict runners already load the full verdict spec, so their
task template supplies only the record and refers to that spec's rules.

### API compatibility

`scripts/api-compatibility.sh` checks every `*openapi*.yaml` basename, case-sensitively
at any repository depth, before
commit/push verdicts, including auditor overrides. Stop does not run it: the
change reaches the user through a finished reply. Unchanged contracts skip the
checker. The push hook checks actual API refs before the commit-receipt shortcut,
using the PR comparison base and Git's outgoing SHA throughout the check. Direct
`push` and `inspect-push` calls capture HEAD once. Workspace/index changes cannot
hide a committed API change or invalidate approval of an unchanged outgoing commit.
Breaking/default changes are reported by path with a recommendation to discuss in
a GitHub issue. The user must explicitly confirm skipping with
`api compatibility: skip`; no issue, link, or Notion token is required.
The UserPromptSubmit hook binds that choice to all changed paths and their
before/after specifications at submission. New affected paths invalidate it.
Specification hashes normalize physical CRLF to LF so Git line-ending conversion
preserves confirmation; other byte changes still invalidate it. Snapshots stay exact.

Git discovers tracked and unignored untracked files for local checks; push discovery
uses committed trees. Directory-only matches and `.yml` files are excluded.
`api_contract.py` reads matching specifications at the merge base and either the
working copy (commit/inspection) or selected commit (push/`inspect-push`), and
classifies each with pinned oasdiff 1.33.0 JSON output. No consumer configuration
exists; unrelated files and submodules never enter comparison. Complete contract
additions/deletions require manual review. User confirmation skips breaking/default
enforcement only; malformed inputs and SDK request-test requirements still block.
Inspection exports native changelog, breaking, and detailed diff JSON with exact
before/after snapshots into a fresh private directory per changed specification under
the worktree Git directory. Stdout returns a `specifications` list of repository paths,
defaults, and artifact paths. These files persist for bounded auditor reads.
Push auditors use `inspect-push` to capture committed specifications.
Python does not extract request-test requirements. The auditor uses the reports,
schema context (including parameter content and ancestor readOnly), and consumer SDK
code to identify new optional request fields and verify their tests against the policy.
Response-only fields need no request tests; shared writable additions need coverage
for each affected operation. The plugin does not build the consumer SDK.
Approvals live in the worktree Git directory. Writable state remains a workflow
boundary, not a sandbox. See [policy](guidance/api-compatibility.md) and
[commands](scripts/api-compatibility.md).

### Author review acknowledgment

GitHub events run `.github/workflows/author-review.yml` from trusted base/default-branch
code. `scripts/pr-author-review.sh` checks dependencies and calls the single facade
`pr_author_review_run` in `.agents/lib/pr-author-review.sh`. This gate is independent of
all local hooks above.
The local PR hook and GitHub author review load the same [review question](.agents/prompts/pr/pr-review-question.md).
It applies `boxlite-writing` and asks whether the explanation fits the current diff.
The preparation skill uses that question for its self-check; self-review cannot
supply the human's acknowledgment.
Acknowledgment remains bound to the commit SHA and does not certify description quality
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

Audit history components:

| Entry point | Responsibility |
| --- | --- |
| `scripts/audit-reflection.sh` → `.agents/lib/audit-reflection.sh` → `.agents/lib/audit-reflection.jq` | Serialize bounded state transitions; deduplicate attempts; validate immutable bindings; atomically write regular files. |
| `.agents/lib/audit-reconciliation.jq` | Stable finding IDs, dispositions, coverage, provenance, and reopening evidence; reject unresolved PASS. |
| `.agents/lib/audit-reflection-contract.jq` | After two failures, require current reflection covering every failed ID and an independent sufficient assessment for PASS. Freeze active reflection; invalidate after failure. |
| `scripts/audit-reflection-gate.sh` → `.agents/lib/audit-reflection-gate.sh` | Bind scoped verdict/Git audits before launch and acceptance; snapshot evidence; recheck prompt epoch; reconcile dossiers. |
| `.agents/prompts/audit/audit-reflection.md`, `.agents/prompts/audit/git-audit-history.md` | Shared reconciliation contract and native Git history review; hooks prepare and record native Git attempts. |

Cycles bind a context of `repo_root`, `session`, `epoch`, `branch`, and `gate`; cap at eight failures,
sixteen attempts, and 10 MiB. PASS closes a cycle; the next operation starts another.
Preparation and inspection share `audit_reflection_ready`: a terminal PASS needs no
new reflection even though recording it changes the history hash. The reflection
retains the failed history it explains. Git still validates the approval's bindings
and freshness before consuming it; changed staged content requires another audit.
Runner failures record ERROR; cancellation is separate. Retain at most four closed cycles per context,
four retired contexts/session, and the latest immutable input/context. Identity-checked
cleanup preserves current-epoch evidence. Snapshots retain bounded transcripts,
sanitized headless diffs, or immutable native Git trees.

The output schema and reconciliation share finding IDs: `F1` through `F9999`;
only a new finding accepts `NEW`. Dispositions and conflicts name existing registry
IDs. Coverage partitions the current attempt's snapshot keys exactly once across
`reviewed` and `unread`; for a snapshot containing only `diff`, use `["diff"]` in
one array. Runtime rejects omitted, invented, or duplicated keys and any unread
evidence on PASS. The static schema cannot enumerate per-attempt snapshot keys.

Preparation reserves 512 KiB beyond the active cycle for the next snapshot/binding,
outcome, registry growth, and reflection metadata. Closed cycles remain removable.
Inspection and preparation share this capacity check; exhausted completed cycles
stop before model launch, while pending results can still be recorded. Storage and
retention readers share the 10 MiB limit. Auditors read relevant history in bounded
chunks; individual requests, dossiers, and transcript/tree reads keep their own bounds.

Stop triage/summary shortcuts and push receipts must respect unresolved history.
Exhausted Stop audits return `continue:false` and INCOMPLETE; Git remains denied without
PASS. Unscoped callers retain legacy contracts with omitted/null history assessments.

All under `.agents/state/`, gitignored, and suffixed by session scope wherever more
than one session can share a checkout.

- `last-verdict.json`: the turn dossier the Stop gate consumes.
- `last-verdict.prev.json`: a FAIL parked when the fix moved the tree, so the next audit re-checks its findings.
- `verdict-decisions.log`: one line per Stop-gate decision, elapsed seconds, rung and outcome.
- `audit-diagnostics.jsonl`: bounded execution records for headless audit attempts; never approval.
- `verdict-last-uuid`: the id of the message the gate last judged.
- `verdict-prompt-epoch`: the current prompt epoch.
- `verdict-request-context.json`: origin prompt epoch and Git binding for retained execution, managed by `.agents/lib/audit-request.sh`.
- `verdict-stop-message.jsonl`: Codex's Stop message preserved in transcript shape when no transcript exists.
- `last-audit.json`: the commit or push dossier. `last-audit-handoff.json` carries the gate's request to the auditor.
- `commit-audit-receipt.json`: the receipt commit-msg publishes and pre-push spends.
- `pr-reviewed.json`: the typed PR-review acknowledgment, bound to branch, HEAD, and request ID.
- `pr-review-request.json`: the review deadline and response lifecycle.
- `pr-size-request.json`: the size-choice deadline, diff binding, and exact response; renewal archives retain the legacy `<state>.expired-<request-id>.json` name for expired or declined requests.
- `auditor-control`: a directory of escalation, completion, grant and event records for running auditors and overrides.
- `last-api-failure.json`: the kind of API error that ended a turn.
- `api-resume`: the recent resumes and the unspent wake hashes of the API-failure resume.

### Verdict retry handoff

A request context binds the original prompt epoch, exact claim checksum, branch,
HEAD, and full working tree. New human prompts always rotate the prompt epoch and
revoke override grants. They preserve a running verdict request only while its Git
binding and bounded context remain valid; changed or unsafe state uses cancellation.
History can finish that original attempt while its request remains current.
Only its original turn may consume the result. An unchanged completed dossier may
be handed to a later auditor as prior evidence, with freshness preserved, never as
approval of the later turn. For example, “what's happening?” leaves unchanged work
running; a later deployment claim gets a new audit generation.

A session retry captures the prior same-generation FAIL's normalized JSON and inode
under the runner's leases before launching the auditor. To publish a replacement,
the new result must pass history reconciliation and stage validation. The runner rechecks the
captured JSON, inode, and request before retiring that exact file. Publication remains
no-clobber: a competing file, even with the same generation, is preserved and blocks
the retry. Prompt revocation and final lease checks still cancel publication.
For example, an unchanged-tree retry can resolve F1 and publish PASS while retaining
both attempts in history. See the [design](https://github.com/boxlite-ai/agent-tooling/issues/171).

## Boundaries

- Pending delivery: `.agents/lib/pr-watch-pending.sh` retains up to 128 events
  outside the replaceable generation journal. Content-derived event IDs exclude
  timestamps and generation IDs. Publishing precedes detection deduplication;
  acknowledgment removes the exact pending record. Full capacity stops polling
  with an error instead of silently discarding unread events. Replays after an
  interrupted acknowledgment are accepted: delivery is at least once. Consumers
  may replay retained events after a crash without a separate receipt ledger or
  mandatory history reconciliation.
- Producer launch: `pr_watch_start` in `.agents/lib/pr-watch-state.sh` starts the
  complete log supervisor in a new POSIX session before forking its children.
  Both `.githooks/pre-push` and `.agents/watch/pr-watch-start.sh` use this bounded
  readiness handshake. Caller process-group cleanup cannot kill the logger or
  producer; a repeated start returns the live generation. This is not service
  supervision or reboot persistence.
- PR delivery: `.agents/hooks/post-remote-write-watch.sh` requests one ten-minute
  event-delivery schedule per chat. `.agents/prompts/watch/pr-watch-schedule.md` owns setup
  and the saved prompt; hook output supplies its absolute JSON path or policy-relative
  compact path. The agent registers through the app and verifies saved bindings.
  `.agents/watch/pr-watch-keepalive.sh` calls `pr_watch_schedule_tick` from
  `.agents/lib/pr-watch-schedule.sh`: validate targets, reconcile each worktree, return
  active/stopped counts by default. With `--events`, it uses normal session reads
  and emits target-bound batches of up to 16 events for each of at most 32 targets;
  empty reads return zero with no stdout. Errors/degraded coverage return nonzero
  with stderr; independent targets still deliver. Busy event reads return 75,
  deferring retirement without an alert. Session
  `--keepalive` retains status-only recovery and rejects start/cancel/ack flags.
  Scheduled and foreground turns report before acknowledging exact event IDs.
  Before pausing all stopped targets, drain terminal events and recheck after the
  final status query. Reused schedules update their prompt without changing pauses
  or notification preferences. Claude retains Monitor; no hook-health checks.
  `.agents/watch/consumer-lifecycle.md` defines draining, cleanup, and
  failure reporting. `.agents/watch/pr-watch-session.sh` persists branch-bound
  intent, monitoring deadlines, and bounded recovery attempts outside execution
  sessions. A per-target descriptor lease serializes reconciliation. Healthy
  polling resets consecutive failures; cancellation and deadlines prevent
  automatic resurrection. Pending delivery survives host restarts. The hook accepts
  `command`/`stdout` or `cmd`/`output`; supplied nonzero/null exit codes cannot arm.
  Saved task context references that policy and saved worktree/branch targets.
  Unexpected stream endings reconcile durable intent; degraded coverage is
  reported while bounded retries continue. Reuse only confirmed task-local PR schedules;
  preserve unrelated automations, explicit pauses, mutes, cancellations, and deadlines.
  Missing scheduling support retains foreground delivery and reconciliation. Consumers
  omit routine status and acknowledgment prose when nothing new needs attention.
  Host quiet completion and rendered reply suppression require separate verification;
  empty script output alone proves neither. [#282](https://github.com/boxlite-ai/agent-tooling/issues/282)
  tracks native-host delivery and silence. Empty replies and alert muting do not prevent
  scheduled task inputs. Registration and pending storage alone do not prove delivery.
  New events get concise human-facing summaries.
  Text-contract tests guard required instructions, not model obedience or live delivery.
- Watcher to commands: `.agents/watch/pr-watch.sh` owns the external command group
  and its timeout/output monitors. Monitor cancellation uses KILL and wait because
  those observers have no shutdown work; command groups retain TERM then KILL.
  The launch-cleanup test has an independent deadline and reports owned processes
  before forced teardown, preserving the original cleanup assertion.
- Host to hook: each manifest command sets `BOXLITE_HOOK_HOST` to `codex`, `claude`, or `unknown`. `.agents/lib/hook-host.sh` validates this exported routing value before legacy root inference. Codex exports both root names as aliases; Claude commands prefer `CLAUDE_PLUGIN_ROOT` and Codex/generic commands prefer `PLUGIN_ROOT`, with the other name as fallback. Session markers never decide routing. The explicit marker is not authorization or runtime attestation.
- Hook to agent: a hook is a bash process and cannot spawn a subagent. It emits text naming the route the calling host has, and the agent takes it. `.agents/lib/subagent.sh:8`
- Agent to auditor: the auditor spec is the only writer of a dossier. Gates read verdicts and never write them.
- Gate to state: each artifact is bound to what it judged. Turn dossier: branch, HEAD, tree hash, generation, session scope, prompt epoch; a mismatch is discarded and the Stop gate falls through to fresh detection (`.agents/hooks/audit/preflight-verdict-check.sh:28`). Commit and push dossier: branch, HEAD, the staged or pushed diff, the command, and for a commit the subject, for 5 hours after it is written; a mismatch or an older dossier denies until a fresh audit (`.agents/hooks/preflight-commit-push.sh:677`). Receipt: parent, tree, subject. Research verdict: root, branch, design URL, and the SHA-256 of the content the auditor reviewed (`.agents/lib/design-doc.sh`).
- Incomplete evidence: a missing or empty source during refresh retains the published failed snapshot. Audit re-entry reads and validates that bounded snapshot before consuming the dossier; loss of the original source cannot become `empty-allow`. An initially absent or empty transcript still has nothing to judge.
- Auditor transcript: the task supplies `parent_session_id`, `parent_host`, and
  `audit_started_at` with the existing repository and dossier bindings. The auditor
  discovers the full source; no transcript path is supplied. Known hosts have storage
  hints; unknown hosts investigate available tools, metadata, configuration, and storage.
  Parent identity, repository, and target turn must match. Missing legacy session IDs
  require verified parent linkage; unresolved identity or completeness requires FAIL.
  Local evidence uses a recorded file identity and prefix length/digest, checked again
  before delivery. API evidence uses complete records through a fixed item boundary,
  with ordered IDs and content/version revalidation; unchanged IDs alone are insufficient.
  [boxlite-verdict-audit](.agents/skills/boxlite-verdict-audit/SKILL.md) owns the complete
  procedure, including input validation, proof standards, verdicts, and dossier output.
  The agent definition retains launch metadata and a read-and-apply link. The runner
  loads the skill explicitly for override, Claude, and Codex launches and identifies
  its source location so relative references resolve. Missing skill or discovery guide
  fails closed. Native agents follow the same link without duplicating audit rules.
  The skill guides native-record search and command/result linkage with 64 KiB outputs
  and no cumulative transcript-read ceiling; the audit deadline still applies.
  For example, the auditor can find a late test result and earlier execution records in
  the discovered source despite their omission from history previews. No claim JSON or
  retrieval service is required ([#293](https://github.com/boxlite-ai/agent-tooling/issues/293)).
- Final-turn bookkeeping reader: `.agents/lib/verdict-audit-state.sh` reads a transcript back from its end to the last real user message and decodes at most `verdict_audit_final_turn_max_bytes` (64 MiB) of it. Earlier history is only hashed into `source_sha256` for this summary; the reader's 15 s alarm bounds the rest ([#262](https://github.com/boxlite-ai/agent-tooling/issues/262)). Stop passes its bounded snapshot to the runner for history. Direct runner callers may supply a bookkeeping source or `-` for an explicit incomplete snapshot. The runner retains only a private bounded history file and cleans it up; it does not copy the full transcript. History is context for discovery, never substitute execution proof.
- Bookkeeping snapshot selection: after the existing preview reductions, binary search retains
  the largest earliest-tool prefix fitting the cap, including the final LF. Claims
  remain whole or use the existing truncated fallback. Fixed-preview sizes increase:
  each new record exceeds any shrinkage in omission counters. The unchanged builder
  and UTF-8 encoder preserve snapshot bytes; selection needs logarithmically many
  candidates ([#264](https://github.com/boxlite-ai/agent-tooling/issues/264)).
  [Selection checks and benchmark](tests/snapshot_selection/README.md) cover this
  size assumption, exact boundaries, and comparison with the previous scan.
- Stop gate to verdict check: after the TL;DR check and timed confirmations, `.agents/hooks/stop-gate.sh` `exec`s `.agents/hooks/audit/preflight-verdict-check.sh` with the payload unchanged, so the check runs as the hook process: its output, stderr, exit status, and signal handling are the hook's ([#255](https://github.com/boxlite-ai/agent-tooling/issues/255)). Missing dependencies fail closed.
- Mandatory summary: `.agents/lib/concise-writing.sh` checks for an ATX TL;DR heading outside fences, quotes, and comments, whose first block is a paragraph opening with a word, emphasis, a link, or inline code. A list item, thematic break, link or footnote definition, setext heading, or table cannot stand in for that paragraph ([#257](https://github.com/boxlite-ai/agent-tooling/issues/257)). Human-facing replies over 80 words, by the same counter, must start there ([#265](https://github.com/boxlite-ai/agent-tooling/issues/265)); the entire section has at most 39 words using the shared Unicode-aware counter. Each denial is one line: the failed condition, then a literal fix; length failures report the count and limit and ask for a same-level heading after one short sentence. Missing, misplaced, malformed, and overlong TL;DR denials end with `apply boxlite-writing` unless the caller passes `no-hint`. Only the GitHub writing check does, because the PR gate appends its own reminder. Stop checks the TL;DR only when `stop_hook_active` is false: one correction can continue a turn, then the check is skipped, including after unrelated Stop continuations. GitHub and design-document checks remain mandatory. Missing Stop text falls back to a bounded transcript snapshot; unreadable or truncated snapshots fail closed even on continuations. Explicitly empty reply text remains empty without replaying earlier text; verdict auditing still runs. Internal instructions and tool payloads need no summary. Sentence simplicity remains a writing instruction.
- Enforcement scope: Stop checks the final reply after generation; it cannot retract streamed commentary. GitHub checks cover recognized CLI calls, not browser or connector writes. Design checks cover fetched GitHub, Linear, and Notion content; native Notion headings retain their structure. Shared guidance applies to every human-facing output across these surfaces.
- Shared writing skill: `boxlite-writing` owns writing rules. Workflow, Stop TL;DR denials, GitHub reminders, PR guidance, and the optional prompt hook reference it by name. `concise_writing_reminder` supplies the shortening request the PR gate appends to GitHub writing denials, without reading skill files. Paragraphs over 80 words or list items over 40 trigger it only in GitHub text that does not start with a valid TL;DR; Stop never asks to shorten a reply.
- Consumer to tooling: consumers float on `tooling.ref`, run only the adopted revision recorded in `.git/agent-tooling/current`, and reach the network only from bootstrap and refresh. `templates/install.sh:11`, hold at `:15`. One refresh runs at a time, held by `.git/agent-tooling/.refresh.lock` (`scripts/refresh-installation.sh`), and a refresh that finds it held skips. Breaking that lock would race its holder, so one left behind by a killed run is reported rather than cleared: `scripts/verify-installation.sh:22`, which every commit and push runs, names it once it is an hour old. Without that, the automatic refresh is dead and only a log nobody reads would say so.
- Lifecycle environment: `sync-installation.sh` and `refresh-installation.sh` capture the consumer root, clear Git's repository-local variables plus `GIT_NAMESPACE` through `.agents/lib/git-environment.sh`, then enter that root before verification or adoption. This protects older committed installers too: a linked-worktree checkout cannot redirect cache initialization into the consumer through inherited `GIT_DIR`. Discovery or cleanup failure prevents installer execution; sync remains nonblocking. Chained hooks retain their parent environment; global Git and transport configuration remain available.

- Offline installation repair: `templates/install.sh` routes the recorded cache through
  the installation lock, cache revision check, and `scripts/setup.sh`, then runs
  `scripts/verify-installation.sh` before success. This repairs worktree-local hooks
  without changing the shared record, adoption history, or last-check stamp. An invalid
  cache or profile fails closed. `scripts/codex-plugin-bootstrap.sh` and
  `scripts/claude-plugin-bootstrap.sh` keep the initial validity probe quiet, but
  report verifier and installer diagnostics if repair or pre-upgrade refresh fails.

- Linked-worktree plugin repair: Claude Code's project-scoped `plugin update` resolves
  the main checkout's record, so in a linked worktree it can succeed while this
  checkout's record stays stale. `scripts/claude-plugin-bootstrap.sh` then runs
  `plugin uninstall --keep-data` and `plugin install`, which resolve this checkout, and
  restores the tracked `.claude/settings.json` byte-for-byte because uninstall edits it.
  A plugin still stale after the reinstall fails closed.

### Startup updates

The consumer host templates load `scripts/claude-plugin-bootstrap.sh` or
`scripts/codex-plugin-bootstrap.sh` from the recorded SHA. The consumer installer
also delegates to `scripts/install.sh` once present; its standalone fallback can
bootstrap an empty cache. Migration requires tooling 0.1.35 and all three released
consumer templates. Automatic runs never overwrite those tracked files.

`.agents/lib/plugin-bootstrap.sh` shares the release check and adopted-runtime
lookup. The host initializes failure state before refresh, then transfers to the
newly adopted host implementation with the original input. Claude `--check` reads
session state only. Both equal-old versions and a host updated ahead of repository
tooling are reconciled; refresh opt-out requires explicit repair on disagreement.

`refresh-installation.sh --if-due` owns the polling timestamp under its refresh
lock, shared with Git lifecycle callers. Failed attempts are stamped too. It
retains an old installation after a failed download only when profile and
installation validation both succeed. A busy lock skips; abandoned locks retain
the existing warning and manual recovery path.

`.agents/lib/tooling-command.sh` bounds individual Git and native host commands
using a child process group, TERM, a brief KILL grace, and reaping before returning.
Polling/adoption gets 30 seconds; host reconciliation gets 120 seconds, including
mismatch repair. Shell owners release their own locks on EXIT and terminate on
INT/TERM. Claude arms settings restoration before uninstall, restores bytes before
reporting success/failure, and keeps failed sessions blocked. A restoration error
retains and names the backup. External SIGKILL can prevent cleanup; no automatic
recovery or hot replacement of already loaded sessions is claimed.

## Test-run receipts

The recorder accepts direct integral signed 32-bit `exit_code` metadata: zero passes,
nonzero fails, and an explicit interruption records `interrupted`. A non-null session
or process ID means the result is pending, even if it also contains an exit code.

Claude's successful `PostToolUse` may omit an exit code. Its recognized result has
string `stdout` and `stderr`, plus optional boolean `interrupted` and `isImage` fields.
`PostToolUseFailure` retains its separate failure/interruption handling.

Unknown fields or envelopes, invalid exit codes, background jobs, and output-only
responses leave no receipt. Some native Codex hooks return raw output without exit
metadata; those runs remain unobserved. Printed JSON or exit-status text cannot
establish completion. Receipt schema, working-tree binding, and silent hook exit stay
unchanged. See [design #270](https://github.com/boxlite-ai/agent-tooling/issues/270).

## Invariants

Often stated as an absence. Each names the line that states or enforces it.

- A gate never produces the verdict it checks. `.agents/hooks/preflight-commit-push.sh:6`
- A PASS never reaches the model: nothing of a consumed PASS or its advisories is shown to the model, and advisories go to the human only. `.agents/hooks/audit/preflight-verdict-check.sh:17`
- A stale or mismatched turn dossier is discarded, never blocked on. `.agents/hooks/audit/preflight-verdict-check.sh:28`
- A readable snapshot with no assistant text ends unjudged under `blind-allow`; a failed or truncated snapshot requires an audit. `.agents/hooks/audit/preflight-verdict-check.sh:53`
- A message is never judged twice. `.agents/hooks/audit/preflight-verdict-check.sh:62`
- A parked dossier supplies prior evidence to a fresh audit; it cannot approve a new turn. `.agents/hooks/audit/preflight-verdict-check.sh`
- A reply that leads with a valid TL;DR is never asked to shorten; the Stop gate's only writing check is that TL;DR. `.agents/hooks/stop-gate.sh:4`
- No editor or patch edit lands in a repository before a research PASS for the bound design's live content. `.agents/hooks/preflight-design-doc.sh:2`
- The prompt hook never signals a PID chosen from workspace state. `.agents/hooks/cancel-verdict-audit.sh:13`
- A hook emits text; only the agent spawns a subagent. `.agents/lib/subagent.sh:8`
- Humans are not gated; named harness variables or recorded live ancestors activate audits. `.agents/lib/git-agent-origin.sh`
- A receipt names a commit by parent and tree, never by a diff hash. `.agents/lib/commit-audit-receipt.sh:10`
- An override is recorded as `OVERRIDDEN BY USER`, never PASS, and expires within an hour. `.agents/hooks/auditor-control.sh:707`, `.agents/lib/auditor-override-state.sh:55`
- A StopFailure hook's result is ignored. A turn resumes only through an `asyncRewake` exit 2, at most three times per session in ten minutes, each resume recorded before it is announced. `.agents/hooks/resume-after-api-failure.sh:125`
- An `asyncRewake` wake is internal only while its one-time nonce is unspent, and its owner spends it on first acceptance; a copy of a spent wake, or text riding after one, is a real prompt. `.agents/lib/hook-wake.sh:19`
- An auditor's wake stays internal for 300 seconds after its escalation, or after the auditor stops once it has stopped. A foreground auditor blocks the parent turn, so the host delivers its wake only after the stop. `.agents/hooks/auditor-control.sh:578`
- A closed escalation survives one auditor lifetime (3660 seconds) after it closes, so it can still authenticate a late `SubagentStop`; the next prompt in its session retires it after that, which keeps the prompt hook inside its 3-second lock. `.agents/hooks/auditor-control.sh:318`
- A commit or push is denied with a reload instruction when the session's loaded plugin version differs from the version the git hooks run: the loaded auditors cannot read the newer gate's audit tasks. `.agents/hooks/preflight-commit-push.sh:819`
- A finished auditor's completion is internal only while its credit lasts. Claude names the auditors under this plugin's namespace and submits each completion twice, as an `agent-message` hand-back and a `task-notification`, so `SubagentStop` credits two deliveries for 300 seconds. A hand-back that arrives while the auditor is still running is accepted once, and the stop then credits one; a replay, an uncredited sender, or a column-zero frame line inside the report is a real prompt. `.agents/hooks/auditor-control.sh:48`, `.agents/hooks/cancel-verdict-audit.sh:108`
- Test evidence must bind the command, completion, and source state through host receipts, complete native records, or safe reruns; current-tree inference cannot certify an earlier run. `.agents/prompts/audit/commit-push-tests.md`
- A FAIL verdict gets a fresh audit once a test runs after it; otherwise the gate repeats its findings. `.agents/hooks/preflight-commit-push.sh:375`
- Codex's hook-event set is closed; an unknown key loads no hooks at all. `host-parity.test.sh:24`
- Every wired command declares its host and prefers its host's plugin root, with the alternate root as fallback. `host-parity.test.sh:30`
- A malformed hold fails closed. `templates/install.sh:15`
- `.agents/state/` is never committed. `.gitignore:1`

## Stop gate decisions

Timed confirmations run first and persist their own lifecycle. After the TL;DR check,
`.agents/hooks/audit/preflight-verdict-check.sh` logs each decision below as a rung and
an outcome, in this order. Line numbers are in that script; a pair logged at more than
one line cites the first.

| Rung | Outcome | When | Line |
| --- | --- | --- | --- |
| override | overridden-allow | A valid `OVERRIDDEN BY USER` grant exists for this prompt epoch; the use is logged and the gate opens. | 716 |
| history | exhausted-stop | Failure, attempt, or remaining-capacity exhaustion terminates Stop with INCOMPLETE; no further audit runs. | 737 |
| extract | truncated-block | The bounded final-turn snapshot is unreadable or exceeds its byte limit; an independent FAIL dossier is required. | 1852 |
| extract | blind-allow | The transcript has content but no assistant text after a 2 second wait; the turn ends unjudged. | 1859 |
| extract | empty-allow | No transcript, or nothing in it; there is nothing to judge. | 1862 |
| cancellation | discard-generation | A cancellation record exists for the requested generation; a newer prompt revoked it. | 1876 |
| dossier | discard-generation | The dossier's generation is not the requested one. | 1954 |
| dossier | discard-stale | Branch, HEAD, tree hash or age no longer match; the dossier is discarded and triage runs. | 1960 |
| dossier | PASS-allow | A fresh, matching PASS; consumed, and any advisories are shown to the human only. | 2003 |
| dossier | discard-revoked | A matching dossier whose request could not be consumed because its generation was revoked or replaced. | 2013 |
| dossier | IN_PROGRESS-allow | Proof deferred while the parent pauses or asks the user; allowed with a note. | 2021 |
| dossier | FAIL-block | Findings block the turn; advisories stay out of the reason; unchanged text reuses this FAIL instead of re-running the model. | 2034 |
| audit | inflight-allow | A live runner holds the lock for this session; its verdict gates the next turn end. | 2158 |
| race | stale-allow | The newest message id is the one already judged; a message is never judged twice. | 2183 |
| harness | noise-allow | Every non-empty assistant line is harness text such as an API error; no model call. | 2215 |
| assertion | match-block | Whole-line "done" or line-initial confirmation; audited with no classifier call. | 2224 |
| runner | ERROR-block | The runner did not complete; safe execution metadata and a diagnostic path accompany the block. | 1790 |
| triage | oversized-block | The turn text exceeds the classifier byte cap; sent straight to the file-backed auditor. | 2231 |
| triage | NO-allow | The fast model found nothing taken on trust; allowed and announced to the human. | 2240 |
| triage | YES-block | The model found a conclusion the reader must take on trust; the audit runs inside this Stop. | 2244 |
| regex | none-allow | No model reachable and no fallback pattern matched. | 2252 |
| regex | match-block | No model reachable and a fallback pattern matched. | 2256 |

Dossier shape, from [boxlite-verdict-audit](.agents/skills/boxlite-verdict-audit/SKILL.md): `branch`, `head`, `tree_hash`,
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
- **guidance block**: the hash-marked workflow with its named writing-skill reference in a consumer's `AGENTS.md`; missing or edited fails the gates, behind only warns.
- **twins**: `hooks/hooks.json` and `hooks/codex-hooks.json`, equivalent after normalizing host identity, root preference, background delivery, and host-only events. Generic hooks share the latter's events with explicit unknown identity.
- **watch**: one run of `.agents/watch/pr-watch.sh` after a push, streaming CI and PR events as JSON lines under one watch id.
- **wake**: the turn Claude Code starts when an `asyncRewake` hook exits 2; its prompt carries the hook's stderr in a reminder after the host's envelope, and it is internal only while its one-time nonce is unspent.
- **author review acknowledgment**: a new, unedited `/reviewed <full-head-SHA>` PR comment from the PR author; the CI gate publishes its verdict on that commit.

## Code map

Directory guides cover [host wiring](hooks/README.md),
[hook scripts](.agents/hooks/README.md), [audit gates and runners](.agents/hooks/audit/README.md),
[Git hooks](.githooks/README.md), and
[maintenance commands](scripts/README.md), with entry points and focused tests.

```text
hooks/                  the twin host hook manifests
.agents/hooks/          one script per gate or producer, listed above
.agents/lib/            shared state, receipt, host, wake and rendering libraries; sourced, never run
.agents/prompts/        editable Markdown prompt templates, read when a request is built
.agents/watch/          the pr-watch producer and its stream and attach consumers
.agents/skills/         boxlite-design-doc, boxlite-clean-code, boxlite-pr-preparation, shell-engineering, boxlite-visualize, boxlite-examples, boxlite-distill, adversarial-iteration, boxlite-writing
.claude/agents/         the two auditor specs
.githooks/              the universal Git gates
scripts/                profile validation, installation verify/sync/refresh, setup, guidance splice, unattended-run supervisor, author review acknowledgment
guidance/workflow.md    workflow naming shared skills for consumers
host-parity.test.sh     what keeps the three hosts loading the same assets
architecture.test.sh    what keeps this map honest
```

Use `boxlite-visualize` to explain architecture, execution sequences, or source call
paths; for example, "Use boxlite-visualize to show the cloud deployment architecture."
The skill produces `diagram.md` and `evidence.json`, then validates rendering, fit,
and source traceability into `validation.json` before visual inspection.

Skills live in `.agents/skills/`; Claude and Copilot use the `skills/` symlink.
Codex declares the canonical directory directly so skills and references survive
cache installation without symlinks. Its auditor routes already use
`.claude/agents/` directly; Claude and Copilot keep the `agents/` alias.
`host-parity.test.sh` checks both source resolution and a copy containing only
regular files, including each skill's resources and canonical auditor paths.

The `boxlite-clean-code` skill keeps essential coding decisions, a reversible
refactoring loop, and verification guidance in a compact `SKILL.md`. Its example
index loads topic addons under `references/` only when relevant. The entrypoint
also directs implementation/review of non-obvious algorithms, layouts, protocols,
ownership, or concurrency to the comment reference. It teaches visual models,
worked traces, and example verification; this is agent guidance, not a runtime
gate. Host skill paths expose the complete directory; standalone
sharing copies that directory, including references. It preserves the receiving
repository's workflow and permission boundaries and needs no plugin scripts.
Shared workflow, shell guidance, fixer prompts, and audit criteria reference it by
name for general coding and test quality. Their own instructions retain repository
gates, Bash contracts, iteration receipts, and audit evidence requirements.

`boxlite-reading-highlights` selects exact source phrases and reviews their meaning
independently of rendering. Its optional browser reference covers reversible page
highlighting, guarded batch application, and reviewed-plan caching. Long scopes can
use authorized text-only workers; one owner controls the destination. Cached plans
require matching live text, sentence fingerprints, scope, and selection settings;
they contain data and do not automatically restore marks after reload.
The shared skill directory exposes both. Codex UI
metadata uses the same skill name. No browser tool or runtime dependency is required
for text selection.

`boxlite-distill` owns the shared scope, removal test, output fields, and sufficiency
review for extracting essential knowledge or a minimal working implementation.
It preserves the requested boundary and defining behavior, separates overview
coverage from selective depth, and keeps the main lesson distinct from detailed evidence.
Its entrypoint loads only the relevant knowledge or implementation guide from
`references/`, plus the code-design guide for codebase or architecture explanations.
That guide owns major-area coverage, source responsibility, ownership, interfaces,
collaboration, and lifecycle. The implementation guide owns the reduction map and
requires a complete path through the requested behavior with audience-appropriate
notation. Coverage, fidelity, execution, reader sufficiency, and evidence completeness
have separate outcomes; incomplete required checks prevent a complete verdict.
The evaluation runbook and raw knowledge fixture in `tests/boxlite_distill/` own
test isolation, frozen inputs, comparisons, and caller-specific evidence budgets;
they are not loaded by ordinary skill use. Existing skill discovery exposes the
whole directory; Codex UI metadata uses the same skill name. No runtime or hook is
added. Original source is preserved unless modification was requested.

`boxlite-design-doc` owns research requirements, the design outline, and design review.
For complex sources, its Research section uses `boxlite-distill` in knowledge mode while retaining decision-relevant evidence and the design outline.
Hosts discover it through their skill paths; consumers name the skill without
copying its rules. The full Test section and reproduce-before-fix remain in workflow guidance.

`boxlite-pr-preparation` keeps four steps in one entrypoint: inspect inputs, choose
an illustration, write the description, and verify delivery. Input, illustration,
and description tables support those steps. The short selection table is core
guidance used for every description, so it stays inline. The skill explicitly reads
the shared workflow and repository instructions, then loads contributor procedures
for authorized publication. The [ownership table](CONTRIBUTING.md#instruction-ownership)
identifies policy, outline, checker, and review owners. Skill invocation grants no
publication or approval authority.
