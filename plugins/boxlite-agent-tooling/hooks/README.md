## TL;DR

These manifests connect Claude Code and Codex lifecycle events to the shared hook scripts.

## Manifests

| File | Loaded by | Host marker | Host differences |
| --- | --- | --- | --- |
| [hooks.json](hooks.json) | Claude Code convention | `claude` | Uses `asyncRewake`; adds `StopFailure` and `PostToolUseFailure`; loads the prompt-origin module. |
| [codex-hooks.json](codex-hooks.json) | Codex plugin manifest | `codex` | Uses `async`; omits Claude-only events. |
| [generic-hooks.json](generic-hooks.json) | Generic `plugin.json` | `unknown` | Same events as Codex. |
| [claude-prompt-origin.mjs](claude-prompt-origin.mjs) | `modules` in `hooks.json` | — | Marks a host background-command notification as verified for `UserPromptSubmit` hooks. |

Every command exports `BOXLITE_HOOK_HOST`, the only host signal hooks read; without it the host is `unknown`.
Claude commands resolve the plugin directory through `${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT}}`, the others through `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}`.
Implementations live in [`.agents/hooks/`](../.agents/hooks/README.md);
[Git hooks](../.githooks/README.md) are installed separately.

## How it works

Active auditors' exact task-bound report writes bypass the design check; their deadline and lifecycle hooks still run.

The deadline Start callback publishes ownership synchronously through `auditor-control.sh publish-start`.
The asynchronous `monitor-start` callback monitors that record and cannot reopen it after Stop.

Other editor or patch calls targeting repository files follow this path:

```mermaid
flowchart LR
    edit["Repository edit"]
    route["Match PreToolUse<br/>in the host manifest"]
    gate["preflight-design-doc.sh"]
    valid{"Readable design<br/>bound to this branch?"}
    allow["Continue edit"]
    deny["Block with registration steps"]
    edit dispatch@-->|"Tool call"| route
    route invoke@-->|"JSON on stdin"| gate
    gate check@-->|"Check binding"| valid
    valid accept@-->|"Yes"| allow
    valid reject@-->|"No"| deny
```

The host resolves the plugin root and interprets the hook's result. Shell hooks
inspect their own command text, because a `Bash` matcher alone does not
distinguish `git commit` from an unrelated command.

## Event routing

| Event / matcher | Scripts in manifest order |
| --- | --- |
| `UserPromptSubmit` | [cancel-verdict-audit.sh](../.agents/hooks/cancel-verdict-audit.sh) |
| `SubagentStart`, `SubagentStop` | [auditor-control.sh](../.agents/hooks/auditor-control.sh) |
| `SubagentStart`, `SubagentStop`; `PreToolUse` / `Read`, `Bash`, `Write`, `WebFetch`, `WebSearch`, `apply_patch`, `TaskStop` | [audit-deadline.sh](../.agents/hooks/audit-deadline.sh): the design and commit/push auditors’ and the design advisor’s deadline |
| `PreToolUse` / `Read`, `Bash`, `Write`, `WebFetch`, `WebSearch`, `apply_patch`, `TaskStop` | [audit-privacy.sh](../.agents/hooks/audit-privacy.sh): no personal identifiers or key requests in design auditor and advisor probes |
| `PreToolUse` / editor or patch tools | [preflight-design-doc.sh](../.agents/hooks/preflight-design-doc.sh) |
| `PreToolUse` / `Bash` | [preflight-commit-push.sh](../.agents/hooks/preflight-commit-push.sh), [preflight-pr-review.sh](../.agents/hooks/preflight-pr-review.sh) |
| `PostToolUse` / `Bash` | [post-remote-write-watch.sh](../.agents/hooks/post-remote-write-watch.sh), [record-test-run.sh](../.agents/hooks/record-test-run.sh) |
| `PostToolUseFailure` / `Bash` (Claude) | [record-test-run.sh](../.agents/hooks/record-test-run.sh) |
| `Stop` | [stop-gate.sh](../.agents/hooks/stop-gate.sh) |
| `StopFailure` (Claude) | [record-api-failure.sh](../.agents/hooks/record-api-failure.sh), [resume-after-api-failure.sh](../.agents/hooks/resume-after-api-failure.sh) |

Tool matchers select tool names; the scripts inspect commands themselves.
For example, a `Bash` call running `git commit` reaches the commit gate,
while an unrelated shell command passes through.

[rule-recency.sh](../.agents/hooks/rule-recency.sh) is opt-in through the consumer
templates; neither plugin manifest wires it. Audit runners are called by gates
or shell callers, rather than registered as lifecycle hooks.

## Validation

Run from the repository root after changing either manifest:

```sh
bash plugins/boxlite-agent-tooling/tests/host-parity.test.sh
bash plugins/boxlite-agent-tooling/tests/architecture.test.sh
```

Parity checks cover event support, command paths, host differences, and plugin
registrations. They do not prove installation or live event delivery on a host.
