# BoxLite Agent Tooling

Canonical, versioned coding-agent resources shared by BoxLite repositories.

One plugin for Codex, Claude Code, and GitHub Copilot: reusable skills, audit
agents, lifecycle hooks, Git gates, and PR watchers. Copilot installation is untested.

| Read next | Covers |
| --- | --- |
| [Architecture](plugins/boxlite-agent-tooling/ARCHITECTURE.md) | Hooks, gates, state, and invariants |
| [Contributing](plugins/boxlite-agent-tooling/CONTRIBUTING.md) | Design docs, small PRs, and review acknowledgment |
| [Shared workflow](plugins/boxlite-agent-tooling/guidance/workflow.md) | Engineering guidance synced into consumer instructions |

## Example-led explanations

The shared [boxlite-examples skill](plugins/boxlite-agent-tooling/.agents/skills/boxlite-examples/SKILL.md)
explains through concrete state shapes, roles, relationships, and changes over time,
choosing diagrams, tables, or prose for clarity. It includes source-backed Commerce
top-up and VMM memory walkthroughs with illustrative values.
Try: "Use boxlite-examples to explain how Commerce top-up works."

## Automatic Codex bootstrap

A consumer that already carries the standard `.agent-tooling/install.sh`,
`.agent-tooling/profile.json`, and `.agents/plugins/marketplace.json` commits two
additional thin bootstrap files before anyone clones it:

```sh
mkdir -p "$consumer/.codex" "$consumer/.agent-tooling"
cp templates/codex-plugin-bootstrap.json "$consumer/.codex/hooks.json"
cp templates/codex-plugin-bootstrap.sh "$consumer/.agent-tooling/codex-plugin-bootstrap.sh"
chmod +x "$consumer/.agent-tooling/codex-plugin-bootstrap.sh"
```

If `.codex/hooks.json` already contains unrelated project hooks, merge the template's
`SessionStart` entry instead of overwriting the file. Add the prompt-only
`templates/codex-hooks.json` only when the repository explicitly wants its compact
reply reminder; the full plugin keeps `UserPromptSubmit` silent except for audit
cancellation.

Trust the project `SessionStart` command, then restart or resume to install the plugin.
Start a new Codex task and review its command hooks with `/hooks`.
Use the canonical Git marketplace URL; local clone paths conflict across worktrees.

## Automatic Claude Code bootstrap

Claude Code needs the same repository-owned bridge, with one extra lifecycle step:
project settings can advertise and enable an external plugin, but current Claude Code
does not install that plugin from `enabledPlugins` alone. A consumer commits the
bootstrap script and merges the full settings template before anyone clones it:

```sh
mkdir -p "$consumer/.claude" "$consumer/.agent-tooling"
cp templates/claude-plugin-bootstrap.sh \
  "$consumer/.agent-tooling/claude-plugin-bootstrap.sh"
chmod +x "$consumer/.agent-tooling/claude-plugin-bootstrap.sh"

if [ -f "$consumer/.claude/settings.json" ]; then
  jq -s -f templates/merge-claude-plugin-settings.jq \
    "$consumer/.claude/settings.json" templates/claude-plugin-bootstrap.json \
    > "$consumer/.claude/settings.json.new" &&
    mv "$consumer/.claude/settings.json.new" "$consumer/.claude/settings.json"
else
  cp templates/claude-plugin-bootstrap.json "$consumer/.claude/settings.json"
fi
```

The merge preserves existing hooks and settings. Match the marketplace `ref` to
the consumer's `tooling.ref` (default: `main`). Trust the repository, then run
`/reload-plugins` or start a new session after installation.
Failed bootstrap blocks prompts until that session completes setup successfully.

### Long-running auditor escalation

`commit-push-auditor` and `verdict-auditor` run normally for their first 30 seconds.
After that, Claude Code's asynchronous `SubagentStart` hook uses `asyncRewake` to wake
the parent with an instruction to open one `AskUserQuestion` card:

- **Keep waiting (Recommended)** — dismiss this escalation and leave the auditor active.
- **Force pass — auditor is taking too long** — override both auditor gates for this
  prompt with that user-selected reason.

For headless or accessibility use, submit this as the first non-empty prompt line:

```text
force-pass-auditors: <required reason>
```

The override expires within one hour or at the next real prompt. Other gates remain
in force. See [auditor control](plugins/boxlite-agent-tooling/ARCHITECTURE.md#entry-points).

## Shared engineering guidance

Run `./.agent-tooling/install.sh` explicitly to sync the shared workflow into
`AGENTS.md`; `CLAUDE.md` imports it with `@AGENTS.md`. Background refreshes leave
these committed files alone. Change the canonical workflow, not its managed block.

## Scoped prompt rules

A full plugin installation brings the audit, PR-review, and verdict gates with it. A
repository that explicitly wants only the reply-shape and workflow reminders can
commit the prompt hook on its own instead. Both hosts run the same committed script:

```sh
mkdir -p "$consumer/.agent-tooling"
cp plugins/boxlite-agent-tooling/.agents/hooks/rule-recency.sh \
   "$consumer/.agent-tooling/rule-recency.sh"
```

For this prompt-only option, Codex takes the whole file because `.codex/hooks.json`
holds nothing else:

```sh
mkdir -p "$consumer/.codex"
cp templates/codex-hooks.json "$consumer/.codex/hooks.json"
```

Claude Code needs a **merge**, not a copy — `.claude/settings.json` also carries keys
such as `env`, and overwriting it would drop them:

```sh
mkdir -p "$consumer/.claude"
if [ -f "$consumer/.claude/settings.json" ]; then
  jq -s '
    .[0] as $current | .[1] as $rules |
    ($current * $rules) |
    .hooks.UserPromptSubmit = (
      reduce (
        (($current.hooks.UserPromptSubmit // []) +
         ($rules.hooks.UserPromptSubmit // []))[]
      ) as $entry
        ([]; if index($entry) == null then . + [$entry] else . end)
    )
  ' "$consumer/.claude/settings.json" templates/claude-settings.json \
    > "$consumer/.claude/settings.json.new" &&
    mv "$consumer/.claude/settings.json.new" "$consumer/.claude/settings.json"
else
  cp templates/claude-settings.json "$consumer/.claude/settings.json"
fi
```

These copies work without the plugin and need manual refreshes. Keep the templates'
schema intact; Codex requires project trust and command-hook approval via `/hooks`.

## Validate

```sh
bash plugins/boxlite-agent-tooling/scripts/check-writing-ownership.sh .
bash plugins/boxlite-agent-tooling/host-parity.test.sh
bash plugins/boxlite-agent-tooling/architecture.test.sh
claude plugin validate plugins/boxlite-agent-tooling
bash templates/codex-plugin-bootstrap.test.sh
bash templates/claude-plugin-bootstrap.test.sh
bash templates/prompt-rules.test.sh
```

After installation, configure repository Git hooks explicitly:

```sh
plugins/boxlite-agent-tooling/scripts/setup.sh /path/to/consumer
```

## Author review acknowledgment

PR authors: follow the [acknowledgment steps](plugins/boxlite-agent-tooling/CONTRIBUTING.md#author-review-acknowledgment).

For consumers:

1. Copy [the workflow](.github/workflows/author-review.yml) with its events and permissions.
2. Run the handler from a reviewed, immutable tooling checkout with `persist-credentials: false`.
   Never execute PR-head code or the floating installer in this privileged workflow.
3. Publish existing PR statuses with `/recheck-author-review`, then require
   `Author reviewed the PR` from GitHub Actions in branch rules.
4. Remove the old file gate and `UNREVIEWED.md`; upgrade this pinned workflow manually.

## Turns cut off by an API error

Interactive Claude Code resumes server/overload failures at most three times per
session in ten minutes. Codex handles dropped-stream retries itself. See
[recovery hooks](plugins/boxlite-agent-tooling/ARCHITECTURE.md#entry-points).

## Unattended runs

A plain `claude -p` run has no in-session resume: the host runs `asyncRewake` hooks
synchronously there and ignores `StopFailure`'s exit code, so a turn that dies on an API
error ends the run. For runs nobody is watching, wrap them:

```sh
plugins/boxlite-agent-tooling/scripts/resume-on-network-error.sh "<task prompt>"
```

Requires `claude`, `jq`, `curl`, the plugin's failure-recording hook, and a matching
`CLAUDE_PROJECT_DIR`. `--max-wait` defaults to six hours for the whole run.

Exit codes a CI wrapper branches on: `0` the run completed · `1` a permanent fault
(auth, billing, invalid request) · `2` usage · `3` restart budget spent · `4` wait
budget spent · `5` the failure kind was never recorded. Needs `curl` in addition to
`claude` and `jq`.

## Floating updates

Consumers copy `templates/install.sh` to `.agent-tooling/install.sh` and declare the
branch they float on in `.agent-tooling/profile.json` (`tooling.ref`, normally
`main`). Only validated revisions are adopted; offline gates use the last valid cache.

Consumer bootstrap scripts are committed copies: copy updated
`templates/install.sh` and host bootstrap scripts into `.agent-tooling/` to adopt these
fixes; updating the shared plugin alone does not replace them.

| Control | Effect |
| --- | --- |
| `AGENT_TOOLING_REFRESH=0` | Disable background polling |
| `AGENT_TOOLING_REFRESH_MINUTES` | Set the refresh interval |
| `.git/agent-tooling/current` | Inspect the adopted revision |
| `.git/agent-tooling/history.log` | Inspect adoption history |

Freeze updates by writing one full lowercase commit SHA to `.agent-tooling/hold`.
Commit it for all clones or keep it local for one machine; delete it to resume.
Gates require the held revision. Host plugins with a different version fail until
the hold is removed.
