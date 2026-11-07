---
name: boxlite-design-doc
description: Research best practices; write design docs before coding.
---

## Research

Answer: what is the best practice for this work, and why?

### 1. Frame

- Depth: follows impact and uncertainty; no citation quotas.
- Evidence: inspect code, callers, and tests for effects, failures, and reuse; read official guidance, standards, and mature implementations.
- Complex sources: use `boxlite-distill` knowledge mode for mechanisms and prerequisites; keep decision-relevant alternatives, counterevidence, constraints, citations, and this skill’s design outline.
- Citations: open originals; cite exact sections or `file:line`, preferably commit-pinned; snippets, memory, link lists, and generic claims are insufficient.
- Reuse: revalidate earlier research against current code and constraints.

### 2. Search protocol

Every design:

1. Known items: name them first, from outside the searched indexes; the search must find them.
2. Sources: search each one in the sources table.
3. Chase: follow citations both ways.
4. Stop: when a round or 3 queries add nothing; record why.
5. Log: per source, as in the log table; after registering, store it with `design-doc.sh log < log.md`, never in the doc; empty input deletes it.
6. SOTA: apply the SOTA table.
7. Disposition: adopt, adapt, or reject each relevant SOTA item with a reason; "none found" with a complete log passes.

| Source | Requirement |
| --- | --- |
| Paper indexes | ≥2; Scholar only supplements |
| Project engines | ≥2 |
| Web | Searched |
| Dependency specs | At the used version |
| Repo and upstream history | With failed attempts |

| Per-source log | Content |
| --- | --- |
| Fields | Tool, date, query count, stop status |
| Exact queries | Only for kept items and the stop run |

| SOTA | Rule |
| --- | --- |
| Papers | ≤24 months old or still leading |
| Projects | Active within 12 months with ≥2 adoption signals besides stars |
| Vendor docs | Prove existence only |

### 3. Analyze

1. Trace questions → sources → mechanisms and failures → constraint differences.
2. Compare alternatives by the principles below, with counterevidence.
3. Separate observations from inferences.
4. Adopt, adapt, or reject with reasons; justify local fit and deviations.
5. Resolve approach and correctness gaps before registering or coding; give each remaining unknown its impact and next check.

#### Option-selection principles

Set hard constraints and decision priorities first; apply `boxlite-clean-code` to implementation trade-offs.

| Criterion | Principle |
| --- | --- |
| Correctness and safety | Reject options that violate required behavior, security, or compatibility; fewer lines cannot compensate. |
| Industry practice | Among viable options, prefer established industry best practice supported by standards or mature implementations; justify departures with local evidence. |
| Readability | Prefer explicit control flow, ownership, and familiar repository patterns; avoid clever compression and unnecessary indirection. |
| Performance | Meet workload and resource requirements; support claimed advantages or equivalence with measurements or source evidence; mark estimates and unknowns. |
| Simplicity and reuse | Prefer existing capabilities and fewer moving parts; new abstractions or dependencies must justify their cost against current requirements. |
| Maintenance risk | Prefer options easier to test, diagnose, change, and roll back; consider migration and operational costs. |
| Lines of code (LOC) | Among equally suitable options, prefer fewer maintained lines without harming correctness, readability, performance, or maintenance. |

- Compare whole solutions, helpers and configuration included; never cut LOC by hiding complexity, compressing formatting, or dropping needed checks or tests.
- Apply the same criteria to every viable option; record benefits, costs, evidence, and the deciding trade-off in the recommendation.
- When criteria conflict, explain which task constraint takes priority; resolve decision-changing unknowns before choosing.
- Popularity is not consensus; never invent consensus; when no industry best practice is established, state that uncertainty and compare the evidence.

## Design

### 4. Write

Outline:

| Section | Content |
| --- | --- |
| TL;DR | Problem → outcome |
| Problem | Current behavior or unmet need, concrete evidence, and impact |
| Scope | Constraints, non-goals, acceptance |
| Related work and lessons | Research conclusions; alternatives include reuse, simplify, and no change; comparison and recommendation using the option-selection principles |
| How it works | Overview line, concrete example, and defined terms first; then approach or mechanism → outcome and trade-offs; secondary changes in their own subsections. Undefined term: a project-specific name used before any definition, link, or plain explanation |
| Validation | Claim or risk → check → expected result; observed versus planned; design-specific checks only |

- Audience: human reviewers; apply `boxlite-writing`. Omit the log, search method, decision-irrelevant evidence limits, coding-agent instructions, repository workflow, PR or task bookkeeping, and references to this tooling.
- Form: 1–3 pages before coding; prefer a GitHub issue, then Notion, then a Linear issue; a tracking issue may hold it.
- Stance: challenge assumptions.
- Lifecycle: keep it matching the final scope.

### 5. Gate

Finish research before registering and before any implementation, tests and shell included; never backfill it. Then [register](../../../CONTRIBUTING.md#pull-request-descriptions) the design, store the log, then pass `design-auditor` and record `design-advisor` advice before the first code edit; registering is not research.
