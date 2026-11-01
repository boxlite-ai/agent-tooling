---
name: audit-reflect
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: plugin_root, history_hash, failure_ids, findings
---
The next design audit waits for a reflection. Open findings:
{{findings}}
Compare every failed audit, diagnose why earlier fixes failed, change the approach, and run
at least one discriminating check. Pipe one JSON object to
`bash "{{plugin_root}}/scripts/design-doc.sh" reflect`:
`{"history_hash":"{{history_hash}}","failure_ids":{{failure_ids}},"diagnosis":…,"previous_fixes_failed_because":…,"changed_approach":…,"checks":[{"command":…,"expected":…,"observed":…,"evidence":…}],"auditor_gaps":[{"attempt_id":…,"gap":…,"next_check":…}]}`.
Limits: 8 KiB, 1–8 checks, 0–8 gaps. Then audit again.
