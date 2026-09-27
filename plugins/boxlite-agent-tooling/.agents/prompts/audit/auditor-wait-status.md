---
name: auditor-wait-status
used-by: .agents/hooks/auditor-control.sh
placeholders: auditor
---
[auditor-control] {{auditor}} is still running after 30 seconds. Publish one short, non-blocking assistant status: "Auditor is still running. Reply with force-pass-auditors: <reason> to override both auditor gates for this prompt, or do nothing to keep waiting." Keep the auditor running. If its completion is already visible, suppress this stale status.
