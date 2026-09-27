---
name: boxlite-design-doc
description: Research best practices and write evidence-backed design docs before implementation.
---

# BoxLite Design Doc

Apply `boxlite-writing`.

## Research before coding

- Finish research before implementation (tests/shell included); never backfill. Inspect code/callers/tests, official guidance, standards, and mature implementations.
- Answer **What is the best practice for this work, and why?** Compare alternatives/counterevidence; explain local fit/deviations; never invent consensus.
- Connect questions → sources → mechanisms/failures → constraint differences → adopt/adapt/reject reasons. Cite opened originals by exact section or `file:line`, preferably commit-pinned; distinguish observations/inferences. Snippets, memory, link lists, and generic claims are insufficient.
- Scale to impact/uncertainty; no citation quotas. Revalidate reused research against current code/constraints; record unsuitable searches/reasons.
- Before binding/coding, resolve approach/correctness gaps; record remaining unknowns/impact/next checks.

## Write the design

Create a 1–3 page design before coding. Prefer GitHub issue > Notion > Linear issue.
Tracking issues may contain the design; no separate document is needed.
Challenge assumptions; ask whether a layer needs to know what you're teaching it.

Replace the prompts below with findings:

| Section | Required content |
| --- | --- |
| TL;DR | Problem → outcome. |
| Scope | Constraints, non-goals, acceptance. |
| Related work and lessons | Questions; callers → implementation → effects; tests, failures, reuse; best-practice evidence; alternatives (including reuse/simplify/no change); recommendation and unknowns. |
| How it works | Approach; mechanism → outcome; trade-offs. |
| Validation | Claim/risk → check → expected result. Observed versus planned. |

Bind using the [registration workflow](../../../CONTRIBUTING.md#pull-request-descriptions).
Every PR, including drafts, must link the design and keep it aligned with final scope.

## Review

Verify sources against the diff. Missing/unreadable/unsupported evidence blocks approval;
name gaps and corrective checks. Binding alone proves no research.
