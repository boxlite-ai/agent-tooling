## TL;DR

Text that explains a flow, state, or structure needs a visual; a confirmed miss is a `high` finding.

## Scope

- Check designs, and docs or comments added or changed in the audited diff; never flag untouched text.
- Accepted: Mermaid, ASCII diagram, call graph, state/transition table, or before/after table.
- The visual must match the text and code.

## Required

| Text explains | Visual |
| --- | --- |
| A flow across 3+ steps, or across 2+ components, processes, or hooks | Sequence diagram or flowchart |
| A lifecycle or state machine with 3+ states | State diagram or transition table |
| Ordering, locks, retries, or concurrency | Sequence diagram with timing |
| Tree, link, or ownership changes | Before/after diagram |
| New architecture or boundaries | Context or container map |

## Not required

- Changes inside one function or file
- Renames, config, typos, dependency bumps, wording
- Rule lists already in tables
- 1–2 step behavior a worked example explains
- Ordinary code comments without a stateful algorithm
