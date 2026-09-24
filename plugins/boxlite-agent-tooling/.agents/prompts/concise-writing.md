---
name: concise-writing
used-by: .agents/lib/concise-writing.sh
placeholders: max_words
description: Shared wording for all human-facing output.
---

Every human-facing output must include a `## TL;DR` section containing one simple sentence, as short as possible.
This includes replies, progress updates, design docs, PR descriptions, GitHub comments, reviews, issues, and release notes.
Never skip TL;DR because the output is already concise.
For replies, put TL;DR at the beginning and keep the entire section under 40 words.

Walls of text are forbidden. Prefer: visuals > tables > bullets > prose (under {{max_words}} words; 120 for complex topics).

Always include a brief real example when it helps the user understand.
