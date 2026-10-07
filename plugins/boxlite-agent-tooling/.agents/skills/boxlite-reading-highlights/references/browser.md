## TL;DR

Apply selected spans to the requested page; keep selection independent of browser mechanics.

## Apply

- Confirm the live page and text. Use documented capabilities; respect read-only restrictions.
- Resolve sentence-local spans against current text. Disambiguate duplicates and preserve offsets through normalization.
- Use reversible, namespaced highlights, e.g. yellow `#ffec99`. Preserve text, links, typography, and layout; avoid replacing `innerHTML`.
- Replace only this skill’s marks. No extensions, persistent scripts, or extra panels unless requested.

## Verify

- Measure spans across inline elements: coverage, phrase count, maximum words per sentence, full-sentence counts, and unmatched spans. Count limit violations only for an explicit hard limit; five is a target.
- Match applied spans to the core skill’s meaning-reviewed selections. Retain skip reasons when reporting incomplete coverage.
- Compare source text; inspect beginning, middle, and end sections. Execution success or truncated previews alone do not prove coverage.
- Restore reading position. Report scope and persistence accurately; temporary page changes normally disappear on refresh.
