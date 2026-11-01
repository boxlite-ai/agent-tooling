---
name: boxlite-writing
description: Write or shorten human-facing replies, docs, PRs, issues, and comments as structured output.
---

## Rules

- Structure all human-facing output: headings, lists, tables, diagrams, code blocks.
- A prose block holds one sentence; connected reasoning may take up to three.
- Write minimally everywhere, prompts included; keep evidence, risks, failures, uncertainty.
- Lead with the result; prefer a visual when one carries it.
- Add a brief real example when it helps understanding.

## TL;DR

- Start with `## TL;DR`: one plain sentence under 40 words, then a same-level heading.
- Only replies and comments of at most 80 words skip it; they lead with the point.

## Form

| Content | Form |
| --- | --- |
| Flow, architecture, interconnected causes | Diagram |
| Steps, priority | Numbered list |
| Parallel points | Bullets |
| Term and meaning | `Term: meaning` bullets |
| Items with 2+ attributes each; conditions → outcomes | Table |
| Reasoning | A paragraph of up to three sentences, or cause-to-effect items |
| Trade-offs | Table: option, decision, reason |
| Commands, code, output | Code block |

## Limits

- Sentences: at most 25 words; reasoning keeps its because or so.
- Lists: 2–7 flat items, one sentence each.
- Tables: 2–5 columns, one line per cell.
- Order items by importance; give risks and uncertainty their own items.
