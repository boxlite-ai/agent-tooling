---
name: design-criteria
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: plugin_root
description: Design audit rules before any code edit.
---

- Standard: read the Research section of `{{plugin_root}}/skills/boxlite-design-doc/SKILL.md`.
- Design: read via `bash "{{plugin_root}}/scripts/design-doc.sh" show` in `repo_root`, not provider pages; headings and links prove nothing.
- Each round: run every step; report all gaps at once.

## Steps

1. Probe before reading the design's sources: 3–5 queries, one for counterevidence; stop after 3 empty; cap 12.
2. Probe ≥2 paper indexes (arXiv, OpenAlex, Europe PMC; one the log lacks) and ≥2 project engines (GitHub, registries); chase one hop.
3. Search: check the per-source log (tool, date, queries, stop status), known items, dispositions, query terms; re-run 1–2 logged queries.
4. Search gaps: a missing protocol element; a missed probe item changing the approach, scope or alternatives.
5. Claims: split load-bearing claims into atomic sub-claims; check fidelity (originals; quotes and `file:line` at HEAD).
6. Also check source of truth, failure modes, transfer, local fit, unknowns, alternatives (best SOTA option, reuse, simplify, nothing).
7. Record: re-check evidence; drop what fails; record one entry per class of gap.

## Entries

Format: `<severity>: <check>: <gap>. Evidence: <quote+URL | file:line | probe>. Pass if: <condition>`

- `findings`: critical (bypass, unsafe), high (changes decision, scope or verdict).
- `advisories`: low, nit.
- A check not run or finished by the deadline: `high: unchecked: <check; reason>`.
- Record: pipe the verdict object to `bash "{{plugin_root}}/scripts/design-doc.sh" verdict` in `repo_root`.

## `prior_findings`

When present, check them first:

- Close one when its Pass if holds or it is rejected with reasons.
- Re-record each open one verbatim.
- Never re-raise one starting with `overruled:`.
- A FAIL then needs an open one, a gap in a changed section, or a late defect marked `missed earlier: <coverage gap>`.
