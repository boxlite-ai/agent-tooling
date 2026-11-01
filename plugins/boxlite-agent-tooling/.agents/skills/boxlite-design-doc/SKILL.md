---
name: boxlite-design-doc
description: Research best practices; write design docs before coding.
---

## Research

Answer: what is the best practice for this work, and why?

- Timing: finish before implementation, tests and shell included; never backfill.
- Depth: follows impact and uncertainty; no citation quotas.
- Evidence: inspect code, callers, and tests for effects, failures, and reuse; read official guidance, standards, and mature implementations.
- Complex sources: use `boxlite-distill` knowledge mode for mechanisms and prerequisites; keep decision-relevant alternatives, counterevidence, constraints, citations, and this skill's design outline.
- Citations: open originals; cite exact sections or `file:line`, preferably commit-pinned; snippets, memory, link lists, and generic claims are insufficient.
- Reuse: revalidate earlier research against current code and constraints.

### Analysis

1. Trace questions → sources → mechanisms and failures → constraint differences.
2. Compare alternatives and counterevidence; never invent consensus.
3. Separate observations from inferences.
4. Adopt, adapt, or reject with reasons; justify local fit and deviations.
5. Resolve approach and correctness gaps before registering or coding; give each remaining unknown its impact and next check.

### Search protocol

Every design follows these steps:

1. Known items: name them first, from outside the searched indexes; the search must find them.
2. Sources: ≥2 paper indexes (Scholar only supplements), ≥2 project engines, web, dependency specs at the used version, repo and upstream history with failed attempts.
3. Citations: chase both ways.
4. Stop: when a round or 3 queries add nothing; record why.
5. Log per source: tool, date, query count, stop status; exact queries only for kept items and the stop run.
6. SOTA: papers ≤24 months old or still leading; projects active within 12 months with ≥2 adoption signals besides stars; vendor docs prove existence only.
7. Disposition: adopt, adapt, or reject each relevant SOTA item with a reason; "none found" with a complete log passes.

## Design

- Form: 1–3 pages before coding; prefer a GitHub issue, then Notion, then a Linear issue; a tracking issue may hold it.
- Stance: challenge assumptions.
- Gate: [register](../../../CONTRIBUTING.md#pull-request-descriptions) it, then pass `design-auditor` before the first code edit; registering is not research.
- Lifecycle: keep it matching the final scope.

Outline:

- TL;DR: problem → outcome.
- Problem: current behavior or unmet need, concrete evidence, and impact.
- Scope: constraints, non-goals, acceptance.
- Related work and lessons: the research above; alternatives include reuse, simplify, and no change; recommendation.
- How it works: approach or mechanism → outcome; trade-offs.
- Validation: claim or risk → check → expected result; observed versus planned.
