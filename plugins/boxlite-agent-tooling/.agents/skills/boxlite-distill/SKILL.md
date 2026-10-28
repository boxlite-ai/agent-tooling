---
name: boxlite-distill
description: Distill topics and code into essential knowledge or a minimal working example for learning.
---

## TL;DR

Extract the smallest understandable core that preserves the requested scope, essential meaning, and defining behavior.

## Details

Apply `boxlite-writing`. Follow the receiving repository's workflow when creating code.

### 1. Define the target

- Establish the learning question or observable behavior, sources, audience, and constraints. Infer reasonable defaults; ask only when missing information changes correctness or scope.
- For a whole-system request, name its purpose and defining behavior and cover its major design boundaries. When implementation is requested, preserve one complete instance of that behavior. A subsystem exercise satisfies a narrower request, not the whole-system target.
- Choose the mode from the requested outcome. A code source alone does not request an implementation.

| Mode | Outcome | Read |
| --- | --- | --- |
| Knowledge | Essential concepts and how they connect | [Knowledge guide](references/knowledge.md) |
| Implementation | A minimal runnable example preserving the requested behavior | [Implementation guide](references/implementation.md) |
| Both | Explain the core and demonstrate it in code | Both guides |

For codebase or architecture explanations, also read [Code design](references/code-design.md). Preserve the original component responsibilities and collaboration, even when the example simplifies them.

Exact source highlighting belongs to `boxlite-reading-highlights`. Distillation may paraphrase and omit whole sections. Preserve original material; create a separate artifact unless editing the source was requested.

### 2. Trace the core

- Inspect the relevant source context; for code, follow the execution path and its dependencies.
- Map prerequisites → concepts or operations → result. Keep essential conditions, negation, quantities, and causal direction.
- Link retained claims or components to source sections or code locations. Label inference and unresolved conflicts; never invent missing evidence.

### 3. Apply the removal test

For each candidate: **would removing it break understanding, a necessary condition, or the chosen behavior?** Keep it if yes; otherwise omit it.

- Remove repetition, tangents, optional features, and incidental infrastructure.
- Assess understanding and execution separately. Keep required code and setup complete; execution-only detail can live in linked references. Moving core logic into an unexplained dependency does not remove it.
- Preserve the target before optimizing concepts, tooling, or size. Prefer fewer concepts and components over compressed wording or code. Honor explicit size limits only while preserving the target; explain any conflict.
- Stop when each remaining element has a necessary role. Describe the result as minimal for this scope; do not claim a globally smallest solution.

### 4. Present the result

Use these labeled sections or a compact table; omit inapplicable fields and group incidental omissions.

| Field | Include |
| --- | --- |
| Goal and scope | Source purpose, requested boundary and defining behavior; what the reader will understand or reproduce; prerequisites |
| Essential core | Concepts; for code, original component roles, ownership, and collaboration; why they matter and their sources |
| Demonstration | One worked example; implementation mode adds files, run instructions, and expected behavior |
| Omissions | What was removed and the resulting limits |
| Verification | What was checked, observed results, and remaining gaps |

Start with purpose, a compact overview and essential roles at one level; follow with one causal example, run commands, and critical conditions/limits. Explain necessary unfamiliar terms once. Link deeper subsystem detail, exact layouts, encodings, extended traces, and raw evidence unless needed for core understanding. Avoid repeating the overview in each section.

### 5. Verify sufficiency

- Review the completed artifact against the sources, requested scope, and chosen guide's checks. Identify the versions reviewed; do not mix changing drafts.
- Check explanation separately from execution: from the main lesson and stated background, explain the purpose, causal flow, and one omission's consequence; for code, include state ownership and collaboration. Repair answers needing unexplained concepts or syntax; passing code tests does not establish reader understanding.
- Repair missing links and misleading simplifications. Remove remaining elements that fail the removal test.
- Report applicable criteria separately: architecture/scope coverage, source fidelity, execution, reader sufficiency, and evidence completeness. Give each its observed result and limits. An incomplete required check prevents a complete verdict; successful execution or matching hashes alone cannot establish the other criteria.
