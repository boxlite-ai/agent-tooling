## TL;DR

Compare OpenAPI changes and their tracked references, with confirmation for breaking changes or existing defaults.

## API compatibility

`scripts/api-compatibility.sh` runs before commit and push verdicts, including overrides. Stop skips the check. The checker uses `.agents/lib/api_contract.py` to compare the selected snapshots.

The auditor traces optional request fields, parameter content, ancestor `readOnly`, and SDK code. Each writable operation needs tests. Response-only fields do not.

Python exports evidence without inferring request-test requirements. The plugin leaves consumer SDK builds to the consumer.

## Setup

Install Python 3.9+ and [oasdiff 1.33.0](https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0).

- The checker uses the Python standard library.
- Set `OASDIFF_BIN` when the pinned binary is outside PATH.
- No consumer configuration or Notion token is needed.

## Commands

Match case-sensitive basenames containing `openapi` and ending in `.yaml`, at any depth. `openapi.yaml` and `api/service.openapi.yaml` match; `openapi/model.yaml`, `openapi.yml`, and `openapi.yaml.bak` do not. Ignore untracked files excluded by Git.

Relative references resolve to matching tracked regular files in the same snapshot. The checker isolates the files read for each root before comparing them. Network references and unresolved targets fail the check.

Gitlinks stay outside contract comparison. A reference to a Git submodule fails resolution.

`api-compatibility.sh inspect [repo-root] [base-ref]` prints status, base commit, aggregate fingerprint, `requires_confirmation`, errors, and a `specifications` list. Each entry has its repository `path`, default changes, and an `artifacts` map of absolute paths:

| Artifact | Content |
| --- | --- |
| `before`, `after` | Exact compared specifications |
| `changelog`, `breaking` | Native oasdiff JSON findings |
| `diff` | Native detailed JSON diff; use the specifications for full schema context |
| `manifest` | For reference comparisons, the source labels and raw digests of the root and referenced artifacts |

Each changed specification gets a fresh private `api-compatibility-report-*` directory inside the worktree Git directory.

- Files remain available after exit and later inspections; delete these directories when no longer needed.
- Native source names refer to the artifact pair or the tree and path mapped in the manifest.
- No request-test list is generated.

`check` exits nonzero on errors without printing or saving reports. Unchanged specifications skip the checker and print nothing. An inspection requiring human confirmation still exports evidence and exits nonzero; the evidence does not grant approval.

Use `inspect-push` with the same arguments to inspect the checked-out commit instead of local edits. `push` checks that commit without printing the report.

The base is the merge base with `origin/main`, then `main`. An explicit base ref takes priority. Reads use local Git objects from the named snapshots.

Complete contract additions or deletions and changed schema-only roots require manual review. A staged deletion also blocks when the original file remains in the working directory. Unreadable snapshots fail discovery.

Commit requires every reviewed specification to be staged. Push checks read the outgoing commit supplied by Git; direct `push` and `inspect-push` calls capture HEAD once. Neither the working copy nor the index controls push classification or approval matching.

Example: deleting an endpoint in a commit, then restoring and staging the original file without committing, still requires confirmation to push the deletion. The push hook checks API refs before reusing a commit audit receipt; changed API refs must be checked out and fast-forward updates.

The headless runner prepares OpenAPI evidence under its private scratch directory. The evidence identifies the gate's resolved base and the staged tree or outgoing commit. A separately recorded report digest binds the exact bytes of all evidence files for the [request-test checks](../guidance/api-compatibility.md#request-tests).

Comparisons with tracked relative references reuse one discovery tree per side. Git Trace2 identifies each root's inputs for replay in its own restricted store. [Git Trace2 event format](https://git-scm.com/docs/api-trace2#_event_format)

Bound audit evidence reads immutable Git objects. Working-copy previews require the checkout paths to remain stable during the read.

Push evidence comes from ref-update headers in the validated Git context. Push classification ignores paths changed only as Git submodules. Transitions between a submodule and a regular contract still require whole-contract review.

## Approval

Follow [human confirmation](../guidance/api-compatibility.md#human-confirmation). Show the breaking or default changes and recommend GitHub issue discussion. Use the check's shared question once and continue without waiting.

Only the exact user prompt `api compatibility: skip` records that choice. Silence keeps the gate. Discussion links are optional and issue creation requires permission.

Approvals live in the worktree Git directory. They bind the before and after content of the changed roots and each resolved reference.

- Another changed contract invalidates confirmation.
- Do not invoke `record` to manufacture a user event.
- A skip leaves SDK request-test audit and checker failures enforced.

Changed-file selection and approval fingerprints normalize physical CRLF to LF.

- A confirmed CRLF working copy remains approved when Git stores LF, including with `core.autocrlf=true`; unchanged contracts with converted line endings stay outside the changed set.
- Other byte changes, including escaped `\r\n` versus `\n` in string values, still invalidate confirmation.
- Inspection snapshots retain their original bytes.

The commit/push auditor uses these files and SDK code to determine and verify request tests; see [request tests](../guidance/api-compatibility.md#request-tests).
