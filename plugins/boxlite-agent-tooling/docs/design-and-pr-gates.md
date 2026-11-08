# Design and PR gates

## TL;DR

Design and publication gates check edit authority, pull request descriptions and size, and author review.

For contributor steps, see [design registration](../CONTRIBUTING.md#pull-request-descriptions). Paths in code spans are relative to the plugin root.

## Design documents

Policy: `boxlite-design-doc`; commands: [Contributing](../CONTRIBUTING.md#pull-request-descriptions); outline: [design issue template](../../../.github/ISSUE_TEMPLATE/design.md).

`scripts/design-doc.sh` delegates provider reads and binding to `.agents/lib/design-doc.sh`.

| Record in worktree Git directory | Binding / validation |
| --- | --- |
| `agent-tooling-design-doc.json` | Canonical root, branch/detached HEAD, readable nonempty provider content, leading TL;DR under 40 words. |
| `agent-tooling-design-audit.json` | Root, branch, URL, live-content SHA-256, PASS or human overrule. |
| `agent-tooling-design-advice.json` | Fresh advice bound to the FAIL attempt or PASSed content; overrules need none. |
| `agent-tooling-design-audit-task.json` | Fixed deadline per design content; `DESIGN_AUDITOR_TIMEOUT`, default 900 seconds. |
| `agent-tooling-design-advice-task.json` | Advisor deadline using the same timeout. |

`register`/`bind` share validation; `verdict`/`research` share recording, and legacy `agent-tooling-design-research.json` remains readable until replacement.

- `.agents/lib/verdict-audit-state.sh` supplies safe reads/replacement; failed reads retain no success cache.
- Notion child blocks fail closed; native block structure prevents literal text forging headings; design length has no total-word cap.
- Missing/stale authority names the auditor route; fresh PASS also waits for advice; changed content requires review again.
- The auditor reads through `show`, then records one live `{content_sha256, verdict, findings, advisories}` object.
- Critical/high gaps FAIL; low/nit gaps remain advisory; every round checks the complete design skill and outline.

The research log stays out of the design, which is for human reviewers ([design #388](https://github.com/boxlite-ai/agent-tooling/issues/388)):

| Part | Behavior |
| --- | --- |
| Store | `design-doc.sh log` stores stdin (≤32,000 characters) as `{id, log}` in `agent-tooling-design-log/<sha256 of design ID>.json` under the clone's common directory (Git 2.31+). Normalized IDs (GitHub `owner/repo#N` lowercase, Linear uppercase, Notion lowercase without dashes) let URL spellings, worktrees, and re-registration share one log; removing a worktree keeps it. |
| Write | Empty input tombstones the log; records are replaced atomically, never removed, and read only as bounded regular files; a failed write keeps the stored log. |
| Hash | With no log ever stored, the bound SHA-256 is the provider body's; otherwise it hashes `agent-tooling-design-log-v1`, the body hash, and the log hash, one per line, so any log change needs a new audit in every bound worktree. |
| Show | `design-doc.sh show` appends `## Research log (local)`, the log's `sha256:` line, and the log; advice anchors resolve against that text. The log is never published; deleting the clone loses it. |
| Template | The design and [issue template](../../../.github/ISSUE_TEMPLATE/design.md) stay tool-free; the skill and audit prompts own the research protocol. |

### Audit rule ownership

Specs own input/output; `design-criteria.md` owns steps/entry format (2048-byte cap); `design-outline.md` owns whole-design checks; tasks own deadlines and untrusted-record framing.

How it works must open with a one-line overview and a concrete example before the mechanism ([design #418](https://github.com/boxlite-ai/agent-tooling/issues/418)). No overview, or no example before the mechanism, is high; other readability gaps, such as an undefined project-specific term, are low; mechanism and trade-off gaps keep their usual severity.

Related work must open with a best-practice line, sourced or “none established” with evidence, then group cited approaches in one table with the design’s pick row marked Pick, and list failures, constraints and counterevidence under Lessons ([design #424](https://github.com/boxlite-ai/agent-tooling/issues/424)). A missing line or approach grouping is high.

`probe-privacy.md` repeats deliberately in both specs; privacy hooks detect addresses/key requests, with address-only WebSearch checks.

Expansion, encoding, file-backed payloads, and Codex-hosted WebSearch bypass the heuristic; [probe policy](../.agents/prompts/audit/probe-privacy.md) remains mandatory.

### Design advice

Each live PASS/FAIL needs fresh advice after required stop/reflection handling: ≤5 single-line items, ≤500 characters each, `Why:` evidence before `Try:`.

Reject severity labels/unresolved local anchors; outside evidence remains unchecked; advice never mutates verdicts or enters `prior_findings`.

### Design audit loop

`.agents/lib/design-audit.jq` counts FAILs per root/branch across rebinding; PASS, overrule, or redesign resets the count.

| Condition / choice | Result |
| --- | --- |
| Edited content, same URL | Carry last FAIL's findings into the next task. |
| Converging second FAIL | Require reflection matching `.agents/lib/audit-reflection-contract.jq`. |
| Repeated/non-reducing second FAIL, third FAIL, or FAIL after reflection choice | Stop as INCOMPLETE and ask for a human decision. |
| Redesign | Reset count; failed content cannot be audited again. |
| Reflect again | Require reflection, then permit one more audit. |
| Overrule | Record `OVERRIDDEN`; retained `overruled:` findings are not re-raised. |
| No answer after five minutes | Keep edits blocked. |

Only managed question hooks, correlated Codex replies, or a human's first-line `design-decision: <choice> <reason>` record decisions.

Neither design agent has a force-pass card; they gate edits, not turn completion or commits.

### Design conformance

Commit/push criteria compare the diff with authenticated `design-doc.sh show` output; they do not repeat design auditing.

- Linear/Notion reads need no browser login; `show [repo-root]` supports writable scratch with authoritative target binding.
- Substantive project documentation remains required for every PR; reviewers assess quality, and the design gate does not inspect documentation diffs.

### Editor scope

`.agents/lib/edit-scope.sh` exempts only targets outside every worktree/Git directory at both named and symlink-resolved locations.

- A directory without `.git` counts as outside; relative cwd, `~`, dot segments, dangling links, or unparseable targets retain the gate.
- Shell commands, other clients, and arbitrary MCP writers remain outside this hook; workflow design requirements still apply.
- Shell execution retains host permissions and independent Git/PR checks; no research-command allowlist applies.

#### Auditor report writes

The design gate allows a native commit/push or verdict auditor to save its assigned report through `Write` or a single-file add/update patch. [Design #406](https://github.com/boxlite-ai/agent-tooling/issues/406)

- `.agents/lib/audit-report-scope.sh` checks the repository, session, worker, open attempt, and current prompt epoch or verdict request before allowing the exact report path.
- Aliases, links, special files, other reports, and unrelated agents still require design authority, as do deletes, moves, and mixed patches.
- The synchronous deadline Start publishes ownership through `auditor-control.sh publish-start`; asynchronous `monitor-start` only observes that ownership.
- The deadline still ends investigation, and Stop validates and records the report as PASS, FAIL, or an execution error.

### Design operations

| Design operation | Contract |
| --- | --- |
| Audit | `design-doc.sh verdict`, default 900 seconds; only critical/high gaps FAIL; content edits need fresh review. |
| Advice | `design-doc.sh advice`; advice never changes verdict. |
| Repeated FAIL | Submit `design-doc.sh reflect` or answer first-line `design-decision: <Redesign\|Reflect again\|Overrule> <reason>`. |
| Codex question | Exact async payload/request-ID title; matching late answers count, silence blocks, changed design/history needs new request. |
| Provider auth | GitHub `gh`; Notion `NOTION_TOKEN`; Linear `LINEAR_API_KEY`; environment only. |
| Binding/content | Re-register after branch changes; Notion text must use top-level blocks. |

## PR description structure

`.agents/lib/pr-description.sh` checks create/edit/ready operations, drafts included, before acknowledgment handling.

| Requirement | Contract |
| --- | --- |
| Design link | Rendered anchor outside code exactly targets the registered canonical URL. |
| Preserved body | Fetch published text and match branch/HEAD, including metadata-only edits. |
| Explanation | Rendered level-two **How it works** has content before the next peer/higher heading. |
| Accepted content | Prose, lists, tables, diagrams; any independently qualifying matching section suffices. |
| Rejected content | Nested headings alone, quotes, comments, example headings, or placeholder-only/mixed placeholders. |
| Render bounds | 20 seconds, 64 KiB; failure blocks publication without consuming acknowledgment. |

Hidden source URLs do not count; direct API/browser writes bypass this CLI boundary; example accuracy and relevance remain human review responsibilities.

### PR body files

Run the launcher from a Claude Code or Codex shell in the PR checkout. Use the plugin's installed path in place of `/path/to/plugin`.

```sh
bash /path/to/plugin/scripts/gh-pr.sh create --draft --title 'fix: keep approved text' --body-file ./pr.md
bash /path/to/plugin/scripts/gh-pr.sh edit 42 --title 'fix: keep approved text' --body-file ./pr.md
```

Omit `--draft` for a non-draft create. Put metadata and target flags after the title and body file.

| Boundary | Contract |
| --- | --- |
| Input | One regular UTF-8 file, up to 24 KiB. Reject symlinks, special files, stdin, and NUL bytes. |
| Checks | Apply the same writing, privacy, design, size, target, and review rules as inline PR text. |
| Review | When required, match the SHA-256 shown in the diagnostic to the reviewed file. A different body or session needs a fresh acknowledgment. |
| Publication | Pass the checked bytes to `gh` through stdin, including trailing newlines. |

Use a direct launcher call with the host's session environment. Direct `gh` commands require inline bodies.

## PR size and stacks

`.agents/lib/pr-target.sh` resolves one target for size, design, and review; `.agents/lib/pr-size.sh`/`.agents/lib/pr-size.jq` measure published GitHub comparisons.

| Target input | Contract |
| --- | --- |
| Checkout | `workdir` → tool `cwd` → event `cwd` → process cwd; explicit invalid directories deny. |
| Legacy state | Without metadata, retain `CLAUDE_PROJECT_DIR` review state. |
| Alternate checkout | Literal `env -C /absolute/checkout` / supported `--chdir`; reject relative, dynamic, repeated, or other overrides. |
| Repository | Literal `--repo`/`-R`, `[HOST/]OWNER/REPO`, before/after subcommand. |
| Creation | Published head must match local HEAD; resolve fork network without guessing repository name. |
| Base | Explicit `--base`/`-B`, head branch `gh-merge-base`, then repository default. |
| Head | `--head`/`-H`, including `owner:branch`; separated, equals, attached short forms. |
| Edit/ready | Resolve PR refs, repository, number, body; omitted selectors preserve gh branch tracking. |
| Unsupported | Duplicate/dynamic targets, URL selectors, base-changing edits, environment overrides. |

Size/review authority binds host, repository, refs, commits, PR identity, and session where applicable; targets recheck before publication.

For example, 612 code additions trigger **Bypass limit** or **Split PR**. A bypass binds that diff without requiring justification.

Creation becoming an existing PR changes identity; later GitHub writes cannot be atomic with the hook.

| Measurement | Rule |
| --- | --- |
| Count | Code additions, including comments/blank lines, configuration, generated files, unknown extensions, MDX, and build/dependency manifests. |
| Exclude | `*.spec.ts`, `*_test.go`, `tests/`, recognized prose, assets/data/logs, lockfiles; classifier owns exact list. |
| Renames | Test destinations excluded; otherwise either code name counts; repository attributes cannot override classification. |
| Completeness | Validate names/statistics; ≥300 returned files deny because GitHub may truncate even prose-only comparisons. |
| Threshold | 400 code lines pass; 401 asks **Bypass limit** or **Split PR**. |
| Decision | Bypass needs no reason, binds exact diff; split persists on retry; changed HEAD invalidates bypass, even for excluded files. |

Git pushes, API/browser writes, and stack commands bypass per-PR size checking; other publication checks still apply.

[Workflow](../guidance/workflow.md#pr-size-and-decomposition) owns decomposition; [tracking template](../.agents/prompts/pr/split-pr-tracking-issue.md) owns the plan.

Publish each layer through guarded commands, then `gh stack link` verified PR URLs with matching bases; issue creation has no gate.

## Author review acknowledgment

The write-enabled `.github/workflows/author-review.yml` checks out the repository's trusted default branch. It invokes `scripts/pr-author-review.sh` → `.agents/lib/pr-author-review.sh` → `pr_author_review_run` independently of local hooks.

| Live state | Result |
| --- | --- |
| No current acknowledgment | Pending; convert ready PR to draft and verify mutation identity/state. |
| Author's new, unedited `/reviewed <full-head-SHA>` comment | Success; preserve draft until manually marked ready. |
| Changed head or edited/deleted sole acknowledgment | Pending/draft; fresh comment required. |
| Another open PR shares head | Pending/draft; distinct commit required. |
| API/malformed state or 1000-comment/PR bound | Pending where writable; handler error. |
| Closed PR / ordinary issue | No write. |
| Merge queue temporary commit | Carry forward required PR-admission status; no new acknowledgment. |

- Subscribe to PR opened/reopened/synchronize/ready/closed and comment created/edited/deleted; serialize per PR without canceling active runs, five-minute job limit.
- Recompute live state for human comments, including `/recheck-author-review`; ignore new bot comments, repair edited/deleted instruction comments idempotently.
- Revoke success before scanning; refetch matching comments, retry head races at most three times, and reject edited comments/bot substitutes.
- One bot prompt uses the shared review question and writing/privacy checks; the comment is the record, with no separate database/token/App.
- Require **Author reviewed the PR** from GitHub Actions in branch rules and queue admission; job name **Update author review status** cannot substitute.
- Exit 0 means acknowledged/irrelevant, 1 awaiting acknowledgment, 2 error; failed writes cannot revoke remote success and need investigation.
- Forks follow the same rules; SHA acknowledgment asserts review, never proves reading/description quality, and survives body edits; maintainer approval remains separate.
