---
name: boxlite-design-doc
description: Research best practices; write design docs before coding.
---

Apply `boxlite-writing`.

## Research

Finish before implementation (tests/shell included); never backfill.
**What is the best practice for this work, and why?**

- Inspect code/callers/tests → effects/failures/reuse; official guidance/standards/mature implementations.
- For complex source material, use `boxlite-distill` in knowledge mode to clarify mechanisms and prerequisites. Preserve decision-relevant alternatives, counterevidence, constraints, and citations. Keep this skill's design outline.
- Questions → sources → mechanisms/failures → constraint differences → adopt/adapt/reject reasons. Compare alternatives/counterevidence; justify local fit/deviations; never invent consensus.
- Open originals; cite exact sections or `file:line` (prefer commit-pinned). Separate observations/inferences. Snippets/memory/link lists/generic claims insufficient.
- Depth follows impact/uncertainty; no citation quotas. Revalidate reused research against current code/constraints.
- Resolve approach/correctness gaps before binding/coding; remaining unknowns → impact/next check.

Search protocol (every design):

- Name known items first, from outside the searched indexes; the search must find them.
- Search ≥2 paper indexes (Scholar only supplements), ≥2 project engines, the web, dependency specs at the used version, and repo/upstream history, including failed attempts.
- Chase citations both ways; stop when a round or 3 queries add nothing; record why.
- Log per source: tool, date, query count, stop status; exact queries only for kept items and the stop run.
- SOTA: papers ≤24 months old or still leading; projects active within 12 months with ≥2 adoption signals (stars alone are not one); vendor docs prove existence only.
- Adopt, adapt, or reject each relevant SOTA item with a reason; "none found" passes.

## Design

Before coding: 1–3 pages; prefer GitHub issue > Notion > Linear issue; tracking issue may hold design.
Challenge assumptions and each layer's need for knowledge.

Write findings:

- **TL;DR:** problem → outcome.
- **Problem:** current behavior or unmet need, concrete evidence, and impact.
- **Scope:** constraints, non-goals, acceptance.
- **Related work and lessons:** research above; alternatives include reuse/simplify/no change; recommendation.
- **How it works:** approach/mechanism → outcome; trade-offs.
- **Validation:** claim/risk → check → expected result; observed versus planned.

[Bind](../../../CONTRIBUTING.md#pull-request-descriptions), then pass `design-auditor` before the first code edit.
Every PR (drafts included): link design; match final scope.

## Review

Before code, `design-auditor` probes the search and verifies sources, reporting
every gap each round. Critical/high gaps block edits (gap → pass condition); low/nit are
advisories. Later audits check prior findings first. A second FAIL that repeats a finding
or doesn't reduce them, or a third FAIL, stops for the human: Redesign, Reflect again, or
Overrule (never PASS). Later reviews check the diff against the design. Binding ≠ research.
