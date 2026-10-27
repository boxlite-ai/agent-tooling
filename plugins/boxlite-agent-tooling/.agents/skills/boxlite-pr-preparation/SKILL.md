---
name: boxlite-pr-preparation
description: Draft or revise PR descriptions with concrete examples and honest verification.
---

# BoxLite PR Preparation

## Purpose and scope

Help reviewers understand why the change exists, how it works, and what evidence
supports it. Apply `boxlite-writing`. For drafts, ready PRs, and description
revisions, read and apply the [shared workflow](../../../guidance/workflow.md)
and repository instructions before these steps. Keep review-only requests read-only.

## 1. Inspect the inputs

| Input | What to establish |
| --- | --- |
| Intended base and current diff | Exact scope of the change |
| Relevant source and tests | Actual mechanism and resulting behavior |
| Bound design | Intended outcome, constraints, and rationale |
| Updated project documentation | Changed sections and their links |
| Verification evidence | Commands, observed results, and coverage gaps |

## 2. Choose the smallest useful illustration

Show **input or starting state → action → result**. Explain why the result follows;
keep enough context in the description to understand the example.

| PR type | Minimum useful illustration |
| --- | --- |
| Bug fix | Reproducer or focused test showing failure before and success after |
| Feature/API | Small working invocation with expected output |
| Refactor | Same input/output, plus the changed internal path or preserved invariant |
| UI | Before/after screenshots and interaction steps |
| Configuration/CI | Concrete configuration or event → resulting behavior |
| Documentation | Before/after wording or corrected usage |

- Prefer runnable project calls or existing focused tests for behavior changes;
  do not reimplement the change in a separate demo.
- For runnable examples, include prerequisites, the exact invocation, and expected results.
- Label illustrative or unrun examples. Examples explain the change; they do not
  replace verification. No fixed code length or new test is required.

Illustrative documentation case: `recieve` → `receive`, linked to the corrected
section. A runnable sample adds nothing to that spelling correction.

## 3. Write the PR description

Adapt these contents to the repository template:

| Content | Required explanation |
| --- | --- |
| Summary | Problem and resulting behavior, once |
| How it works | Mechanism or rationale with the selected illustration |
| Verification | Decisive command → observed result, including missing coverage |
| Links | Full registered design URL, relevant source/tests, and changed project docs |

For fixes, report the workflow's full-revert failure and restored-fix
result; disclose missing proof. Never present expected output as observed or reuse
stale verification.

Use repository-relative paths or verified repository URLs in the PR body;
keep machine-local evidence in the private handoff. Omit work logs and exhaustive
test counts.

## 4. Verify before delivery

- Recheck explanation, illustration, linked source/tests/docs, and evidence against
  the final diff, including drafts and description edits. Remove placeholders and
  superseded claims.
- Use `Fixes #<n>` only when the PR meets that issue's agreed acceptance criteria.
  Intermediate slices reference the tracking issue without closing it.
- Read and apply the [review question](../../prompts/pr/pr-review-question.md).
  Self-review cannot supply the human's acknowledgment.

## Authority

Preparing a description grants no permission to commit, push, publish, or approve.
For authorized publication, read and apply the [publication and acknowledgment
procedures](../../../CONTRIBUTING.md#pull-request-descriptions).
