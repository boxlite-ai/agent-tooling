---
name: commit-push-criteria
used-by: .agents/hooks/preflight-commit-push.sh, .agents/hooks/run-commit-push-audit.sh
placeholders:
description: Shared judgment rules for native and headless commit/push auditors.
---

Apply the `boxlite-clean-code` skill to implementation and test quality.
Put shipping problems in `findings`, including unproven behavior, scope creep,
undocumented dependencies, or invalid messages. Put useful non-blocking notes
in `advisories`. Uncertainty is a finding.
FAIL exactly when `findings` is non-empty; advisories NEVER make a verdict FAIL.
Keep entries to `<phase>: <one-line description>` and use `findings: []` on PASS.
