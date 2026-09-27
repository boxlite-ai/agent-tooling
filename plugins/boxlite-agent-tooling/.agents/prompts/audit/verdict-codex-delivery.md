---
name: verdict-codex-delivery
used-by: .agents/hooks/audit/run-verdict-audit.sh
placeholders: spec_body, audit_prompt, codex_tree_hash
---
{{spec_body}}

{{audit_prompt}}

READ-ONLY DELIVERY OVERRIDE FOR THIS CODEX INVOCATION:
- Do not write or modify any file, including verdict_file.
- In procedure step 2, run the two read-only branch and HEAD commands, but do not
  create the temporary Git index. Use this parent-captured tree_hash exactly:
  {{codex_tree_hash}}
- For Tier-2, inspect any existing isolated red-to-green evidence in the transcript;
  do not create another worktree. If required evidence is absent, use step 5's
  blocked-proof form and state that residual risk.
- Replace procedure steps 6 and 7 with: return ONLY the dossier JSON object as your
  final response, with no Markdown fence or commentary.
- The Codex host captures that final response into a generation-owned staging file.
  The parent runner alone validates and publishes the authoritative dossier.
