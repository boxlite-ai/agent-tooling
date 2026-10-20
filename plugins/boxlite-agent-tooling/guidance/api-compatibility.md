## TL;DR

Box API changes require deterministic compatibility checks; breaking and existing-default changes need human confirmation linked to Notion.

## Scope and ownership

- Phase 1 triggers only for `openapi/box.openapi.yaml` changes against the PR's starting revision. Unchanged YAML does not trigger behavioral auditing.
- The shared checker lives in agent-tooling. Consumers supply SDK source mappings, invocation adapters, feature values, and stub responses.
- Select tests from the current PR's changed SDK paths; Server-only changes do not require an SDK implementation in the same PR. Runtime version negotiation is out of scope.

## Required decisions

| Change | Gate |
| --- | --- |
| oasdiff breaking finding, including warnings | Fail until explicit human confirmation links a readable Notion decision document for the current change |
| Existing default added, changed, or removed | Same as breaking, including informational findings |
| New optional request field in a changed SDK | Require local pre-change/current SDK request comparisons |
| Unsupported shape or missing mapping | Fail with the missing classification; never treat it as no change |

The checker uses pinned oasdiff 1.33.0 and its JSON parser. Inherited oasdiff configuration and external references are disabled. Shared schema additions expand to affected operations.

## Request evidence

| Input | Required behavior |
| --- | --- |
| Omitted | Same request as pre-change SDK |
| Explicit default, when declared | Same request as pre-change SDK |
| Null/empty SDK input, when allowed | Equivalent to omission only when the contract says so; otherwise transmit null |
| Non-default | Requested value appears in the affected operation's actual request |

The runner captures HTTP requests itself. Compare method, path/query, meaningful headers, and body; ignore only transport host, content-length, and connection headers. Preserve missing/null/false/zero and duplicate headers. JSON key ordering is insignificant.

Adapters must load production SDK code from the supplied source snapshot and use that revision's dependencies. Handcrafted requests, an installed current SDK used for both revisions, or a printed PASS are not evidence. Auditors verify these boundaries, source mappings, sample validity, and SDK input semantics. An SDK may accept `None` as omission even when the wire schema rejects null; declare `nullIsOmitted: true` to test that input.

Required cases are generated independently of test names. Missing, skipped, failing, stale, or zero-request results block. Source/configuration/tooling changes invalidate evidence. No permanent request baselines or deployed business Server are required.

## Human confirmation

A maintainer reviews the exact change and the linked Notion decision document, then submits:

```text
maintainer confirmed: https://notion.so/<page-id>
```

The digest is optional. Without it, the confirmation approves the change as it stands at submission. With `maintainer confirmed: <displayed-digest> <URL>`, a digest that no longer matches is rejected.

The confirmation must start with exactly `maintainer confirmed:`; other phrasings do not approve the change. The hook checks only this text, not who typed it.

The UserPromptSubmit hook verifies the Notion document using `NOTION_TOKEN`, then records confirmation bound to the current digest. Any later source change invalidates it. A URL without the phrase, assistant-generated confirmation, or model PASS cannot approve the change. Never manufacture an approval record.

Commit and push checks run before accepting auditor PASS or override; Stop does not check, so the reply can show the change for confirmation. These are local workflow checks; writable local state is not a security boundary.

Consumer setup and commands: [local compatibility testing](../scripts/api-compatibility.md).
