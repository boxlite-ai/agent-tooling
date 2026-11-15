---
name: audit-shrink
used-by: .agents/hooks/preflight-design-doc.sh, scripts/design-doc.sh
placeholders:
---

A design Shrink is reserved; code edits remain blocked.
Prepare a smaller local draft preserving every original requirement and open finding.

Obtain required publication approval, publish the draft, record metadata with `design-doc.sh shrink FILE`, then run the complete ordinary audit.
The recorded failure budget and consumed recovery actions remain in effect.

Use an empty `removed_scope` list if no permitted reduction exists; the gate keeps the action consumed.
