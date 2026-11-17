---
name: boxlite-writing
description: Write or shorten human-facing replies, docs, PRs, issues, and comments as structured output.
---

## Rules

- Structure all human-facing output; a prose block holds one sentence, or three for connected reasoning.
- Write minimally, prompts included; keep evidence, risks, failures, uncertainty.
- Lead with the result.

## TL;DR

- Start with `## TL;DR`: one plain sentence under 40 words, then a same-level heading.
- Only replies and comments of at most 80 words skip it.

## Form

- Choose the structure, then the smallest useful illustration; one concrete visual can also serve as the example.
- Explanations in any topic require a concrete example, visual, or call graph; flow, architecture, and interconnected causes require a diagram.
- Use the Structure cell; in Example and Visual, only cells marked Required are mandatory, and others describe what fits when needed.

| Reader need | Structure | Example | Visual |
| --- | --- | --- | --- |
| Fact or status | Direct sentence or labeled item | If interpretation needs clarification | Usually unnecessary |
| Term and meaning | `Term: meaning` bullets | Instance; non-example if easily confused | If shape, location, or relationships define it |
| Parallel points | Bullets | If a point needs clarification | If relationships among points matter |
| How something works | Overview → mechanism → result | Trace one input → action → output | For interacting parts; call graph for source mechanics |
| Steps or priority | Numbered list; prerequisites and verification for procedures | Realistic execution with expected outcome | Screenshot to locate controls; diagram for branching flow |
| Comparison or trade-offs | Table: shared attributes, decision, reason | Same scenario for each option | If topology, scale, or measured differences matter |
| Conditions → outcomes | Decision table | Typical and boundary cases | Decision tree for dependent branches |
| Flow or architecture | Whole system → relevant parts | One request crossing boundaries | Required: components, ownership, and connections |
| Timing or concurrency | Ordered events with named actors | One retry, race, callback, or failure | Required: sequence diagram or timeline for order and overlap |
| States and transitions | State → trigger → resulting state | One object's lifecycle | State diagram for branching or looping transitions |
| Hierarchy | Nested outline or parent/child table | One path through the hierarchy | Tree when nesting is hard to follow |
| Change | Before → after → consequence | Identical input exposing changed behavior | Adjacent views if connections or layout change |
| Calculation | Formula → units → substitution → result | Worked values with units | If geometry, accumulation, or scale explains the result |
| Data patterns | Question → finding → evidence | Representative observations; retain dataset context | Chart matched to trend, distribution, ranking, or relationship |
| Exact values; items with 2+ attributes | Table with labels and units | Usually unnecessary | Only if patterns also matter |
| Failure diagnosis | Symptom → evidence → cause → remedy → verification | Failing case and corrected outcome | Diagram if dependencies or timing explain failure |
| Reasoning | Up to three connected sentences, or cause-to-effect items | Concrete case or counterexample | Required for interconnected causes |
| Commands, code, output | Copyable code block | Inputs, expected output, relevant errors | Only if surrounding flow needs explanation |

## Limits

- Sentences: at most 25 words; reasoning keeps its because or so.
- Lists: 2–7 items, one sentence each, or up to three for connected reasoning.
- Nesting: sub-lists of 2–3 items, at most 3 levels.
- Tables: 2–5 columns, one-line cells.
- Order by importance; risks and uncertainty get their own items.
