---
name: boxlite-writing
description: Write or shorten human-facing replies, docs, PRs, issues, and comments as structured output.
---

## Rules

- Structure all human-facing output; a prose block holds one sentence, or three for connected reasoning.
- Write minimally, prompts included; keep evidence, risks, failures, uncertainty.
- Lead with the result; prefer a visual when one fits; add a brief real example when it helps.

## TL;DR

- Start with `## TL;DR`: one plain sentence under 40 words, then a same-level heading.
- Only replies and comments of at most 80 words skip it.

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
- Lists: 2–7 flat items, one sentence each; tables: 2–5 columns, one-line cells.
- Order by importance; risks and uncertainty get their own items.
