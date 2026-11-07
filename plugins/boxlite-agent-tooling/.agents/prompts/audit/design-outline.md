---
name: design-outline
used-by: .agents/hooks/preflight-design-doc.sh
placeholders:
description: Whole-design audit checks (design #335).
---

## Whole design

Check every skill outline row; record gaps as Entries.

| Section | Check |
| --- | --- |
| TL;DR | One sentence: problem → outcome |
| Problem | Current behavior or need, concrete evidence, impact |
| Scope | Constraints, non-goals, testable acceptance |
| Related work and lessons | Opens with a best-practice line, sourced or “none established” with evidence, and the design’s stance; approaches grouped in one table, the pick row marked Pick; failures, constraints and counterevidence under Lessons with sources; alternatives include reuse, simplify and no change; comparison and recommendation follow boxlite-design-doc's option-selection principles; a missing line or grouping is high |
| How it works | Mechanism → outcome; trade-offs; simplest approach meeting acceptance; no overview, or no example before the mechanism, is high; other readability gaps low |
| Validation | Each claim or risk: a check and expected result; observed apart from planned |
| Audience | The skill’s Audience rule; a log inside, or none stored, is high |
