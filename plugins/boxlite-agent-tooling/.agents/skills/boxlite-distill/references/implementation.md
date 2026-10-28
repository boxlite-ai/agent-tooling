## TL;DR

Expose a system's essential mechanism in a small runnable artifact with a defined behavior, explicit omissions, and observed verification.

## Details

### Bound the behavior

- Define inputs, expected effects, supported environment, and required setup → core work → completion/cleanup. Choose variants within the requested behavior, not a different behavior.
- For a whole-system target, keep one complete path through its defining capability and required system boundaries. Remove optional features; a helper simulation cannot replace that path. Honor explicitly requested subsystem scope.
- Prefer familiar representations after preserving the target. Explain unavoidable platform calls or startup syntax; reducing dependencies does not justify simulating the required mechanism.
- Trace the real path through entrypoint, state, operations, and dependencies. Identify which source components are necessary for that behavior.
- Default to a separate learning artifact. Preserve the original implementation unless modification was requested.

### Extract

1. Keep the actual core logic, required setup, data, and cleanup. Preserve source attribution and applicable license notices when copying code.
2. Remove unrelated features and generalization. Use meaningful names for state, flags, and protocol values; explain necessary encodings. Preserve readable control flow even when it takes more lines. Add an abstraction only when it clarifies the mechanism.
3. Use standard libraries and required platform APIs where appropriate. Do not replace the mechanism under study with a mock, canned output, or a wrapper around the original system.
4. Keep dependencies explicit. Supply complete files and exact setup/run commands; do not call pseudocode or unfinished stubs runnable.
5. Preserve checks needed for the supported inputs and execution environment. Disclose omitted guarantees and their consequences; learning scope does not authorize weakening production code.

### Demonstrate

Use one input → execution → result trace, linking each conceptual step to code. Show expected output separately from captured output.

Map original components to retained, merged, replaced, or omitted parts, with lost capabilities and semantic differences. Preserve source roles without forcing every abstraction into the reduced code. Keep conditions that change the example's validity visible in the main lesson.

[vmmlite](https://github.com/boxlite-ai/vmmlite/blob/df298e821acac00195a1ba96fa1ae8a650edd280/README.md) illustrates the scope: boot Linux, print from PID 1 through a virtio console, and exit on guest reboot. Its platform-specific setup remains necessary; its documented learning-only limits remain part of the explanation. Source line count alone proves neither sufficiency nor safety.

### Check

- Run the documented entrypoint when the environment is available. Observe the defining behavior across its required boundaries and a meaningful failure/boundary case; helper output alone does not verify the system path.
- Check supported conditions, intermediate worked-example values, outputs, errors, and effects against source and completed code. Tests must exercise the extracted mechanism.
- Apply the removal test again: does every remaining component serve the chosen behavior or its necessary execution conditions?
- If execution is unavailable, name the missing prerequisite and documented run command, if known. Otherwise state that the entrypoint is unavailable. Label the artifact unverified; static inspection is not a successful run.
