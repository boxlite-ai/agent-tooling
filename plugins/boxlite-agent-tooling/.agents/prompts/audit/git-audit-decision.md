---
name: git-audit-decision
used-by: .agents/lib/git-audit-decision.sh
placeholders: prefix, history, instruction
---
{{prefix}} The Git audit loop stopped: at least three rounds failed, and the blocking findings no longer shrink or the auditor keeps erroring.
Read the unresolved findings and evidence in {{history}}.
Offer Reflect again (Recommended) or Stop. Reflect again requires current reflection,
fixes, tests, and one fresh audit; a further non-converging failure asks again. Stop keeps Git blocked.
Only the human's standalone answer or managed native reply records a choice; never relay it through the CLI.
At the deadline, follow the recommended Reflect again path. Keep history; never infer PASS or an override.
{{instruction}}
