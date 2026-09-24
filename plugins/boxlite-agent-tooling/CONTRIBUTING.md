# Contributing

- Read [ARCHITECTURE.md](ARCHITECTURE.md) first: entry points, invariants, the Stop gate's decision table, and the vocabulary used below.
- Every human-facing output requires `## TL;DR` with one simple sentence, as short as possible, including replies, progress updates, design docs, PR descriptions, and GitHub comments.
- Replies must begin with TL;DR; keep the entire section under 40 words.
- Beyond TL;DR, choose the clearest form: a diagram, real example, bullets, table, or short prose; walls of text are forbidden.

## Commit & PR messages

The preflight hook's denials point here as `CONTRIBUTING.md #commit--pr-messages`; keep this heading so that anchor resolves.

### Commit messages

- Subject: Conventional Commit, no longer than 72 characters.
- Body: the why. The problem, why this change solves it, the alternatives rejected.
- Squash merges keep commit messages and drop the PR body, so a why that lives only in the PR never reaches `git log` or `git blame`.

### Pull request size

Follow the hard PR-size and decomposition requirements in
[the shared workflow](guidance/workflow.md#workflow): target 100–200 changed lines,
maximum 400, with a three-minute human exception window followed by automatic
splitting if no valid reply arrives. The size exception is separate from `reviewed:`; both use the same timed-request library.
The agent opens the question and performs the split. The hook enforces expiry;
it does not open or dismiss a native dialog. For Claude, launch with
`bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh` to load
this plugin and enable native idle dismissal in a local session. The launcher disables
Remote Control only for that session; global settings remain unchanged. Remote Control,
custom `--settings`, print, background, and cloud invocations use non-blocking questions
instead. Setting `CLAUDE_AFK_TIMEOUT_MS` alone does not enable managed native questions.
Activity can keep a native dialog open beyond the fixed deadline, but late replies
remain invalid. See [enforcement scope](ARCHITECTURE.md#entry-points).

Illustrative typed exception:

> pr-size-exception: The dependency update regenerates 612 lockfile lines; splitting the proposed manifest and lockfile changes would leave the dependency graph inconsistent.

The agent must show the actual diff and proposed split first. It must never supply
that example as a pre-filled developer response. Record an accepted reason verbatim
with the repository, base/head, and measured size in the PR and parent issue.

Use native GitHub stacks for dependent slices; follow the
[shared workflow](guidance/workflow.md#workflow) for per-layer checks and publication.

### Pull request descriptions

Before writing any code, create a **1–3 page design doc**. Every PR, including drafts
and small changes, must link it. Prefer **GitHub issue > Notion > Linear issue**.
Cover the problem, approach, alternatives and trade-offs, and validation plan.
Use reply-summary presentation: start with TL;DR under 40 words.
Walls of text are forbidden; use short bullets, tables, or diagrams.
Include a brief real example when helpful;
link supporting detail. Design docs have no fixed total-word limit.
Keep the doc aligned with the final PR scope; summarize the implementation in the PR.

Register the canonical URL before implementation:

```sh
bash <plugin-root>/scripts/design-doc.sh bind <URL>
```

The pre-edit hook verifies the document before native editor, patch, and notebook
operations. Missing, unreadable, oversized, or overly dense documents block edits;
a missing, buried, or oversized TL;DR also blocks them.
GitHub uses `gh` authentication; Notion needs `NOTION_TOKEN`, Linear needs
`LINEAR_API_KEY`. Keep credentials in the environment, never in the repository.
Shell commands are outside this design gate, so investigation and document
registration need no command-specific exemptions. Host permissions and the separate
commit/push and GitHub publication hooks still apply. The requirement to create a
design before writing code includes shell-created code as workflow guidance;
this pre-edit hook does not enforce shell writes or arbitrary MCP writers.
Re-register after changing branches. Design quality still requires review.
Notion designs must keep their text in top-level blocks; unread child blocks are rejected.
Use the full registered URL in the PR body as plain text or a Markdown link.
The hook renders the body through GitHub and checks the resulting link target;
hidden references, comments, and code examples do not count. Rendering failures block publication.
The PR hook rechecks the document and link before consuming any review acknowledgment;
ready and metadata-only operations inspect the current published body.

Every PR description must explain how the change produces its intended result. Use a
call graph, sequence diagram, real example, bullets, table, or short prose—whichever
best explains that PR.
TL;DR is mandatory; diagrams, Before/After layouts, source annotations, and section order are optional.

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
- Link the design doc in every PR. Use `Fixes #<n>` only when the PR closes that
  GitHub issue. Large work also requires the parent and child issues described
  above. No inline bug marker is required.

For issues, comments, reviews, discussions and release notes, use the same
[reply-summary prompt](.agents/prompts/concise-writing.md).
Design documents follow the 1–3-page guidance above.

Public artifacts must not include private chats, memory citations, internal sources,
or local session details, including paraphrases. Use public evidence or explicit
disclosure authorization for the exact content and destination. The publication
hook rejects recognizable privacy indicators in titles and bodies; passing it does
not establish that arbitrary content is public. See the scope in ARCHITECTURE.md.

The preflight hook checks explicit nonempty text, including draft PRs and REST body
fields. It shares reply-summary's word and density checks; see
[ARCHITECTURE.md](ARCHITECTURE.md) for the exact scope. Prepare generated text first,
then pass literal inline text. Files, stdin, editors and GraphQL text mutations cannot
bind the eventual published text at this boundary. Body-preserving operations need
no new text. Browser edits and other clients remain outside the hook.

`.github/PULL_REQUEST_TEMPLATE.md` is a starting point, not a required structure.
Use safe shell quoting for inline bodies: Markdown backticks inside double quotes
can execute as command substitutions.

CI posts an author-review prompt and converts unacknowledged PRs to draft. After
reading the current diff, the PR author posts `/reviewed <full-head-SHA>` as a new,
unedited comment. Once `Author reviewed the PR` passes, the author can click
**Ready for review**. A new push or editing/deleting the only acknowledgment
returns the PR to draft and requires a fresh comment. Forks use the same flow.
The local hook gives each `reviewed:` request three minutes; retries preserve that
deadline. Expiry leaves the PR draft or uncreated. The GitHub comment flow is separate.
Both the local acknowledgment prompt and GitHub comment ask the explanation question.
Acknowledgments bind to the commit SHA, so a description edit alone does not revoke
one. Description quality is a human review criterion. Maintainer approval remains separate.

Illustrative example; the behavior and test results are hypothetical:

````markdown
## TL;DR

Reduce routine SDK CI work while keeping the full compatibility matrix weekly.

Design doc: https://github.com/example/repo/issues/123

- The workflow selects a reduced SDK matrix for PRs and the full matrix for weekly
  and manual runs.
- PR changing both SDKs: 21 jobs → 11.
- Every supported version still runs on Linux x64; macOS/ARM use the latest version.

Verification: `make test:apps:infra` → passed. Hosted CI timing has not been measured.
````
