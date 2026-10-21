## TL;DR

Check every `*openapi*.yaml` contract with oasdiff; breaking/default changes need explicit user confirmation to skip commit/push enforcement.

## Setup

Install Python 3.9+ and [oasdiff 1.33.0](https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0). The checker uses the Python standard library. Set `OASDIFF_BIN` when the pinned binary is outside PATH. No consumer configuration or Notion token is needed.

## Commands

Match case-sensitive basenames containing `openapi` and ending in `.yaml`, at any depth. `openapi.yaml` and `api/service.openapi.yaml` match; `openapi/model.yaml`, `openapi.yml`, and `openapi.yaml.bak` do not. Ignore untracked files excluded by Git.

`api-compatibility.sh inspect [repo-root] [base-ref]` prints status, base commit, aggregate fingerprint, `requires_confirmation`, errors, and a `specifications` list. Each entry has its repository `path`, default changes, and an `artifacts` map of absolute paths:

| Artifact | Content |
| --- | --- |
| `before`, `after` | Exact compared specifications |
| `changelog`, `breaking` | Native oasdiff JSON findings |
| `diff` | Native detailed JSON diff; use the specifications for full schema context |

Each changed specification gets a fresh private `api-compatibility-report-*` directory inside the worktree Git directory. Files remain available after exit and later inspections; delete these directories when no longer needed. Native source names `before.yaml` and `after.yaml` refer to adjacent snapshots; the enclosing entry identifies the repository path. No request-test list is generated.

`check` exits nonzero on errors without printing or saving reports. Unchanged specifications skip the checker and print nothing. An inspection requiring human confirmation still exports evidence and exits nonzero; the evidence does not grant approval.

Use `inspect-push` with the same arguments to inspect the checked-out commit instead of local edits. `push` checks that commit without printing the report.

The base is the merge base with `origin/main`, then `main`; a third argument overrides it. Only matching specifications are read; unrelated files and submodules do not enter comparison. Complete contract additions/deletions require manual review.

Commit requires every reviewed specification to be staged. Push checks read the outgoing commit supplied by Git; direct `push` and `inspect-push` calls capture HEAD once. Neither the working copy nor the index controls push classification or approval matching.

Example: deleting an endpoint in a commit, then restoring and staging the original file without committing, still requires confirmation to push the deletion. The push hook checks API refs before reusing a commit audit receipt; changed API refs must be checked out and fast-forward updates.

## Approval

Follow [human confirmation](../guidance/api-compatibility.md#human-confirmation): show breaking/default changes, recommend GitHub issue discussion, and ask whether to skip. Only the exact user prompt `api compatibility: skip` records that choice. No discussion link is required; do not create an issue without permission.

Approvals live in the worktree Git directory and bind the sorted set of changed paths and their before/after content. Another changed contract invalidates confirmation. Do not invoke `record` to manufacture a user event. A skip leaves SDK request-test audit and checker failures enforced.

Changed-file selection and approval fingerprints normalize physical CRLF to LF. A confirmed CRLF working copy remains approved when Git stores LF, including with `core.autocrlf=true`; unchanged contracts with converted line endings stay outside the changed set. Other byte changes, including escaped `\r\n` versus `\n` in string values, still invalidate confirmation. Inspection snapshots retain their original bytes.

The commit/push auditor uses these files and SDK code to determine and verify request tests; see [request tests](../guidance/api-compatibility.md#request-tests).
