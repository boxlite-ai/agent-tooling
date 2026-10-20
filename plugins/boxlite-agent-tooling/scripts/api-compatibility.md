## TL;DR

Classify `openapi/box.openapi.yaml` changes with oasdiff and gate commit/push on maintainer confirmation; no consumer configuration is needed.

## Setup

Install Python 3.9+ and [oasdiff 1.33.0](https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0). The checker uses the Python standard library. Set `OASDIFF_BIN` when the pinned binary is outside PATH. Recording a confirmation needs `NOTION_TOKEN`.

## Commands

`api-compatibility.sh inspect [repo-root] [base-ref]` prints the report: oasdiff changes, breaking findings, default changes, request-test `obligations`, and errors. `check` exits nonzero on errors without printing the report.

The base is the merge base with `origin/main`, then `main`; a third argument overrides it. Only the specification is read, so submodules, symlinks, and build outputs elsewhere in the repository do not matter.

Commit requires the reviewed specification to be staged; push requires it to be committed. The push hook checks API refs before reusing a commit audit receipt; changed API refs must be checked out and fast-forward updates.

## Approval

Follow [human confirmation](../guidance/api-compatibility.md#human-confirmation). The Notion page must follow the existing design-document format. Approvals live in the worktree Git directory and bind the specification at submission. Do not invoke `record` to manufacture a user event.

Request-test obligations are checked by the commit/push auditor, not by this script; see [request tests](../guidance/api-compatibility.md#request-tests).
