## TL;DR

OpenAPI changes need explicit user confirmation to skip breaking/default-change enforcement, and SDK request tests for new optional fields.

## Scope

- Check every repository file whose basename contains `openapi` and ends in `.yaml` (case-sensitive), at any depth: e.g. `openapi.yaml` and `api/service.openapi.yaml`. Directory-only matches, `.yml`, and ignored untracked files are excluded.
- Compare each file with the PR's merge base. Commit checks read the working copy; push checks read the outgoing commit. Unchanged specifications skip it; complete contract additions/deletions require manual review.
- It needs no consumer configuration. Runtime version negotiation is out of scope.

## Required decisions

| Change | Gate |
| --- | --- |
| oasdiff breaking finding, including warnings | Explain the impact, recommend GitHub issue discussion, and ask whether the user confirms skipping this gate |
| Existing default added, changed, or removed | Same as breaking, including informational findings |
| New optional request field | The commit/push auditor verifies SDK request tests (below) |

The checker uses pinned oasdiff 1.33.0 and its JSON parser. Inherited oasdiff configuration and external references are disabled.

## Request tests

Run `bash "<plugin>/scripts/api-compatibility.sh" inspect <repo-root>` for commits; use `inspect-push` for pushes to read the checked-out commit. For every entry in `specifications`, read its `path` and `artifacts`: native `changelog`, `breaking`, and `diff` JSON reports, plus exact `before` and `after` snapshots. Use bounded reads within the auditor's evidence budget; missing, truncated, or unresolved evidence blocks PASS.

Use native findings and the detailed diff to locate changes; verify request relevance, defaults, and nullability against the snapshots and SDK code. Include parameter `content` schemas, references, composed schemas, and ancestor `readOnly` context. Native classifications can overreport request additions beneath a read-only parent. Response-only fields do not require request tests; shared writable fields need coverage for each affected operation. Python does not infer request-test obligations.

For each new optional request field, the auditor requires repository tests that exercise production request code and assert:

| Input | Required request |
| --- | --- |
| Omitted | Same as before the change: the field is absent |
| Explicit default, when the field has one | Same as omitted |
| Null, when nullable | Omitted only when the contract says so; otherwise null is sent |
| Non-default | The value appears in the affected operation's request |

Test the consumer's production request layer against a local HTTP server. Compare method, path, query, meaningful headers, and body; preserve missing/null/false/zero. Handcrafted request literals or a printed PASS are not evidence.

A missed request field, missing case, or test without a passing `make test...` receipt for the audited tree is a blocking finding. Server-only changes still need the request tests if the shared client changed.

## Human confirmation

Tell the user which files contain breaking or existing-default changes and explain their impact. Recommend discussing them in a GitHub issue. Ask whether to discuss or skip the compatibility gate; wait for the user's explicit choice. Discussion is recommended, not required; no issue/link or Notion token is required. Creating an issue needs separate authorization.

To confirm skipping, the user submits exactly:

```text
api compatibility: skip
```

Other phrasings do not confirm skipping. The hook checks the user event and text, not the user's identity. Never infer confirmation from silence or general implementation instructions.

The UserPromptSubmit hook binds confirmation to all changed paths and their before/after specifications at submission. Physical CRLF and LF are equivalent; other byte changes or a different changed-file set require confirmation again. Unrelated files and pending local edits do not invalidate approval of an unchanged outgoing commit.

A URL, assistant-generated confirmation, or model PASS cannot approve skipping. Never manufacture a record. Confirmation skips only breaking/default-change enforcement; parsing/tool failures and SDK request-test requirements still block.

Commit and push checks run before accepting auditor PASS or override; Stop does not check, so the reply can show the change for confirmation. These are local workflow checks; writable local state is not a security boundary.

Commands: [API compatibility check](../scripts/api-compatibility.md).
