> Managed by **boxlite-ai/agent-tooling** — do not edit between the markers. Change `plugins/boxlite-agent-tooling/guidance/workflow.md` there, then rerun `./.agent-tooling/install.sh` here.

## Workflow

Every change goes: understand → research → design → implement → test → verify.
Apply the `boxlite-clean-code` skill for design, implementation, refactoring, and maintainability review.

**Understand**

- Read this file, the nearest README/CONTRIBUTING, relevant docs, and the actual source before editing.
- Reproduce-before-fix: when fixing a bug, write the failing test first, observe it fail, then fix.
- If docs and code disagree, record the conflict and ask before assuming the architecture.

**Research**

- Before choosing an approach, examine relevant code and comparable projects. Cite `file:line` (prefer commit-pinned links) or exact documentation sections.
- Every design must include **Related work and lessons**: sources, approaches, differing constraints, and what it adopts, adapts, or rejects—and why. Check that evidence supports the decisions.
- Scale research to uncertainty and impact, without citation quotas. If no comparison is useful, record the search and reasons. Link reused research and explain its applicability.

**Design**

- Before coding, create a 1–3 page design: problem, related work and lessons, approach, alternatives, trade-offs, and validation. Prefer GitHub issue > Notion > Linear issue. Every PR, including drafts, must link it and keep it aligned with final scope.
- Apply Communication rules to designs.
- Don't be yes-man — challenge assumptions (yours too); ask whether a layer needs to know what you're about to teach it.

**Documentation (every PR)**

- Every PR, including drafts, must add or update meaningful project docs. Prefer existing docs; explain changed behavior, usage, contracts, or maintenance (including refactor rationale).
- Link the changed section and check it against the final diff. Design links, PR summaries, file lists, formatting, and token edits alone do not count.

**PR size and decomposition (hard requirement)**

- Target 100–200 lines; cap each PR at 400 additions + deletions against its intended base (the preceding branch in a stack). Count tests, docs, and generated text, including drafts. Splitting commits does not reduce size.
- Estimate before implementation; measure before PR creation and every update. Resolve unknown base or size before publishing. Never omit tests, compress code, or hide changes to fit.
- Over the limit: reuse one tracking issue, or create one if absent. Checklist each slice's scope, dependencies, acceptance criteria, estimated size, and eventual PR link.
- Use the installed plugin's `.agents/prompts/split-pr-tracking-issue.md` body; remove metadata and replace instructions with the plan. Keep design, steps, questions, and implementation history together.
- Separate issues only for independently tracked work: owners, priorities, releases, or deferred outcomes. Splitting alone needs no child issues, milestone, or Project.
- Implement and validate one coherent, working slice at a time, with relevant tests and within the limit; re-plan oversized slices. Link the tracking issue, update todos as slices land, and close only when agreed acceptance criteria are met.
- Dependent slices **must** use native [GitHub PR stacks](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-stacked-pull-requests) (`trunk ← PR1 ← PR2`). Preserve per-PR gates. Use `gh stack link` with verified existing PR URLs; confirm membership. Rebase and revalidate affected layers after changes.
- For a size exception, show the human developer the measured size, exact base/head, and proposed split. Ask once per attempt, without preselected approval, for: `pr-size-exception: <specific reason this change must remain one PR>`.
- The typed reason must identify the change, concrete constraint, and why splitting is unsafe or impractical. Bare approval, urgency, effort, or convenience does not qualify. Never invent, paraphrase, or pre-fill it.
- Use a non-blocking prompt with a **3-minute** deadline from the question. Continue reversible split preparation. Invalid replies do not reset the timer; explicit cancellation or revised instructions take precedence.
- Without a valid exception by the deadline, continue the split plan; do not end the task awaiting permission or treat silence as approval. If timed prompting is unavailable, keep the limit and split.
- Bind exceptions to the shown repository, base/head, and diff; any diff change invalidates them. Record the exact reason and context in the PR and tracking issue. Only size is waived, never tests, review, or `reviewed:` acknowledgment.
- Late replies cannot authorize expired requests. Renew only on a new explicit human request to ask again. First remeasure through the guarded PR operation and show the current diff and split.
- Renew using `scripts/timed-user-prompt.sh renew STATE REQUEST_ID USER_REQUEST` with the human request verbatim. Renewal archives the attempt and creates a new ID and deadline; it grants no approval.

**Implement**

- Calculate paths from known roots; never assume them.
- Complete setup before irreversible operations.
- Never commit secrets. Validate before SQL/shell/URL/path/HTML/prompt construction; avoid shell execution with untrusted input.
- Don't paste long excerpts from books, tickets, or logs into source comments.
- Add dependencies only when they materially reduce risk or complexity.

**Test**

- For each test added with a fix, manually run both steps in order:
  1. Revert **every** production change: restore every non-test file to its pre-fix state; only the test remains. If API, signature, or schema changes prevent compilation or reaching the defect check, keep production reverted and add the smallest temporary test-only compatibility adapter for the old contract. The test-only compatibility adapter may adjust setup or invocation only; it must not implement the fix, alter the defect check, or become the failure signal. Run the test: it must reach the defect check and fail for the original bug. Log the failure signal (assertion, hang, panic). **Partial reverts, mental simulation, and assumed failure are cheating.** If no adapter preserves the signal, stop and report the blocker.
  2. Remove the adapter, restore all production changes, and rerun: the test must pass. Without step 1, a pass cannot prove the test catches the bug or the fix is necessary.
- Test data must come from production code under test, across a boundary where behavior can fail. Asserting on a value built entirely by the test proves nothing—for example, checking a substring the test itself inserted.
- Add or update tests when behavior changes around branching, parsing, retries, security checks, or boundaries.
- Focus tests on the reason for the change.
- Test project code, not just stdlib or frameworks.
- Put temporary tests without project-symbol references in a temporary directory, outside production tests.
- Fix the code; never weaken a test to force a pass.

**Cross-cutting** (apply at every phase)

- Verify external findings against the working tree with `git grep` and `git diff` before acting; reviews, lint, and PR comments may reference stale code.
- Stay inside the ask: do and discuss only what the request needs. File adjacent bugs, cleanup, or topics in a GitHub/Linear issue or docs note; mention them in one closing line, never a change or section. "drop X" means drop X.
- Fix every evidenced site of the same defect in one pass; do not speculate. Different nearby defects are adjacent work; one site does not resolve a systemic bug.
- When behavior changes, remove superseded code, comments, prose, old-contract tests, and broken references in the same change. Search all replaced terms, not just edited files; contradictory prose misleads readers.

**Disclosure**

Public artifacts/delegates: public evidence or disclosure approval for exact content/destination, including private messages, memory citations, local paths, internal context, paraphrases. Omit uncertain material. Edits invalidate approval; task authorization and hook passes grant none.

**Communication**

Apply the `boxlite-writing` skill.

- Check PR explanations against the diff, including drafts and description edits. State the problem, resulting behavior, and decisive verification once; file lists alone do not explain a change. Omit work logs and exhaustive test counts. Adapt repository templates.
