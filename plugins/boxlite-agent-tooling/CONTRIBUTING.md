# Contributing

- Read [ARCHITECTURE.md](ARCHITECTURE.md) first: entry points, invariants, the Stop gate's decision table, and the vocabulary used below.
- Choose the form that makes the point easiest to understand: a diagram, real example, bullets, table, or short prose. No form is mandatory; walls of text are forbidden.

## Commit & PR messages

The preflight hook's denials point here as `CONTRIBUTING.md #commit--pr-messages`; keep this heading so that anchor resolves.

### Commit messages

- Subject: Conventional Commit, no longer than 72 characters.
- Body: the why. The problem, why this change solves it, the alternatives rejected.
- Squash merges keep commit messages and drop the PR body, so a why that lives only in the PR never reaches `git log` or `git blame`.

### Pull request descriptions

Every PR description must explain how the change produces its intended result. Use a
call graph, sequence diagram, real example, bullets, table, or short prose—whichever
best explains that PR.
No diagram, Before/After layout, source annotation, or section order is mandatory.

- Lead with the problem and resulting behavior, then explain the key steps or
  decisions that produce that result. Listing modified files is not an explanation.
  Explain each fact once.
- Before creating a PR (including drafts) and after editing its description, check:
  **Does the description accurately explain the mechanism shown in the diff?**
- Keep the description concise. Walls of text are forbidden; splitting one into many
  bullets or hiding it in a collapsed section does not make it concise.
- Keep material trade-offs, risks, and untested behavior visible. Link detailed
  evidence instead of pasting logs, file inventories, or exhaustive test counts.
- Include decisive verification as `command → observed result`. For a fix, briefly
  report the failure with all production changes reverted and the pass with the
  complete fix restored. Do not present old results as newly verified.
- Link the relevant issue when one exists, using `Fixes #<n>` when the PR closes it.
  No issue or inline bug marker is required just to satisfy a format.

The preflight hook checks explicit nonempty bodies for non-draft creates and
description edits, with its current size checks documented in
[ARCHITECTURE.md](ARCHITECTURE.md). It does not judge the explanatory form.
Draft creates, body-preserving operations, web/API edits, and later bot additions
are outside this content check; the writing rules still apply.

`.github/PULL_REQUEST_TEMPLATE.md` is a starting point, not a required structure.
Use safe shell quoting for inline bodies: Markdown backticks inside double quotes
can execute as command substitutions.

CI posts an author-review prompt and converts unacknowledged PRs to draft. After
reading the current diff, the PR author posts `/reviewed <full-head-SHA>` as a new,
unedited comment. Once `Author reviewed the PR` passes, the author can click
**Ready for review**. A new push or editing/deleting the only acknowledgment
returns the PR to draft and requires a fresh comment. Forks use the same flow.
Both the local acknowledgment prompt and GitHub comment ask the explanation question.
Acknowledgments bind to the commit SHA, so a description edit alone does not revoke
one. Description quality is a human review criterion. Maintainer approval remains separate.

Illustrative example; the behavior and test results are hypothetical:

````markdown
Reduce routine SDK CI work while keeping the full compatibility matrix weekly.

- The workflow selects a reduced SDK matrix for PRs and the full matrix for weekly
  and manual runs.
- PR changing both SDKs: 21 jobs → 11.
- Every supported version still runs on Linux x64; macOS/ARM use the latest version.

Verification: `make test:apps:infra` → passed. Hosted CI timing has not been measured.
````
