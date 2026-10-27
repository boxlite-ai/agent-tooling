---
name: boxlite-pr-preparation
description: Draft or revise PR descriptions with concrete examples and honest verification.
---

# BoxLite PR Preparation

Apply `boxlite-writing`. Prepare descriptions for drafts, ready PRs, and revisions.
Keep review-only requests read-only; this workflow does not authorize publication.

## Inspect

- Establish the intended base; read the current diff and relevant source/tests.
  Identify the problem, resulting behavior, and mechanism or rationale.
- Measure the diff under the repository's PR-size policy before creation or update;
  resolve any required size choice. Early estimation remains part of implementation.
- Find the bound design and meaningful project documentation changed by this PR.
  Check the linked sections against the final diff.

## Draft

- State the problem and resulting behavior once; a file list does not explain a change.
- Populate **How it works** with a minimal, concrete example explaining the mechanism
  or rationale. Read [example formats](references/examples.md) when drafting this section.
  For runnable examples, include prerequisites and the exact invocation.
- Link relevant source/tests, the full registered design URL, and the changed project
  documentation. Keep enough context in the description to understand the example.
  Use repository-relative paths or verified repository URLs in the PR body;
  keep machine-local evidence paths in the private handoff.
- Report decisive verification as command → observed result. Label unrun examples
  and expected output; never turn them into execution claims or reuse stale results.
  For fixes, include the required full-revert failure and restored-fix result;
  disclose missing proof.
- Adapt the repository template. Omit work logs and exhaustive test counts.
  Use `Fixes #<n>` only when this PR closes that issue; intermediate slices reference
  the tracking issue without closing it. Close tracking issues only after their
  agreed acceptance criteria are met.

## Before delivery

- Recheck explanation, example, links, and verification against the final diff,
  including drafts and description edits. Remove placeholders and superseded claims.
- Apply the [review question](../../prompts/pr/pr-review-question.md).
  Self-review cannot supply the human's acknowledgment.
- For authorized publication, follow the existing [publication and acknowledgment
  procedures](../../../CONTRIBUTING.md#pull-request-descriptions) and disclosure rules.
  Preparing a description grants no permission to commit, push, publish, or approve.
