# Contributing

## TL;DR

Use canonical skills and policies, register designs before code, validate affected contracts, and refresh repository tooling and host installations separately.

## Instruction ownership

[Architecture](ARCHITECTURE.md) maps entry points, state, and enforcement boundaries.

| Guidance | Owner |
| --- | --- |
| Research/design | [boxlite-design-doc](.agents/skills/boxlite-design-doc/SKILL.md); [issue template](../../.github/ISSUE_TEMPLATE/design.md) |
| Design review | [Criteria](.agents/prompts/audit/design-criteria.md), [outline](.agents/prompts/audit/design-outline.md), [auditor](.claude/agents/design-auditor.md) |
| Design advice/privacy | [Advice task](.agents/prompts/audit/design-advice-task.md), [advisor](.claude/agents/design-advisor.md), [probe privacy](.agents/prompts/audit/probe-privacy.md) |
| Size, stacks, docs, disclosure, verification | [Shared workflow](guidance/workflow.md#workflow) |
| Coding/review | [boxlite-clean-code](.agents/skills/boxlite-clean-code/SKILL.md), [google-code-review](.agents/skills/google-code-review/SKILL.md) |
| Writing/PR preparation | [boxlite-writing](.agents/skills/boxlite-writing/SKILL.md), [boxlite-pr-preparation](.agents/skills/boxlite-pr-preparation/SKILL.md) |
| PR outline/checking/review | [Template](../../.github/PULL_REQUEST_TEMPLATE.md), [checker](.agents/lib/pr-description.sh), [review question](.agents/prompts/pr/pr-review-question.md) |

Reference skills by name; keep paths in link targets/tests/diagnostics, task requirements with their owners, and regenerate consumer instructions instead of copying rules.

## Validation

Run from the repository root, plus affected suites:

```sh
make test:writing test:parity test:architecture
make test:plugin TEST_FILTER=<name>
```

API changes also require `make test:api-compatibility test:api-lint` with oasdiff 1.33.0 or `OASDIFF_BIN`.

Test affected Claude/Codex and OS combinations; report unverified coverage; Copilot installs remain unverified.

### Auditor test isolation

- Use utility-only fixture PATH and explicit auditor stubs; add utilities individually, never restore host PATH.
- Integration cases provide fake CLIs; absent-runner cases omit them; unavailable `CODEX_BIN` disables desktop discovery, and sentinels catch unintended model calls.
- Select each newly created receipt by invocation; keep selection state ignored, because timestamp/PID sorting can choose old receipts or tracked helpers alter bindings.
- Wait for `watch_start` before TERM; preserve FIFO's two-second replacement bound and give the next audit its own deadline/published-finding assertion.
- Render complete composed prompts within budgets; run `subagent.test.sh` and `claude-timed-prompts.test.sh` when changing shared prompt composition.

### Commit/push retry choices

After three FAIL/ERROR rounds, choose **Reflect again (Recommended)** or **Stop**; five-minute silence selects reflection, never approval.

- Retain history, submit current reflection, fix/test, then obtain a fresh audit; further failures ask again within eight-failure/sixteen-attempt/storage limits.
- Use the managed question or standalone `commit-audit-decision: <request-id> <Reflect again|Stop>`; push uses `push-audit-decision:`.
- Stale/mixed answers follow ordinary cancellation; Stop keeps Git blocked; later explicit task instructions start a new prompt context.

## Release maintenance

| Change | Required action |
| --- | --- |
| Release | Bump generic/Claude/Codex manifests and both version fields in Claude/Copilot marketplaces; Codex marketplace follows `main`. |
| Auditor task/dossier format | Bump version so stale sessions request reload instead of receiving incompatible tasks. |
| Host packaging | Run parity, including symlink-free copies; install/reinstall using real CLI in empty isolated Codex home, checking fresh `skills/list` and `hooks/list`. |
| Consumer adoption | Run `.agent-tooling/install.sh`, refresh host plugin, then reload/start a new task. |
| Verification | Separately check recorded revision, worktree hook path, managed guidance, and installed version; preserve holds/unrelated edits. |

Use [one-time migration instructions](../../README.md#migrate-existing-consumers-once) for adopted-package loaders; installers never rewrite tracked loaders.

| Older installation | Migration caution |
| --- | --- |
| 0.1.29–0.1.34 | Refresh both runtime/plugin for size, API, research, summary, skill discovery, and declared-host routing. |
| Code begun under 0.1.30 | Attempt an editor edit before next commit/push to trigger missing design review; merged work remains accepted risk. |
| Before 0.1.35 | Migrate all three consumer loaders once; preserve customizations/held releases. |
| Markerless Git wiring | Retain launcher/PID contract; see [Git gates](ARCHITECTURE.md#git-gates). |
| Earlier design verdicts | Legacy record/`research` alias remain readable; PASS now needs fresh advice; refresh/reload, including displayed async cards. |
| Review/retry updates | Refresh whole plugin and start a new session so prompts, Git gates, and callbacks agree. |

Check Claude installation by exact `projectPath`; updating one linked worktree can leave another stale.

Transcript discovery and runner contracts: [audit configuration](.agents/hooks/audit/README.md), [proof/routing](ARCHITECTURE.md#audit-producers), [review criteria](ARCHITECTURE.md#commitpush-review-criteria).

`full-transcript` fixtures prove handoff/access, not live model behavior; verify native hosts/platforms separately after adoption.

## Commit & PR messages

### Commit messages

Use Conventional Commit subjects ≤72 characters; bodies explain problem, solution, and rejected alternatives, since squash merges retain commits and discard PR bodies.

### Pull request size

Apply [size/decomposition policy](guidance/workflow.md#pr-size-and-decomposition) and [tracking template](.agents/prompts/pr/split-pr-tracking-issue.md); [architecture](ARCHITECTURE.md#pr-size-and-stacks) defines hook coverage.

Example: 612 code additions ask **Bypass limit** or **Split PR**; bypass binds that diff without requiring justification.

For managed native questions and auditor cards in local Claude:

```sh
bash plugins/boxlite-agent-tooling/scripts/claude-with-timed-prompts.sh
```

This disables Remote Control for the session; [timed confirmations](ARCHITECTURE.md#timed-confirmations) defines modes, fallback, expiry, and renewal.

### Pull request descriptions

1. Apply `boxlite-design-doc`; use the design issue template, keeping its outline aligned with the skill, including `Problem` before `Scope`.
2. Register before code; `bind` remains an alias:

   ```sh
   bash <plugin-root>/scripts/design-doc.sh register <URL>
   ```

3. Follow the gate's auditor route, then advisor route; show advice to the human, who selects what to adopt.
4. Read/apply `boxlite-pr-preparation` for drafts/revisions; include the registered full URL and substantive project-documentation link.
5. Prepare generated text, then pass safely quoted literal inline bodies; backticks in double quotes execute shell substitutions.

| Design operation | Contract |
| --- | --- |
| Audit | `design-doc.sh verdict`, default 900 seconds; only critical/high gaps FAIL; content edits need fresh review. |
| Advice | `design-doc.sh advice`; advice never changes verdict. |
| Repeated FAIL | Submit `design-doc.sh reflect` or answer first-line `design-decision: <Redesign|Reflect again|Overrule> <reason>`. |
| Codex question | Exact async payload/request-ID title; matching late answers count, silence blocks, changed design/history needs new request. |
| Provider auth | GitHub `gh`; Notion `NOTION_TOKEN`; Linear `LINEAR_API_KEY`; environment only. |
| Binding/content | Re-register after branch changes; Notion text must use top-level blocks. |

See [design/description validation](ARCHITECTURE.md#design-documents) and [accepted GitHub inputs](ARCHITECTURE.md#github-writing); old uncorrelated cards require fresh questions or typed directives.

### Examples for review

Choose the smallest useful example from the [illustration table](.agents/skills/boxlite-pr-preparation/SKILL.md#2-choose-the-smallest-useful-illustration).

### Author review acknowledgment

1. Read the current diff; post a new, unedited `/reviewed <full-head-SHA>` comment as the PR author, using the bot's SHA.
2. Wait for **Author reviewed the PR**, then mark **Ready for review**.
3. After a push or editing/deleting the sole acknowledgment, repeat; CI returns the PR to draft.

Forks follow the same flow; body edits retain SHA acknowledgment; description quality and maintainer approval remain separate.

Local `reviewed:` acknowledgment uses the distinct [timed-confirmation flow](ARCHITECTURE.md#timed-confirmations).

### Example PR description

Hypothetical behavior/results:

````markdown
## TL;DR

Run fewer SDK jobs per PR while retaining the full matrix weekly.

Design doc: https://github.com/example/repo/issues/123

Documentation: [SDK matrix](docs/ci.md#sdk-matrix).

## How it works

`pull_request` selects 11 jobs instead of 21; weekly/manual runs retain every supported version.

Source: [matrix selection](.github/workflows/sdk-ci.yml).

## Verification

`make test:apps:infra` passed; hosted timing remains unmeasured.
````
