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

Plugin suites and fixtures live under [`tests/`](tests/) by subsystem. Bootstrap suites and fixtures live under [`tests/bootstrap/`](../../tests/bootstrap/).

- `make test:plugin` discovers shell suites under the plugin test directory.
- `make test:bootstrap` runs the installer and both host bootstrap suites. Run [prompt rules](../../tests/bootstrap/prompt-rules.test.sh) separately.
- `TEST_FILTER` matches substrings of current and previous suite paths. For example, `TEST_FILTER=tests/` selects every shell suite in the chosen Make target.
- Run each Python skill suite with `python3 -m unittest discover -s plugins/boxlite-agent-tooling/tests/skills/<skill>`.

API changes also require `make test:api-compatibility test:api-lint` with oasdiff 1.33.0 or `OASDIFF_BIN`.

Test affected Claude/Codex and OS combinations; report unverified coverage; Copilot installs remain unverified.

On macOS, set `BOXLITE_FOLLOWUP_SDK` and `BOXLITE_FOLLOWUP_CLAUDE` to the absolute SDK and Claude paths before running `make test:plugin TEST_FILTER=followups`. The native fixture uses a loopback model endpoint and simulated GitHub responses.

For releases and upgrades, see [release maintenance](scripts/README.md#release-maintenance). For test setup, see [auditor test isolation](.agents/hooks/audit/README.md#auditor-test-isolation).

## Commit & PR messages

### Commit messages

Use Conventional Commit subjects ≤72 characters; bodies explain problem, solution, and rejected alternatives, since squash merges retain commits and discard PR bodies.

### Pull request size

Apply [size/decomposition policy](guidance/workflow.md#pr-size-and-decomposition) and [tracking template](.agents/prompts/pr/split-pr-tracking-issue.md); [architecture](docs/design-and-pr-gates.md#pr-size-and-stacks) defines hook coverage.

### Pull request descriptions

1. Apply `boxlite-design-doc`; use the design issue template, keeping its outline aligned with the skill, including `Problem` before `Scope`.
2. Register and store the research log before code; `bind` remains an alias:

   ```sh
   bash <plugin-root>/scripts/design-doc.sh register <URL>
   bash <plugin-root>/scripts/design-doc.sh log < research-log.md
   ```

   The design is for human reviewers; the log stays in the clone, bound to the audit, and is never published ([#388](https://github.com/boxlite-ai/agent-tooling/issues/388)). An empty log deletes it; any log change needs a new audit.

3. Follow the gate's auditor route, then advisor route; show advice to the human, who selects what to adopt.
4. Read/apply `boxlite-pr-preparation` for drafts/revisions; include the registered full URL and substantive project-documentation link.
5. Pass safely quoted inline text or use the [guarded PR body-file launcher](docs/design-and-pr-gates.md#pr-body-files).

See [design operations](docs/design-and-pr-gates.md#design-operations), [accepted GitHub inputs](docs/writing-checks.md#github-writing), and [timed confirmations](docs/timed-confirmations.md#timed-confirmations).

### Author review acknowledgment

1. Read the current diff; post a new, unedited `/reviewed <full-head-SHA>` comment as the PR author, using the bot's SHA.
2. Wait for **Author reviewed the PR**, then mark **Ready for review**.
3. After a push or editing/deleting the sole acknowledgment, repeat; CI returns the PR to draft.

Forks follow the same flow; body edits retain SHA acknowledgment; description quality and maintainer approval remain separate.

Local `reviewed:` acknowledgment uses the distinct [timed-confirmation flow](docs/timed-confirmations.md#timed-confirmations).

### Example PR description

Choose the smallest useful illustration. The example below is hypothetical. [Illustration table](.agents/skills/boxlite-pr-preparation/SKILL.md#2-choose-the-smallest-useful-illustration)

````markdown
## TL;DR

Run fewer SDK jobs per PR while retaining the full matrix weekly.

- Design doc: https://github.com/example/repo/issues/123
- Documentation: [SDK matrix](docs/ci.md#sdk-matrix).

## How it works

`pull_request` selects 11 jobs instead of 21; weekly/manual runs retain every supported version.

Source: [matrix selection](.github/workflows/sdk-ci.yml).

## Verification

`make test:apps:infra` passed; hosted timing remains unmeasured.
````
