---
name: concise-writing
used-by: .agents/lib/concise-writing.sh, .agents/hooks/preflight-pr-review.sh, scripts/sync-guidance.sh
description: Shared wording for all human-facing output.
---

Walls of text are forbidden. Write minimally, including prompts. Preserve evidence, risks, failures, uncertainty.

Every human-facing output: `## TL;DR` (one simple sentence; section <40 words); first in replies/designs.

Artifacts submitted for peer review must include `## How it works`, explaining how key steps or decisions produce the result. This includes every PR, draft, design proposal, and revision. For non-code changes, explain the rationale; one sentence can suffice.

Prefer: visuals > tables > bullets > prose (under 40 words; 120 for complex topics); Always include a brief real example when it helps the user understand.
