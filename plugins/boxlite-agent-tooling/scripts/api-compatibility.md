## TL;DR

Classify `openapi/box.openapi.yaml` changes with oasdiff and gate commit/push on maintainer confirmation; no consumer configuration is needed.

## Setup

Install Python 3.9+ and [oasdiff 1.33.0](https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0). The checker uses the Python standard library. Set `OASDIFF_BIN` when the pinned binary is outside PATH. Recording a confirmation needs `NOTION_TOKEN`.

## Commands

`api-compatibility.sh inspect [repo-root] [base-ref]` prints JSON with status, base commit, fingerprint, default changes, errors, and an `artifacts` map of absolute paths:

| Artifact | Content |
| --- | --- |
| `before`, `after` | Exact compared specifications |
| `changelog`, `breaking` | Native oasdiff JSON findings |
| `diff` | Native detailed JSON diff; use the specifications for full schema context |

Each inspection writes a fresh private `api-compatibility-report-*` directory inside the worktree Git directory. Files remain available after exit and later inspections; delete these directories when no longer needed. Native source names `before.yaml` and `after.yaml` refer to the adjacent snapshots. No request-test list is generated.

`check` exits nonzero on errors without printing or saving reports. Unchanged specifications skip the checker and print nothing. An inspection requiring human confirmation still exports evidence and exits nonzero; the evidence does not grant approval.

Use `inspect-push` with the same arguments to inspect the checked-out commit instead of local edits. `push` checks that commit without printing the report.

The base is the merge base with `origin/main`, then `main`; a third argument overrides it. Only the specification is read, so submodules, symlinks, and build outputs elsewhere in the repository do not matter.

Commit requires the reviewed specification to be staged. Push checks read the outgoing commit supplied by Git; direct `push` and `inspect-push` calls capture HEAD once. Neither the working copy nor the index controls push classification or approval matching.

Example: deleting an endpoint in a commit, then restoring and staging the original file without committing, still requires confirmation to push the deletion. The push hook checks API refs before reusing a commit audit receipt; changed API refs must be checked out and fast-forward updates.

## Approval

Follow [human confirmation](../guidance/api-compatibility.md#human-confirmation). The Notion page must follow the existing design-document format. Approvals live in the worktree Git directory and bind the specification at submission. Do not invoke `record` to manufacture a user event.

Approval fingerprints normalize physical CRLF line endings to LF. A confirmed CRLF working copy remains approved when Git stores LF, including with `core.autocrlf=true`. Other byte changes, including escaped `\r\n` versus `\n` in string values, still invalidate confirmation. Inspection snapshots retain their original bytes.

The commit/push auditor uses these files and SDK code to determine and verify request tests; see [request tests](../guidance/api-compatibility.md#request-tests).
