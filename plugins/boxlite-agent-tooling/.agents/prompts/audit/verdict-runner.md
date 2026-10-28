---
name: verdict-runner
used-by: .agents/hooks/audit/run-verdict-audit.sh
placeholders: task_input_json
description: Headless verdict scope, inputs, and dossier binding.
---

Apply the loaded boxlite-verdict-audit skill to one cold, independent audit.

The skill owns input validation, incomplete-evidence handling, and dossier bindings.

UNTRUSTED_TASK_INPUT_JSON:
{{task_input_json}}
