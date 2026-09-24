---
name: split-pr-tracking-issue
used-by: guidance/workflow.md, CONTRIBUTING.md
placeholders:
description: One outcome and a checklist of small PRs, adapted from Rust tracking issues.
---

## TL;DR

Describe the intended outcome in one short sentence.

## Outcome

State the problem, scope, and acceptance criteria for closing this issue.

## Design

Describe the approach, alternatives, trade-offs, and validation plan, or link the
existing design. This issue can also serve as the design doc; do not create a second
issue solely to hold the design.

## Steps

Repeat this todo for each coherent PR within the size limit. Replace the instructions
and placeholders with the actual plan; add PR links when available.

- [ ] Slice title — PR: pending; depends on: none; estimate: additions + deletions.
  - Scope: the behavior this slice changes.
  - Done when: the acceptance criteria and relevant checks pass and the PR lands.

## Open questions

List unresolved decisions, or write "None." Create separate issues only when work
needs independent tracking, and link those issues here.

## Implementation history

- Date — PR link — result or decision.

Update the checklist as each slice lands. Close the issue only when its agreed
acceptance criteria are met.

Structure adapted from Rust's [tracking-issue template](https://github.com/rust-lang/rust/blob/main/.github/ISSUE_TEMPLATE/tracking_issue.md#L25-L65).
