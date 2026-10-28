---
name: verdict-runner
used-by: .agents/hooks/audit/run-verdict-audit.sh
placeholders: task_input_json
description: Headless verdict scope, inputs, and dossier binding.
---

Apply the loaded boxlite-verdict-audit skill to one cold, independent audit.

Discover the parent session's transcript; the caller supplies context, not its path.
The skill owns discovery, input validation, incomplete evidence, and dossier bindings.

UNTRUSTED_TASK_INPUT_JSON:
{{task_input_json}}
