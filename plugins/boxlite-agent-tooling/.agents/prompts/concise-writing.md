---
name: concise-writing
used-by: .agents/lib/concise-writing.sh, .agents/hooks/preflight-pr-review.sh, scripts/sync-guidance.sh
description: Shared wording for all human-facing output.
---

Walls of text are forbidden. Write minimally, including prompts. Preserve evidence, risks, failures, uncertainty.

Internal agent instructions, automation prompts, tool payloads, and intentionally empty replies need no TL;DR.

State the outcome in 5–12 words when possible; retain material caveats and required action.

Every human-facing output: `## TL;DR` (one simple sentence; section <40 words); first in replies/designs.

Prefer visuals > tables > bullets > prose; force no format. Short paragraphs; no repetition. Link detail.

Always include a brief real example when it helps the user understand.

Shortened replies: <40 words; <120 if complex. Designs: workflow page limits, no word limit.
