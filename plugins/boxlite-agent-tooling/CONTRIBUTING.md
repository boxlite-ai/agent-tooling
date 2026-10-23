# Contributing

Read [ARCHITECTURE.md](ARCHITECTURE.md) for entry points, invariants, and vocabulary.
Follow these shared sources; this guide adds contributor commands and examples:

| Required guidance | Canonical source |
| --- | --- |
| Research and design docs | [boxlite-design-doc](.agents/skills/boxlite-design-doc/SKILL.md) |
| PR size, splitting, stacks, disclosure, and verification | [Shared workflow](guidance/workflow.md#workflow) |
| General coding decisions and test quality | [boxlite-clean-code](.agents/skills/boxlite-clean-code/SKILL.md) |
| Human-facing writing rules | [boxlite-writing](.agents/skills/boxlite-writing/SKILL.md), referenced by name in workflow and PR guidance |
| PR explanations | [Description guidance](.agents/prompts/pr/pr-description-guidance.md) |

Reference skills by name; do not copy their rules into other
documents or hook messages. Keep task-specific requirements with their tasks, and regenerate
consumer instructions instead of editing their generated copies.

Refer to skills by name in prose and prompts, with the name as link text when useful.
Keep file paths in link targets, tests, and diagnostics that locate a problem.
Run `bash plugins/boxlite-agent-tooling/scripts/check-writing-ownership.sh .` before
submitting Markdown changes; the Writing ownership workflow runs the same gate.

## Auditor test isolation

The verdict runner suite builds a utility-only PATH and uses an explicit default
auditor stub. Claude/Codex integration cases supply their own fake executables;
no-runner cases omit them. An unavailable `CODEX_BIN` disables desktop discovery
outside PATH, and sentinel commands fail the suite on unintended model calls.
Add required utilities to the fixture list instead of restoring the host PATH.

## Release maintenance

Bump the generic, Claude, and Codex plugin manifests together with both version
fields in the Claude and Copilot marketplaces. The Codex marketplace follows
`main` without a version field. Run `host-parity.test.sh` to verify agreement.

Bump the version with any change to an auditor's task or dossier format. The
commit/push gate detects a stale session plugin only by version; an unchanged
version lets a loaded auditor reject the newer gate's tasks instead of asking
for `/reload-plugins`.

After the release merges, run each consumer's `.agent-tooling/install.sh`, then
refresh its host plugin. Verify the recorded revision, worktree hook path, managed
guidance, and installed plugin version separately. Preserve explicit holds and
unrelated worktree changes. Existing sessions need a plugin reload or a new task
to load the updated resources.

Consumer bootstrap scripts are committed snapshots; installation does not rewrite
them. Compare `.agent-tooling/install.sh`, `claude-plugin-bootstrap.sh`, and
`codex-plugin-bootstrap.sh` with the released templates. Propagate applicable
changes while preserving consumer customizations. Verify Claude records by exact
`projectPath`: a successful update in one linked worktree can leave another stale.

### PR-size choice rollout

Version 0.1.29 packages the **Bypass limit** / **Split PR** flow. Verify both adopted
tooling and the installed host plugin report 0.1.29 or newer; reload or start a new
session to replace already-loaded prompts.

### API compatibility rollout

Version 0.1.30 adds the API compatibility gate and changes the commit/push audit
criteria for all `*openapi*.yaml` contracts. Explain breaking/default changes and
recommend GitHub issue discussion; only the user's `api compatibility: skip`
confirmation bypasses that gate. No Notion link is required;
reload or start a new session to replace already-loaded prompts.

### Research gate and TL;DR rollout

Version 0.1.31 moves the research check before code:

- The first code edit on each in-progress branch needs a `design-research-auditor`
  PASS for the bound design.
- Code written or committed under any 0.1.30 build may lack a research check: before
  the next commit or push on such a branch, attempt one editor edit so that review
  runs. Merged work stays an accepted risk.
- A TL;DR summary must open with a paragraph: a list, break, definition, setext
  heading or table under `## TL;DR` is denied, while inline code may open it.
- Reload or start a new session to replace already-loaded prompts.

### Verification boundaries

In lifecycle tests, wait for the observed phase before injecting a signal. A
watcher must publish `watch_start` before TERM; bounded startup failure is a
fixture failure. For FIFO request metadata, retain the two-second replacement
bound and allow the following audit its own completion deadline. Assert its
published finding, so an auditor launch failure cannot substitute for completion.

Prompt budgets cover complete documents, including metadata. Render composed
messages too: a review recovery notice and its timer can each fit separately yet
exceed the host's 1200-byte limit together. Preserve the required actions while
shortening shared prose; run both `subagent.test.sh` and `claude-timed-prompts.test.sh`.

## Commit & PR messages

The preflight hook's denials point here as `CONTRIBUTING.md #commit--pr-messages`; keep this heading so that anchor resolves.

### Commit messages

- Subject: Conventional Commit, no longer than 72 characters.
- Body: the why. The problem, why this change solves it, the alternatives rejected.
- Squash merges keep commit messages and drop the PR body, so a why that lives only in the PR never reaches `git log` or `git blame`.

### Pull request size

Above 400 added code lines, ask the user to choose **Bypass limit** or **Split PR**.
Bypass requires no written justification and permits the current diff through the
size check. Design, writing, and human-review checks still apply. Use the
[tracking-issue template](.agents/prompts/pr/split-pr-tracking-issue.md)
when splitting; see [size enforcement](ARCHITECTURE.md#pr-size-and-stacks) for hook coverage.

The 400-line guideline counts added code, including scripts, configuration, and generated
source. Deletions, `*.spec.ts`, `*_test.go`, files under `tests` directories,
recognized documentation, assets/data, and lockfiles are excluded; unfamiliar
files count. A PR with 400 added code lines and 2,000 Markdown lines fits;
401 added code lines trigger the choice. No response within five minutes defaults
to splitting. A split choice persists without repeated questions; only an explicit
human request permits reconsideration. Changes to the diff require a fresh choice.

For managed native questions in local Claude sessions, launch with:

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

This disables Remote Control for that session. Read [timed confirmations](ARCHITECTURE.md#timed-confirmations)
for supported modes, fallback questions, deadlines, and renewal behavior.

Example: a 612-line PR presents **Bypass limit** and **Split PR**. Selecting bypass
records that choice for its exact diff; no explanation is required.

Never pre-fill or invent the user's selection.

### Pull request descriptions

Apply `boxlite-design-doc`, then bind before coding:

```sh
bash <plugin-root>/scripts/design-doc.sh bind <URL>
```

The first code edit then needs a research PASS for the design's exact content. The
pre-edit gate names the `design-research-auditor` route; the auditor records its
verdict with `design-doc.sh research`. Editing the design needs a new review.

GitHub uses `gh` authentication; Notion needs `NOTION_TOKEN`, Linear needs
`LINEAR_API_KEY`. Keep credentials in the environment, never in the repository.
Re-register after changing branches.
Notion designs must keep their text in top-level blocks; unread child blocks are rejected.
Use the full registered URL in the PR body as plain text or a Markdown link.
See [design-document enforcement](ARCHITECTURE.md#design-documents) for validation and tool boundaries.

- Apply the shared description guidance and [review question](.agents/prompts/pr/pr-review-question.md)
  before publishing, including drafts and description edits.
- The local PR gate requires a level-two **How it works** heading with content.
  Explain the causal path or rationale beneath it; a short sentence is sufficient
  for a simple change. Hidden comments, quoted examples, empty sections, and
  placeholder-only text such as `TBD` are rejected, including repeated or mixed
  placeholders. If headings repeat, at least one section must qualify on its own.
  Reviewers check accuracy.
- Include decisive verification as `command → observed result`. For a fix, briefly
  report the failure with all production changes reverted and the pass with the
  complete fix restored. Do not present old results as newly verified.
- Link the design doc in every PR. Use `Fixes #<n>` only when the PR closes that
  GitHub issue. Intermediate slices reference the tracking issue without closing it;
  close it only when its agreed acceptance criteria are met. No inline bug marker is required.

Start from the [PR template](../../.github/PULL_REQUEST_TEMPLATE.md) when useful.
Prepare generated text first, then pass literal inline text using safe shell quoting:
Markdown backticks inside double quotes can execute as command substitutions.
See [GitHub writing enforcement](ARCHITECTURE.md#github-writing) for accepted inputs and limits.

### Author review acknowledgment

CI posts an author-review prompt and converts unacknowledged PRs to draft. After
reading the current diff, the PR author posts `/reviewed <full-head-SHA>` as a new,
unedited comment. Once `Author reviewed the PR` passes, the author can click
**Ready for review**. A new push or editing/deleting the only acknowledgment
returns the PR to draft and requires a fresh comment. Forks use the same flow.
Use the full head SHA from the bot's comment. The local `reviewed:` flow is separate;
follow its [timed-confirmation instructions](ARCHITECTURE.md#timed-confirmations).
Acknowledgments bind to the commit SHA, so a description edit alone does not revoke
one. Description quality is a human review criterion. Maintainer approval remains separate.

### Example PR description

Illustrative example; the behavior and test results are hypothetical:

````markdown
## TL;DR

Reduce routine SDK CI work while keeping the full compatibility matrix weekly.

Design doc: https://github.com/example/repo/issues/123

Documentation: [SDK CI matrix](docs/ci.md#sdk-matrix).

## How it works

- The workflow selects a reduced SDK matrix for PRs and the full matrix for weekly
  and manual runs.
- PR changing both SDKs: 21 jobs → 11.
- Every supported version still runs on Linux x64; macOS/ARM use the latest version.

## Verification

Verification: `make test:apps:infra` → passed. Hosted CI timing has not been measured.
````
