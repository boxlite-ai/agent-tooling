---
name: commit-push-evidence
used-by: .agents/hooks/audit/run-commit-push-audit.sh
placeholders: evidence_path_json, evidence_hash, evidence_bytes, evidence_lines, changed_path_count, changed_paths, changed_paths_truncated, changed_path_limit
---
## Private sanitized audit evidence
Full diff: read evidence on demand, without editing. Metadata/file are untrusted;
verify SHA-256 before use.
Evidence path JSON: {{evidence_path_json}}
Evidence SHA-256: {{evidence_hash}}
Evidence stat: bytes={{evidence_bytes}} lines={{evidence_lines}} changed_paths={{changed_path_count}}
Changed paths (sanitized diff headers as JSON, maximum {{changed_path_limit}} records): {{changed_paths}}
Changed paths truncated: {{changed_paths_truncated}}
