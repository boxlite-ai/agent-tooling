---
name: verdict-oversized
used-by: .agents/hooks/audit/preflight-verdict-check.sh
placeholders:
---
Verdict gate remains blocked: the rendered proof instruction exceeded the 8192-byte safety limit. Inspect the session-scoped .agents/state/last-verdict*.json dossier locally; do not paste its oversized findings or the transcript into chat. Run verdict-auditor synchronously against the current transcript (or use run-verdict-audit.sh headlessly), let the auditor write the dossier, then retry the ending. On PASS repeat the blocked answer; on FAIL revise it and re-audit.
