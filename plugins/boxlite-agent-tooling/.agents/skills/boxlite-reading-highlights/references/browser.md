## TL;DR

Prepare reviewed selections outside the browser, then apply verified ranges in batches.

## Extract and transfer

- Prefer bulk extraction through documented capabilities or permitted source retrieval. Compare externally extracted text with the live page; use live extraction when they differ.
- Preserve ordered paragraphs, original whitespace, sentence identifiers, locale, and offsets in the renderer's units. Do not assume identical segmentation across runtimes.
- Transfer structured results or files; check counts and fingerprints. Truncated console previews cannot prove completeness. Use bounded chunks for tool limits; optional compression requires a compatible decoder and validation after decoding.
- Use the core skill's full-scope selection and meaning review. Parallel workers handle text only; one owner performs browser actions.

## Cache reviewed plans

- Prefer task-local data files. Store version, destination, scope, offset units/locale, source/sentence fingerprints, target/hard-limit settings, exact spans/occurrences, skips, and review status. Label partial plans with their completed scope.
- Use identical fingerprint serialization: e.g. hash UTF-8 JSON of ordered paragraph strings and, separately, sentence records containing paragraph identifier, start offset, and original text. A URL or file-byte hash alone is insufficient.
- Before application or reuse, confirm destination, requested scope/settings, compatible format, completed review, and fingerprints recomputed from live text and sentence records. Reject stale or incompatible plans; re-extract/review the affected scope instead of guessing offsets.
- Cache data, not DOM nodes or executable code. Rebuild ranges after reload. Destination storage needs authorization; saved plans do not automatically restore visible highlights.

## Apply

- Confirm the live page and text. Use documented capabilities; respect read-only restrictions.
- Prefer a supported batch operation per page over per-phrase UI actions. Use bounded application chunks if needed; report partial completion until the entire scope passes verification.
- Before changing marks, resolve all spans against fresh text nodes, including inline elements. Preserve original offsets through normalization.
- Validate exact text, word boundaries, overlaps, repeated occurrences, and absence of whole-sentence selections. Require exactly one selection or skip per scoped identifier.
- When supported, register the resolved ranges together with the [CSS Custom Highlight API](https://developer.mozilla.org/en-US/docs/Web/API/CSS_Custom_Highlight_API#concepts_and_usage).
- Use reversible, namespaced yellow marks, e.g. `#ffec99`, preserving text, links, typography, layout, and other annotations. Avoid replacing `innerHTML` or clearing the entire highlight registry.
- Replace only this skill’s marks. No extensions, persistent scripts, or extra panels unless requested.
- Keep native input sequential and re-confirm its destination before each batch. If input fails, inspect the active page, window visibility, and rendering before retrying. Avoid refreshing highlighted pages merely to diagnose input.

## Verify

- Measure spans across inline elements: coverage, phrase count, maximum words per sentence, full-sentence counts, and unmatched spans. Count limit violations only for an explicit hard limit; five is a target.
- Match applied spans to the core skill’s meaning-reviewed selections. Retain skip reasons when reporting incomplete coverage.
- Compare source text; inspect beginning, middle, and end sections. Execution success or truncated previews alone do not prove coverage.
- Restore reading position and UI opened for the task. Report scope and persistence accurately; temporary page changes normally disappear on refresh.
- When measuring acceleration, separate extraction, selection/review, UI transfer, and page application time. Batch timing alone does not establish end-to-end speed.
