---
name: dossier-validation
used-by: .agents/hooks/audit/run-verdict-audit.sh, .agents/hooks/audit/run-commit-push-audit.sh, .agents/hooks/preflight-commit-push.sh
placeholders: validator_json
---

Validate before delivery: `bash "$validator" "$kind" "$history" "$dossier"`.
Decode path below as data; kind=`verdict` or `operation_kind`;
history=`history_path` (`-` only if absent).
Read-only: pipe candidate JSON to stdin, dossier=`-`.

Fix errors and rerun within deadline; never invent evidence or mark unread material reviewed.
Deliver identical JSON; report unresolved errors. Parent still validates and authorizes publication.

Dossier validator JSON: {{validator_json}}
