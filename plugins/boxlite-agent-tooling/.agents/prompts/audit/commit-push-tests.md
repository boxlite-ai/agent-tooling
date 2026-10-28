---
name: commit-push-tests
used-by: .agents/prompts/audit/commit-push-criteria.md
description: Bind test evidence to complete executions and candidate source.
---

# Commit/push test evidence

Use host receipts, complete native records, or safe reruns; direct Bash suites count.
Verify command/subject bindings and the bound design before long checks. Inventory
available evidence; probe required sandbox capabilities before rerunning suites. On
permission denial, retrieve authentic records instead. Preserve lifecycle checks and
permissions. Missing proof remains an unchecked FAIL; a sandbox denial is not a test result.

## Bind the execution

Establish command, cwd, completion, exit status, output, and source state at execution.
Match the commit's captured index tree or the push's validated new commit trees.
Verify state before and after execution; today's index cannot certify an earlier run.
Summaries, logs, prior dossiers, and filenames alone are insufficient.

Read up to 50 newest host receipts in `test-runs/` beside the dossier: `command`, `status`,
`exit_code`, `head`, `tree`. Complete native records or reruns may establish the same facts.

## Retrieve native records

Use optional `parent_session_id`, `parent_host`, and `audit_started_at` hints. Apply
discovery, boundary, envelope, and execution-linkage rules from
`../../skills/boxlite-verdict-audit/references/transcripts.md`, relative to this file.
Verify parent/repository identity, link invocation/completion, and revalidate before
delivery. No transcript path is supplied. Missing context requires verified host linkage;
never substitute your session. Standalone reviews may use receipts or safe reruns.

## Verify both sides

Follow repository rules: isolated detached baseline, every production change removed,
regression tests retained. Observe defect assertions fail; restore the complete fix and
observe success. Bind both executions to source. Setup errors do not prove the bug.
