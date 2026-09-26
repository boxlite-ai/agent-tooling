# Contributing

Read [ARCHITECTURE.md](ARCHITECTURE.md) for entry points, invariants, and vocabulary.
Follow these shared sources; this guide adds contributor commands and examples:

| Required guidance | Canonical source |
| --- | --- |
| Research, design docs, PR size, splitting, stacks, disclosure, and verification | [Shared workflow](guidance/workflow.md#workflow) |
| Human-facing writing rules | [Writing prompt](.agents/prompts/concise-writing.md), embedded in workflow and PR guidance |
| PR explanations | [Description guidance](.agents/prompts/pr-description-guidance.md) |

Edit shared writing rules only in the writing prompt above; other documents must
reference or compose it. Keep task-specific requirements with their tasks, and
regenerate consumer instructions instead of editing their generated copies.
Run `bash plugins/boxlite-agent-tooling/scripts/check-writing-ownership.sh .` before
submitting Markdown changes; the Writing ownership workflow runs the same gate.

## Commit & PR messages

The preflight hook's denials point here as `CONTRIBUTING.md #commit--pr-messages`; keep this heading so that anchor resolves.

### Commit messages

- Subject: Conventional Commit, no longer than 72 characters.
- Body: the why. The problem, why this change solves it, the alternatives rejected.
- Squash merges keep commit messages and drop the PR body, so a why that lives only in the PR never reaches `git log` or `git blame`.

### Pull request size

Apply the workflow's **PR size and decomposition** requirements, including exception
expiry and renewal. Use the [tracking-issue template](.agents/prompts/split-pr-tracking-issue.md)
when splitting; see [size enforcement](ARCHITECTURE.md#pr-size-and-stacks) for hook coverage.

For managed native questions in local Claude sessions, launch with:

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

This disables Remote Control for that session. Read [timed confirmations](ARCHITECTURE.md#timed-confirmations)
for supported modes, fallback questions, deadlines, and renewal behavior.

Illustrative typed exception:

> pr-size-exception: The dependency update regenerates 612 lockfile lines; splitting the proposed manifest and lockfile changes would leave the dependency graph inconsistent.

Do not pre-fill this example as a developer response.

### Pull request descriptions

Apply the workflow's **Documentation (every PR)** requirement.
Create the design required by the workflow's **Research** and **Design** rules, then
register its canonical URL before implementation:

```sh
bash <plugin-root>/scripts/design-doc.sh bind <URL>
```

GitHub uses `gh` authentication; Notion needs `NOTION_TOKEN`, Linear needs
`LINEAR_API_KEY`. Keep credentials in the environment, never in the repository.
Re-register after changing branches.
Notion designs must keep their text in top-level blocks; unread child blocks are rejected.
Use the full registered URL in the PR body as plain text or a Markdown link.
See [design-document enforcement](ARCHITECTURE.md#design-documents) for validation and tool boundaries.

- Apply the shared description guidance and [review question](.agents/prompts/pr-review-question.md)
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
