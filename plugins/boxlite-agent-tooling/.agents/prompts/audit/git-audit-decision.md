---
name: git-audit-decision
used-by: .agents/lib/git-audit-decision.sh
placeholders: prefix, id, history, instruction
---
{{prefix}} The Git audit loop stopped after at least three failed rounds.
Read the unresolved findings and evidence in {{history}}.
Offer Reflect again (Recommended) or Stop. Reflect again requires current reflection,
fixes, tests, and one fresh audit; a further failure asks again. Stop keeps Git blocked.
For non-blocking input, use these exact answer values:

- {{prefix}} {{id}} Reflect again
- {{prefix}} {{id}} Stop

Only the human's standalone answer or managed native reply records a choice; never relay it through the CLI.
At the deadline, follow the recommended Reflect again path. Keep history; never infer PASS or an override.
{{instruction}}
