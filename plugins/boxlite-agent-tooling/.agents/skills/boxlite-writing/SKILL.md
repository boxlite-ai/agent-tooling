---
name: boxlite-writing
description: Write or shorten human-facing replies, docs, PRs, issues, and comments as structured output.
---

## Rules

- Structure all human-facing output; use the forms and limits below.
- Write minimally, prompts included; keep evidence, risks, failures, uncertainty.
- Lead with the result; prefer a visual when one fits; add a brief real example when possible.

## TL;DR

- Start with `## TL;DR`: one plain sentence, then a same-level heading.
- Only short replies and comments may skip it; the limits below define short.

## Form

| Content | Form |
| --- | --- |
| Flow, architecture, interconnected causes | Diagram |
| Steps, priority | Numbered list |
| Parallel points | Bullets |
| Term and meaning | `Term: meaning` bullets |
| Items with 2+ attributes each; conditions → outcomes | Table |
| Reasoning | A short paragraph or cause-to-effect items |
| Trade-offs | Table: option, decision, reason |
| Commands, code, output | Code block |

## Limits

<!-- writing-limits:begin -->
| Rule | Limit | Checked by hooks |
| --- | --- | --- |
| TL;DR section | At most 39 words | Where callers require a cap |
| Short replies and comments | At most 80 words may omit TL;DR | Yes |
| GitHub paragraphs / list items | At most 80 / 40 words | Unless a valid TL;DR leads |
| Sentences | At most 25 words | No |
| Prose blocks | 1 sentence; up to 3 for connected reasoning | No |
| Lists | 2–7 flat items; 1 sentence each | No |
| Tables | 2–5 columns; one-line cells | No |
<!-- writing-limits:end -->

- Reasoning keeps its because or so.
- Order by importance; risks and uncertainty get their own items.

## Maintenance

- Edit [rules.json](rules.json), then run `bash scripts/sync-rules.sh`; `--check` detects drift.
- [scripts/check.sh](scripts/check.sh) supplies Bash functions; source it with Perl and jq available.
- Existing hook decisions stay unchanged; guidance-only limits await #317.
