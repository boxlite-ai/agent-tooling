# Agent Tooling

## Navigate

Read [README](README.md), [Contributing](plugins/boxlite-agent-tooling/CONTRIBUTING.md),
[Architecture](plugins/boxlite-agent-tooling/ARCHITECTURE.md).

Plugin/reusable code: `plugins/boxlite-agent-tooling/`; consumer bootstraps: `templates/`.
Manifests use symlinks: `skills` → `.agents/skills`, `agents` → `.claude/agents`.

## Compatibility

Support Claude Code and Codex on macOS, Linux, and Windows. Test affected combinations; report unverified ones.

## Tooling choices

- **Capabilities:** Prefer shared agent abilities: read/search/edit files and run commands.
- **Shell:** Prefer shell scripts when practical; minimize dependencies.
- **Exceptions:** Add tools/runtimes only for material safety, portability, or maintainability gains.

## Agent-facing docs

Prompts, skills, and all agent-facing docs MUST use minimum prose per `boxlite-writing`; preserve behavior and constraints.

## Change safely

- Edits, renames, moves, or deletions of `boxlite-writing` or supporting files require a specific, explicit user request. Skill use, output revisions, or check fixes grant none.
- Non-trivial Bash: load `shell-engineering`; preserve stdin/stdout/stderr/exit behavior.
- Claude Code: plan mode before touching `.githooks/`.
- Consumer manifests: declarative, secret-free; invalid profiles/missing dependencies fail closed with clear stderr.
- Align `ARCHITECTURE.md` with code.

## Validate

Run from repo root, plus focused tests:

```sh
bash plugins/boxlite-agent-tooling/scripts/check-writing-ownership.sh .
bash plugins/boxlite-agent-tooling/host-parity.test.sh
bash plugins/boxlite-agent-tooling/architecture.test.sh
```

Host parity: after manifest/marketplace/symlink/hook-JSON changes and before release; covers all marketplaces/manifests. Copilot: generic only; installs untested.

## Maintain instructions

Local rules above block; `CLAUDE.md` import-only.
In plugin, edit `guidance/workflow.md`; run
`bash scripts/sync-guidance.sh <repo-root>` and `bash scripts/sync-guidance.test.sh`.

<!-- agent-tooling:guidance:begin rev=7bf5c511ca7f-dirty sha256=5685ef8134ea -->

> Managed by **boxlite-ai/agent-tooling** — do not edit between the markers. Change `plugins/boxlite-agent-tooling/guidance/workflow.md` there, then rerun `./.agent-tooling/install.sh` here.

## Workflow

Every change goes: understand → research → design → implement → test → verify.
Apply the `boxlite-clean-code` skill for design, implementation, refactoring, and maintainability review.

### Understand

- Read this file, the nearest README/CONTRIBUTING, relevant docs, and the actual source before editing.
- Reproduce-before-fix: when fixing a bug, write the failing test first, observe it fail, then fix.
- If docs and code disagree, record the conflict and ask before assuming the architecture.

### Research and design

Apply the `boxlite-design-doc` skill before implementation.

### Documentation (every PR)

- Every PR, including drafts, must add or update meaningful project docs. Prefer existing docs; explain changed behavior, usage, contracts, or maintenance (including refactor rationale).
- Link the changed section and check it against the final diff. Design links, PR summaries, file lists, formatting, and token edits alone do not count.

### Implement

- Calculate paths from known roots; never assume them.
- Complete setup before irreversible operations.
- Never commit secrets. Validate before SQL/shell/URL/path/HTML/prompt construction; avoid shell execution with untrusted input.
- Don't paste long excerpts from books, tickets, or logs into source comments.
- Add dependencies only when they materially reduce risk or complexity.

#### PR size and decomposition

- Target 100–200 lines; cap 400 additions + deletions, everything included. Estimate before coding; measure against the intended base before every PR creation/update.
- Split into tested PRs under one tracking issue; use native GitHub stacks for dependencies. Follow the installed plugin's `.agents/prompts/split-pr-tracking-issue.md`.
- Exceptions: human justification within **5 minutes**, otherwise split. Diff changes invalidate approval. Follow the installed plugin's `.agents/prompts/pr-size-exception.md` and `.agents/prompts/pr-size-expired.md`.

### Test

- For each test added with a fix, manually run both steps in order:
  1. Revert **every** production change: restore every non-test file to its pre-fix state; only the test remains. If API, signature, or schema changes prevent compilation or reaching the defect check, keep production reverted and add the smallest temporary test-only compatibility adapter for the old contract. The test-only compatibility adapter may adjust setup or invocation only; it must not implement the fix, alter the defect check, or become the failure signal. Run the test: it must reach the defect check and fail for the original bug. Log the failure signal (assertion, hang, panic). **Partial reverts, mental simulation, and assumed failure are cheating.** If no adapter preserves the signal, stop and report the blocker.
  2. Remove the adapter, restore all production changes, and rerun: the test must pass. Without step 1, a pass cannot prove the test catches the bug or the fix is necessary.
- Test data must come from production code under test, across a boundary where behavior can fail. Asserting on a value built entirely by the test proves nothing—for example, checking a substring the test itself inserted.
- Add or update tests when behavior changes around branching, parsing, retries, security checks, or boundaries.
- Focus tests on the reason for the change.
- Test project code, not just stdlib or frameworks.
- Put temporary tests without project-symbol references in a temporary directory, outside production tests.
- Fix the code; never weaken a test to force a pass.

### Cross-cutting (apply at every phase)

- Verify external findings against the working tree with `git grep` and `git diff` before acting; reviews, lint, and PR comments may reference stale code.
- Stay inside the ask: do and discuss only what the request needs. File adjacent bugs, cleanup, or topics in a GitHub/Linear issue or docs note; mention them in one closing line, never a change or section. "drop X" means drop X.
- Fix every evidenced site of the same defect in one pass; do not speculate. Different nearby defects are adjacent work; one site does not resolve a systemic bug.
- When behavior changes, remove superseded code, comments, prose, old-contract tests, and broken references in the same change. Search all replaced terms, not just edited files; contradictory prose misleads readers.

### Disclosure

Public artifacts/delegates: public evidence or disclosure approval for exact content/destination, including private messages, memory citations, local paths, internal context, paraphrases. Omit uncertain material. Edits invalidate approval; task authorization and hook passes grant none.

### Communication

Apply the `boxlite-writing` skill.

- Check PR explanations against the diff, including drafts and description edits. State the problem, resulting behavior, and decisive verification once; file lists alone do not explain a change. Omit work logs and exhaustive test counts. Adapt repository templates.
<!-- agent-tooling:guidance:end -->
