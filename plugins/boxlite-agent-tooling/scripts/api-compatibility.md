## TL;DR

Run SDK code from before and after an API change against a local HTTP recorder, then reuse the verified results in local audit gates.

## Setup

Install Python 3.9+ and [oasdiff 1.33.0](https://github.com/oasdiff/oasdiff/releases/tag/v1.33.0). The checker uses the Python standard library; no YAML package is needed. Set `OASDIFF_BIN` when the pinned binary is outside PATH.

Declare `.agent-tooling/api-compatibility.json` in the consumer:

```json
{
  "baseRef": "origin/main",
  "timeoutSeconds": 120,
  "sdks": [{
    "name": "python",
    "paths": ["sdks/python", "src/shared-serializer"],
    "command": ["python3", "tests/compatibility/invoke_sdk.py"]
  }],
  "features": {
    "POST /boxes body/enabled": {
      "nonDefault": true,
      "nullIsOmitted": true,
      "response": {"status": 200, "body": {"id": "test-box"}}
    }
  }
}
```

Use actual repository paths and response contracts; this example is illustrative. Map shared transport code to every affected SDK. Feature keys contain HTTP method, specification path, and `body/<JSON-pointer>`, `query/<name>`, or `header/<name>`.

Defaults and wire nullability come from the specification. `nullIsOmitted` is required when wire null is allowed. Also set it to `true` when the SDK accepts an empty value such as Python `None` as omission, even if the wire schema rejects null; this adds the empty-input case. `nonDefault` must differ from the declared default. For a server URL prefix, set `requestPath` to the concrete captured path, such as `/v1/test/boxes`.

## Adapter contract

The current adapter runs for both source versions, with these environment values:

| Variable | Meaning |
| --- | --- |
| `API_COMPAT_SDK_ROOT` | Isolated pre-change or current source tree; import/build the SDK from here |
| `API_COMPAT_URL` | Local recorder URL; use test credentials, never production endpoints |
| `API_COMPAT_INPUT` | JSON containing `operation`, `field`, `case`, and `value` except for omission |

Invoke the real SDK method. The pre-change SDK receives only the omitted case; the current SDK receives every generated case. Ignored build outputs and Git metadata are not copied. Resolve dependencies and build metadata from each source revision and key build caches by revision. The adapter must exit successfully and emit actual HTTP traffic; it does not produce its own PASS report.

The runner compares the whole request sequence for default/omission cases and checks the affected operation's field for non-default/null cases. JSON requests and scalar query/header parameters are supported; chunked bodies, external references, and unsupported schema additions fail closed. Snapshots recreate in-repository symlinks as links; absolute or repository-escaping targets, a symlinked specification or configuration, and submodules fail closed.

## Commands

Add a consumer Make target, with the plugin path supplied by its installation:

```make
test\:api-compatibility:
	bash "$(PLUGIN_ROOT)/scripts/api-compatibility.sh" test "$(CURDIR)"
```

Run `make test:api-compatibility`. The runner uses the merge-base with `baseRef`, defaulting to `origin/main`, then `main`. An explicit third script argument overrides the comparison ref.

`api-compatibility.sh inspect` prints findings and required cases; `check` validates evidence without rerunning SDKs. Receipts and approval records live in the worktree Git directory. Source, permission, configuration, rule, or base changes invalidate them. A new test run invalidates its previous receipt before executing.

Stage all reviewed sources before committing, then commit them before pushing. The push hook checks API refs before reusing a commit audit receipt; changed API refs must be checked out and fast-forward updates. It retains the configured PR comparison base, so an incremental push does not redefine the compatibility contract.

SDK and Server work may ship separately; unchanged SDK mappings yield no SDK request obligations for a Server-only PR. This proves the executed request cases, not runtime compatibility against every historical Server.

## Approval

Follow [human confirmation](../guidance/api-compatibility.md#human-confirmation). The Notion page must follow the existing design-document format. Notion access is needed only when recording an exception, and its credentials stay in the environment. Do not invoke `record` to manufacture a user event.

The same confirmation covers breaking and existing-default changes. Version-negotiation errors remain separate implementation steps.
