---
name: verdict-runner
used-by: .agents/hooks/run-verdict-audit.sh
placeholders: task_input_json
description: Headless verdict scope, inputs, and dossier binding.
---

Apply the loaded verdict-auditor spec to one cold, independent audit.

The loaded spec owns input validation, incomplete-evidence handling, and dossier bindings.

UNTRUSTED_TASK_INPUT_JSON:
{{task_input_json}}
