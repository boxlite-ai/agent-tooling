## TL;DR

Box API changes need human confirmation for breaking and existing-default changes, and SDK request tests for new optional fields.

## Scope

- The check reads only `openapi/box.openapi.yaml`: its copy at the PR's merge base and the working copy. Unchanged YAML skips it.
- It needs no consumer configuration. Runtime version negotiation is out of scope.

## Required decisions

| Change | Gate |
| --- | --- |
| oasdiff breaking finding, including warnings | Commit/push fail until a maintainer confirms with a readable Notion decision document |
| Existing default added, changed, or removed | Same as breaking, including informational findings |
| New optional request field | The commit/push auditor verifies SDK request tests (below) |

The checker uses pinned oasdiff 1.33.0 and its JSON parser. Inherited oasdiff configuration and external references are disabled. Shared schema additions expand to affected operations.

## Request tests

Run `bash "<plugin>/scripts/api-compatibility.sh" inspect <repo-root>`. Its `obligations` list each new optional field as `<METHOD> <path> <location>/<name>`, with its default and nullability. An `unclassified` entry is a blocking finding until the auditor identifies the new request fields by hand and verifies their tests.

For each obligation, the auditor requires repository tests that exercise production request code and assert:

| Input | Required request |
| --- | --- |
| Omitted | Same as before the change: the field is absent |
| Explicit default, when the field has one | Same as omitted |
| Null, when nullable | Omitted only when the contract says so; otherwise null is sent |
| Non-default | The value appears in the affected operation's request |

Test the shared request layer (for boxlite, the Rust REST client in `src/boxlite`) against a local HTTP server. Compare method, path, query, meaningful headers, and body; preserve missing/null/false/zero. Handcrafted request literals or a printed PASS are not evidence.

A missing obligation, missing case, or test without a passing `make test...` receipt for the staged tree is a blocking finding. Server-only changes still need the request tests if the shared client changed.

## Human confirmation

A maintainer reviews the change and the linked Notion decision document, then submits:

```text
maintainer confirmed: https://notion.so/<page-id>
```

The confirmation must be exactly `maintainer confirmed: <Notion URL>`; other phrasings do not approve the change. The hook checks only this text, not who typed it.

The UserPromptSubmit hook verifies the Notion document using `NOTION_TOKEN`, then records the confirmation bound to the specification as it stands at submission. Any later specification change invalidates it. A URL without the phrase, assistant-generated confirmation, or model PASS cannot approve the change. Never manufacture an approval record.

Commit and push checks run before accepting auditor PASS or override; Stop does not check, so the reply can show the change for confirmation. These are local workflow checks; writable local state is not a security boundary.

Commands: [API compatibility check](../scripts/api-compatibility.md).
