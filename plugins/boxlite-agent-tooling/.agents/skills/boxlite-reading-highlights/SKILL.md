---
name: boxlite-reading-highlights
description: Select meaningful reading highlights across media, including ADHD-assisted reading.
---

## TL;DR

Highlight each sentence’s essential meaning in short yellow phrases, aiming for five words while preserving meaning.

## Input and output

- Input: source text, scope, and optional word target or explicit hard limit. No browser required.
- Use for source highlighting, not summaries or medical advice.
- Output: sentence identifiers and exact source spans, with offsets or anchors to distinguish repeated text.
- Apply highlights only to the requested destination; otherwise return selections. Keep selection separate from rendering.

## Select

- Read the full scope. Cover every substantive sentence where possible, rather than only a few key sentences.
- Aim for five highlighted words per sentence. Use fewer for simple points; expand when meaning requires it. Never pad or cut useful phrases to meet the target.
- Enforce a hard limit only when explicitly requested.
- Select original phrases identifying topic, action, and object or result. Preserve essential negation, conditions, quantities, units, and causal direction.
- Prefer coherent phrases over scattered keywords. Never highlight whole sentences.
- Record each skipped sentence’s identifier and reason: navigation, filler, or no meaningful partial selection.
- Sum selected words per sentence. Count whitespace-separated English tokens; internal hyphens and apostrophes stay intact. Use language-appropriate segmentation elsewhere.

Example: “Never delay a customer conversation just to polish your slide design.” → “Never delay” + “customer conversation” (4 words).

Preserve conditions: “If adoption falls below 20%, pause rollout rather than expanding to every customer.” → “If adoption falls below 20%” + “pause rollout” (7 words).

## Review meaning

- Compare selections with each source sentence: retain the main claim, negation, conditions, quantities, units, and cause/result relationships.
- Read only the highlights in paragraph order. Repair unclear topics, referents, fragmented phrases, or isolated jargon using clearer original spans or necessary nouns, verbs, and objects.
- Expand the flexible target to preserve meaning. If an explicit hard limit prevents meaningful partial selection, record a skip instead of misleading readers. Mechanical checks cannot replace meaning review.

## Verify

- Check source matches, word boundaries, coverage, and selected words per sentence.
- Review above-target selections for unnecessary words; exceeding five is not a failure. Fix explicit hard-limit violations without dropping essential qualifiers.
- Excluding punctuation does not make a fully highlighted sentence acceptable.
- Report verified scope, target or hard limit, incomplete coverage, and relevant skip reasons. Distinguish selected spans from applied highlights. Never claim highlights replace the full text.

## Rendering

Preserve source text and existing annotations. Use supported formatting; prefer yellow. For browser application only, read [browser.md](references/browser.md).
