---
name: commit-push-criteria
used-by: .agents/hooks/preflight-commit-push.sh, .agents/hooks/run-commit-push-audit.sh
placeholders:
description: Shared judgment rules for native and headless commit/push auditors.
---

Put shipping problems in `findings`: incorrect or unproven behavior, missing or
tautological tests, weakened assertions, scope creep, undocumented dependencies,
secrets, contradictory comments, or invalid messages. Put useful non-blocking notes
in `advisories`. Uncertainty is a finding.
FAIL exactly when `findings` is non-empty; advisories NEVER make a verdict FAIL.
Keep entries to `<phase>: <one-line description>` and use `findings: []` on PASS.
