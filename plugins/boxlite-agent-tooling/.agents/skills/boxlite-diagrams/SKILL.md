---
name: boxlite-diagrams
description: Draw and validate source-grounded BoxLite diagrams; split big topics into topic sections.
---

# BoxLite Diagrams

Smallest source-grounded view set that answers the question. Evidence and composition
are separate gates; pass both.

## Route

1. Resolve repository root, revision(s), subject, reader, and output location. For an
   issue or PR, `gh` resolves base/head.
2. `rg -n 'flowchart|sequenceDiagram|^## .*Architecture' README.md apps docs .github` —
   reuse the nearest composition; re-verify anything drift-prone against source and IaC.
3. Pick views that answer distinct questions:

   | Need | View |
   | --- | --- |
   | deployment, topology, boundaries, overview, picture | architecture |
   | order, retries, concurrency, callbacks, failure | sequence |
   | source mechanics, function path | call graph, + sequence only if time matters |
   | issue, before/after | smallest unambiguous set |
   | named views | exactly those |

4. Read [output-contract.md](references/output-contract.md) before any artifact, and
   [architecture-composition.md](references/architecture-composition.md) before any
   architecture, deployment, topology, overview, or picture work.

Never edit production code for a diagram request; save into the repository only when
asked.

## Split a big topic

Every diagram must fit 1600×900 (validated). Shape decides, not node count:

| Diagram | Renders | |
| --- | --- | --- |
| 20 nodes, top-down chain | 148×1946 | too tall |
| 12 nodes, fanned out | 1879×164 | too wide |
| 16 nodes, zoned | 1504×562 | fits |

Draw one diagram. Split only when its own honest view at its altitude cannot fit or
mixes altitudes — then test each child the same way, so depth follows the subject:

```text
overview                                 1 — most subjects stop here
overview → runner_fleet                  2 — systems → one system's parts
overview → runner_fleet → boxlite_core   3 — → one part's mechanics; the limit
```

- Level 3 still overflows → the altitude is wrong, not the depth.
- Index topic (has children) ≤12 nodes; leaf topic 12–20.
- A child sits one altitude below its parent and reuses the parent element's ID. Same
  altitude is a crop, not a zoom.
- Split along existing boundaries — scope zone, ownership boundary, deployment unit, one
  request path. One question sentence per topic: overlap → merge; two altitudes → split.

## Build

1. States: overview `Current`; open issue `Current` + `Expected (proposed)`; PR, commit,
   branch, or working tree `Before` + `After`.
2. Read only what the altitude needs. Cite exact revision, repo-relative path, inclusive
   lines, symbol, narrow tokens; deleted hop → base revision, added hop → head. Never
   infer a call from a matching name or invent a symbol; proposed behavior cites the
   issue and stops at the last real boundary.
3. Write `diagram.md` + `evidence.json` in a temp task dir per the contract; one ID per
   element across views, states, and topics.
4. Annotate the exact node or edge. `← BUG: <why>` on the faulty `Current`/`Before` hop;
   a bug fix ends with `Fixes #<n>`.
5. Validate; fix from `validation.json`; after three failed rounds return the report,
   not an unverified diagram.
6. Open every PNG at fit-to-page and run the composition visual QA. Say that you did —
   reading source is not visual QA.
7. Run the verdict-auditor workflow before presenting architectural conclusions.

## Validate

```bash
python3 .agents/skills/boxlite-diagrams/scripts/validate_diagrams.py \
  --repo "$(git rev-parse --show-toplevel)" \
  --document "$TASK_DIR/diagram.md" \
  --evidence "$TASK_DIR/evidence.json" \
  --report "$TASK_DIR/validation.json"
```

Exit `0` pass, `1` invalid, `2` missing tool; checks are prefixed per topic. Passing
proves render, fit, and traceability — not composition or completeness.

## Respond

Lead with the picture (topic tree: overview, then its outline). `Before`/`After`
adjacent. Code path: call graph + one `Key:` line first. End with the evidence summary,
the visual-QA statement, and the report path when files were requested.
