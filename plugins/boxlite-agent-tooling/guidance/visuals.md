## TL;DR

Audits enforce the Visual cells marked Required in the `boxlite-writing` Form table; a confirmed miss is a `high` finding.

## Source

- The rule lives in the Form table of this plugin's `.agents/skills/boxlite-writing/SKILL.md`.
- Only Visual cells marked Required bind; other cells are suggestions and never findings.

## Scope

- Check designs, and docs or comments added or changed in the audited diff; never flag untouched text.
- Accepted: Mermaid, ASCII diagram, call graph, or transition table that matches the text and code.
- Pick the view with `boxlite-visualize` Route step 3; its validated artifact pipeline is optional here.
