---
name: boxlite-examples
description: Explain concepts and changes through concrete examples and verified real-world cases.
---

# BoxLite Examples

Carry one concrete example through the explanation, then state the principle.
Skip examples for trivial or code-only answers.

- **Whole picture first:** show actors, ownership, roles, field shapes, and links
  before zooming in. Distinguish contents from metadata describing them.
- **Concrete state:** use records, balances, bytes, or queue contents with values
  and units. Keep identifiers consistent; mark absent records.
- **Trace change:** input → action → before/after state → output. Carry unchanged
  values forward; distinguish external outcomes from local commits.
- **Time:** T1/T2/T3 express order. Preserve concurrency; give durations only when
  relevant and known. Compare alternatives using the same input.

Choose the simplest useful form; UML is optional:

| Question | Useful form |
| --- | --- |
| Who interacts, when? | Sequence diagram spanning the steps |
| What exists and how is it related? | Object/class diagram or record table |
| Where does each part fit? | ASCII layout with ranges, contents, mappings |
| What value changes? | Before/after table or calculation |

Do not require diagrams per step. Keep prose brief; omit repeated structures and
facts already visible. Inspect and cite sources; label illustrative values and
assumptions. Never invent measurements, balances, or implemented behavior.

Read only the relevant example; these are models, not fixed templates:

- [Commerce top-up](references/top-up-example.md): records and payment sequence.
- [VMM memory](references/vmm-memory-example.md): whole layout, slots, one byte.
