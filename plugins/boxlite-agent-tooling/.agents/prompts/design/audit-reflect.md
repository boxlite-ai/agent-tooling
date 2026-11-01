---
name: audit-reflect
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: plugin_root, history_hash, failure_ids, findings
---
The next design audit waits for a reflection. Open findings:
{{findings}}

1. Compare every failed audit and diagnose why earlier fixes failed.
2. Change the approach and run at least one discriminating check.
3. Pipe one JSON object, at most 8 KiB with 1–8 checks and 0–8 gaps, to `bash "{{plugin_root}}/scripts/design-doc.sh" reflect`:
   `{"history_hash":"{{history_hash}}","failure_ids":{{failure_ids}},"diagnosis":…,"previous_fixes_failed_because":…,"changed_approach":…,"checks":[{"command":…,"expected":…,"observed":…,"evidence":…}],"auditor_gaps":[{"attempt_id":…,"gap":…,"next_check":…}]}`
4. Audit again.
