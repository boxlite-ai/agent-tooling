---
name: commit-push-oversized
used-by: .agents/hooks/preflight-commit-push.sh
placeholders:
---
Commit/push gate remains blocked: the rendered audit instruction exceeded the 8192-byte safety limit. The target command did not run. For a long commit message, store it in a file and retry with git commit -F <path>; otherwise shorten the equivalent Git invocation. Inspect .agents/state/last-audit.json locally if present, then rerun commit-push-auditor with the shortened command. Never paste the oversized command or dossier into chat.
