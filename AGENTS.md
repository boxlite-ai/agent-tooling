# Agent Tooling

## Navigate

Read [README](README.md), [Contributing](plugins/boxlite-agent-tooling/CONTRIBUTING.md),
[Architecture](plugins/boxlite-agent-tooling/ARCHITECTURE.md).

Plugin code: `plugins/boxlite-agent-tooling/`; consumer bootstraps: `templates/`.
Aliases: `skills` → `.agents/skills`, `agents` → `.claude/agents`; Codex: `.agents/skills`.

## Compatibility

Support Claude Code and Codex on macOS, Linux, and Windows. Test affected pairs; report gaps.

## Tooling choices

- Prefer shared file and shell abilities. Use shell scripts when practical; minimize dependencies.
- Add tools/runtimes only for material safety, portability, or maintainability gains.

## Agent-facing docs

Prompts, skills, and agent-facing docs MUST minimize prose per `boxlite-writing`; preserve behavior and constraints.
New or changed user-facing questions, confirmations, and choices MUST use `user_question`.

## Change safely

- Editing, renaming, moving, or deleting `boxlite-writing` or its files requires a specific user request. Skill use, output revisions, and check fixes grant none.
- Non-trivial Bash: load `boxlite-shell-engineering`; preserve stdin/stdout/stderr/exit behavior.
- Claude Code: plan mode before touching `.githooks/`.
- Consumer manifests: declarative, secret-free; invalid profiles/missing dependencies fail closed with clear stderr.
- Align `ARCHITECTURE.md` with code.

## Validate

From repo root, run focused tests (`make test:plugin TEST_FILTER=<name>`) and:

```sh
make test:writing test:parity test:architecture
```

API: `make test:api-compatibility test:api-lint` (oasdiff 1.33.0 or `OASDIFF_BIN`).

Host parity: after manifest/marketplace/symlink/hook-JSON changes and before release; covers all marketplaces/manifests. Copilot: generic only; installs untested.

## Maintain instructions

Local rules above block; `CLAUDE.md` import-only.
Edit `guidance/workflow.md`. Run `bash scripts/sync-guidance.sh <repo-root>` in plugin.
Run `make test:guidance` from root.

<!-- agent-tooling:guidance:begin rev=1f433e122f5d-dirty sha256=c111ec225cda -->

> Managed by **boxlite-ai/agent-tooling** — do not edit between the markers. Change `plugins/boxlite-agent-tooling/guidance/workflow.md` there, then rerun `./.agent-tooling/install.sh` here.

## Workflow

Every change goes: understand → research → design → implement → test → verify.

Apply the `boxlite-clean-code` skill for design, implementation, refactoring, and maintainability review.

MANDATORY: File all agent-tooling issues from any consumer in [upstream GitHub Issues](https://github.com/boxlite-ai/agent-tooling/issues).

### Understand

- Read this file, the nearest README/CONTRIBUTING, relevant docs, and the actual source before editing.
- Reproduce-before-fix: when fixing a bug, write the failing test first, observe it fail, then fix.
- If docs and code disagree, record the conflict and ask before assuming the architecture.

### Research and design

Apply the `boxlite-design-doc` skill before implementation.

### Documentation (every PR)

- Every PR, including drafts, must add or update meaningful project docs; prefer existing docs.
- Explain changed behavior, usage, contracts, or maintenance, including refactor rationale.
- Link the changed section and check it against the final diff.
- Design links, PR summaries, file lists, formatting, and token edits alone do not count.

### Implement

- Calculate paths from known roots; never assume them.
- Complete setup before irreversible operations.
- Never commit secrets; validate before SQL/shell/URL/path/HTML/prompt construction; avoid shell execution with untrusted input.
- Don't paste long excerpts from books, tickets, or logs into source comments.
- Add dependencies only when they materially reduce risk or complexity.

#### PR size and decomposition

| Case | Rule |
| --- | --- |
| Target | Prefer 100–200 added code lines; 400 is a bypassable guideline, including drafts |
| Measure | Estimate before coding; measure against the intended base before every PR creation/update |
| Count | Source, scripts, configuration, generated code, and unfamiliar files |
| Exclude | `*.spec.ts`, `*_test.go`, `tests` directories, recognized documentation, data/assets, and lockfiles |
| Above 400 | Ask the user to choose **Bypass limit** or **Split PR**; never infer a choice |
| Bypass | Needs no written justification and applies only to the current diff; diff changes require a new decision |
| Split | Tested PRs under one tracking issue, native GitHub stacks for dependencies; follow the installed plugin's `.agents/prompts/pr/split-pr-tracking-issue.md` |
| Choice window | Allow **5 minutes**; silence defaults to splitting; follow the installed plugin's `.agents/prompts/pr/pr-size-exception.md` and `.agents/prompts/pr/pr-size-expired.md` |
| Reconsider | A split choice or expired request, only after explicit human instruction |

### Test

Classify each behavioral claim against its base contract:

| Claim | Proof |
| --- | --- |
| Fixes to existing behavior, including through new APIs/wrappers | Keep defect proof, below |
| New entry points over unchanged, correct dependencies | New-contract proof; dependency reuse alone is not a fix |
| Wholly new contracts | Verify base/source evidence of no equivalent prior contract; run positive, negative, and boundary tests against the implementation; mark full-revert defect proof not applicable with a reason; new security APIs also need allowed/denied checks at real security boundaries |
| Mixed changes | Apply both standards, defect proof and new-contract proof, per claim |

#### Defect proof

For each test added with a fix, run these steps manually, in order:

1. Revert **every** production change: restore every non-test file to its pre-fix state; only the test remains.
2. If API, signature, or schema changes prevent compilation or reaching the defect check, keep production reverted.
3. In that case only, add the smallest temporary test-only compatibility adapter for the old contract.
4. The test-only compatibility adapter may adjust setup or invocation only; it must not implement the fix, alter the defect check, or become the failure signal.
5. Run the test: it must reach the defect check and fail for the original bug; log the failure signal (assertion, hang, panic).
6. If no adapter preserves the signal, stop and report the blocker.
7. Remove the adapter, restore all production changes, and rerun: the test must pass.

- **Partial reverts, mental simulation, and assumed failure are cheating.**
- Without the failing run, a pass cannot prove the test catches the bug or the fix is necessary.

#### API contracts

- OpenAPI files matching `*openapi*.yaml` require the installed plugin's `guidance/api-compatibility.md`; new optional SDK parameters need local before/after request tests.
- For those files, explain breaking/default changes, recommend GitHub issue discussion, and require explicit user confirmation to skip the gate.

#### Test rules

- Missing APIs, compilation errors, and setup errors never reproduce a defect.
- Test data must come from production code under test, across a boundary where behavior can fail.
- Asserting on a value built entirely by the test proves nothing, for example a substring the test itself inserted.
- Add or update tests when behavior changes around branching, parsing, retries, security checks, or boundaries.
- Focus tests on the reason for the change, and test project code, not just stdlib or frameworks.
- Put temporary tests without project-symbol references in a temporary directory, outside production tests.
- Fix the code; never weaken a test to force a pass.

### Cross-cutting (apply at every phase)

- Verify external findings against the working tree with `git grep` and `git diff` before acting; reviews, lint, and PR comments may reference stale code.
- Stay inside the ask: do and discuss only what the request needs; "drop X" means drop X.
- File adjacent bugs, cleanup, or topics in a GitHub/Linear issue or docs note; mention them in one closing line, never a change or section.
- If SessionStart supplies a follow-up queue, record verified unresolved findings there. Acknowledge the exact pending revisions before Stop, including an empty list.
- Fix every evidenced site of the same defect in one pass; do not speculate.
- Different nearby defects are adjacent work; one site does not resolve a systemic bug.
- When behavior changes, remove superseded code, comments, prose, old-contract tests, and broken references in the same change.
- Search all replaced terms, not just edited files; contradictory prose misleads readers.

### Disclosure

- Public artifacts and delegates need public evidence or disclosure approval for the exact content and destination.
- This covers private messages, memory citations, local paths, internal context, and paraphrases.
- Omit uncertain material.
- Edits invalidate approval; task authorization and hook passes grant none.

### Communication

- Apply the `boxlite-writing` skill.
- Apply `boxlite-pr-preparation` for every PR, including drafts and description edits.

<!-- agent-tooling:guidance:end -->
