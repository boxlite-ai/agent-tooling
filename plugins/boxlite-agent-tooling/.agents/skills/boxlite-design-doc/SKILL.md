---
name: boxlite-design-doc
description: Research best practices; write design docs before coding.
---

Apply `boxlite-writing`.

## Research

Finish before implementation (tests/shell included); never backfill.
**What is the best practice for this work, and why?**

- Inspect code/callers/tests → effects/failures/reuse; official guidance/standards/mature implementations.
- Questions → sources → mechanisms/failures → constraint differences → adopt/adapt/reject reasons. Compare alternatives/counterevidence; justify local fit/deviations; never invent consensus.
- Open originals; cite exact sections or `file:line` (prefer commit-pinned). Separate observations/inferences. Snippets/memory/link lists/generic claims insufficient.
- Depth follows impact/uncertainty; no citation quotas. Revalidate reused research against current code/constraints; log unsuitable searches/reasons.
- Resolve approach/correctness gaps before binding/coding; remaining unknowns → impact/next check.

## Design

Before coding: 1–3 pages; prefer GitHub issue > Notion > Linear issue; tracking issue may hold design.
Challenge assumptions and each layer's need for knowledge.

Write findings:

- **TL;DR:** problem → outcome.
- **Scope:** constraints, non-goals, acceptance.
- **Related work and lessons:** research above; alternatives include reuse/simplify/no change; recommendation.
- **How it works:** approach/mechanism → outcome; trade-offs.
- **Validation:** claim/risk → check → expected result; observed versus planned.

[Bind](../../../CONTRIBUTING.md#pull-request-descriptions). Every PR (drafts included): link design; match final scope.

## Review

Verify sources against diff. Missing/unreadable/unsupported evidence blocks approval:
gap → corrective check. Binding ≠ research.
