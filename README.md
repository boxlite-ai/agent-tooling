# BoxLite Agent Tooling

Canonical, versioned coding-agent resources shared by BoxLite repositories.

The repository packages one `boxlite-agent-tooling` plugin for Codex, Claude
Code, and GitHub Copilot. It owns reusable skills, audit agents, lifecycle
hooks, Git gates, and PR watchers. Consumer repositories keep only thin
activation settings, the branch they float on (`tooling.ref`), and a private
profile manifest; the adopted revision is recorded locally in
`.git/agent-tooling/current`.

## Layout

```text
.agents/plugins/marketplace.json        Codex repository marketplace
.claude-plugin/marketplace.json         Claude-compatible marketplace
.github/plugin/marketplace.json         Copilot marketplace
plugins/boxlite-agent-tooling/          Shared multi-host plugin
plugins/boxlite-agent-tooling/guidance/ Canonical engineering-workflow guidance
templates/install.sh                    Thin consumer bootstrap
templates/codex-plugin-bootstrap.json   Full-plugin Codex SessionStart wiring
templates/codex-plugin-bootstrap.sh     Trust-once Codex plugin bootstrap
templates/claude-plugin-bootstrap.json  Full-plugin Claude project settings
templates/claude-plugin-bootstrap.sh    Trust-once Claude plugin bootstrap
templates/merge-claude-plugin-settings.jq  Canonical Claude settings merge
templates/codex-hooks.json              Prompt-only Codex wiring
templates/claude-settings.json          Scoped Claude Code prompt-rule wiring
```

Codex's repository marketplace uses a typed Git-subdirectory source. The nested
`source.source: "git-subdir"` discriminator is required alongside `url`, `ref`, and
`path`; omitting it makes the plugin undiscoverable. Profile validation and the
host-parity suite pin that complete shape.

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

The clone-side flow is:

```text
git clone
└─ open the repository in Codex
   ├─ review and trust the project SessionStart command
   └─ next startup or resume
      └─ .agent-tooling/codex-plugin-bootstrap.sh
         ├─ verify the adopted tooling locally
         ├─ install it in lifecycle mode when missing or invalid
         ├─ add the canonical boxlite-ai/agent-tooling Git marketplace
         ├─ compare the installed plugin with the adopted manifest version
         ├─ refresh and validate the adopted tip first when versions differ
         ├─ install once, or upgrade the marketplace snapshot on version drift
         └─ ask for a new Codex task
            └─ review the installed plugin's command hooks with /hooks
```

The marketplace source is the canonical Git URL, not the consumer's local `.` path.
Codex stores configured marketplaces in user scope by marketplace name; two clones or
worktrees with the same name but different local paths conflict. The shared Git source
gives every consumer one stable identity. The bootstrap validates the catalog before
installing, refreshes only when the adopted plugin version changes, preserves an
intentionally disabled plugin, stays silent on later valid starts, and fails closed
with stderr when setup is incomplete.

Trust is deliberately not transferable. Codex reviews the committed project bootstrap
before it runs, then separately reviews the plugin-bundled hooks after installation.
Plugin skills, tools, and hooks load only in a new task. There is no repository command
that safely pre-approves those plugin hook definitions. The one-time approval is for
the stable command definition, not a content hash of the script it launches; later
changes to `codex-plugin-bootstrap.sh` therefore rely on the consumer repository's
normal branch protection and code review.

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

The explicit array merge preserves existing `SessionStart` and `UserPromptSubmit`
hooks as well as unrelated settings and hook events. It also emits the host's canonical
top-level and command-field order, preferring the current template when an older copy
of the same hook is already present. This keeps the first plugin installation from
rewriting and dirtying the committed settings file. The template floats on `main`; if
the consumer's `tooling.ref` names another branch, change the template's marketplace
`ref` to that same value before committing it.

The clone-side call graph is:

```text
git clone
└─ open the repository in Claude Code
   ├─ review and trust the repository once
   └─ trusted SessionStart (startup, resume, fork, or /clear)
      └─ .agent-tooling/claude-plugin-bootstrap.sh
         ├─ verify the adopted tooling locally
         ├─ install it in lifecycle mode when missing or invalid
         ├─ validate or add boxlite-ai/agent-tooling@tooling.ref
         ├─ compare the project plugin with the adopted manifest version
         ├─ refresh and validate the adopted tip first when versions differ
         ├─ install once, or update the marketplace and plugin on version drift
         ├─ record success for this Claude session
         └─ ask for /reload-plugins or a new Claude session
            ├─ UserPromptSubmit --check → require that success record
            └─ Task(subagent_type="boxlite-agent-tooling:<auditor>")
```

The hook validates the public CLI state before every mutation because Claude permits
a same-name marketplace to be replaced with a different source. It also distinguishes
project installations by canonical worktree path, verifies an update reached the
adopted version without changing an explicit local disable, and suppresses installer
chatter that would otherwise enter model context.

Claude does not let a `SessionStart` hook block the conversation. On failure the
bootstrap therefore writes a per-session error and exits nonzero; the committed
`UserPromptSubmit` hook exits 2 until that same session has a successful bootstrap
record. The pair, rather than a fake `SessionStart` decision response, is the
fail-closed boundary.

There is no shell command that hot-loads the newly installed agents and hooks into
the already-running parent process. `/reload-plugins` is therefore the final one-time
step; later valid starts are silent. Repository trust remains a human decision and is
not pre-approved by these files.

### Long-running auditor escalation

`commit-push-auditor` and `verdict-auditor` run normally for their first 30 seconds.
After that, Claude Code's asynchronous `SubagentStart` hook uses `asyncRewake` to wake
the parent with an instruction to open one `AskUserQuestion` card:

- **Keep waiting (Recommended)** — dismiss this escalation and leave the auditor active.
- **Force pass — auditor is taking too long** — override both auditor gates for this
  prompt with that user-selected reason.

The card blocks the parent conversation but not the auditor. If the user does nothing,
the audit keeps running. Claude Code exposes no completion hook that can dismiss an
already-rendered question, so the card may remain stale after the audit finishes; a
later click is still safe because the selection command rejects a terminal or replaced
generation. `SubagentStop` closes the exact session, prompt epoch, auditor, and
generation record when completion arrives.
Claude's host-generated `<task-notification>` wake and completion envelopes do not
advance the human prompt epoch. The wake consumes a random generation-bound marker;
prompt closure or same-auditor replacement retains a non-authorizing pending-stop
receipt for each displaced active generation, and every `SubagentStop` adds one
matching completion-delivery credit. Each host completion consumes one credit,
including repeated notifications from a resumed task. This avoids relying on the
transcript, which Claude appends only after
`UserPromptSubmit` hooks finish.

Codex's strict hook schema accepts `async` but not `asyncRewake`, so the generic and
Codex manifests use `hooks/codex-hooks.json`; Claude conventionally discovers
`hooks/hooks.json`. `host-parity.test.sh` normalizes the one delivery-key difference and
requires every command and all remaining behavior to match. Codex receives the same
non-blocking typed status instruction at its next safe conversation point.

For headless or accessibility use, submit this as the first non-empty prompt line:

```text
force-pass-auditors: <required reason>
```

The override is bound to the canonical repository, host session, and new prompt epoch,
expires within one hour, and is revoked by the next real prompt. Runtime state stores a
nonce hash and reason hash, not the bearer or reason. Gate-use logs say `OVERRIDDEN` and
bind commit, push, and Stop uses to their actual diff/subject/tree context. No PASS
dossier is created or rewritten. Installation and guidance checks, PR-review
acknowledgement, chained framework hooks, exact push-ref calculation, PR watching,
host permissions, and remote protections remain in force.

## Shared engineering guidance

`plugins/boxlite-agent-tooling/guidance/workflow.md` is the canonical, domain-neutral
engineering workflow (understand → research → design → implement → test → verify) that
consumers used to hand-copy into their CLAUDE.md. `scripts/sync-guidance.sh` splices it
into each consumer's committed instructions files between HTML-comment markers:

```text
AGENTS.md    the consumer's own domain knowledge, then:
             <!-- agent-tooling:guidance:begin rev=<sha> sha256=<hash> -->
             …shared workflow, replaced in place on adoption…
             <!-- agent-tooling:guidance:end -->
CLAUDE.md    @AGENTS.md bridge (plus Claude-specific lines) — exempt from the block
```

Committed text is the one channel every host reads natively — Codex recognizes only
AGENTS.md by default, Claude Code only CLAUDE.md (which inlines the `@AGENTS.md`
import), Copilot either — and it reaches clones that never ran an install, cloud
agents included. Claude Code strips block-level HTML comments before injection, so
the markers cost no context. A consumer whose two files are one file (a symlink
either direction) gets exactly one splice; a repository with neither file gets this
layout created.

The splice runs only on an EXPLICIT `./.agent-tooling/install.sh` (or a direct
`setup.sh`): lifecycle-triggered installs defer it, so a background refresh can never
dirty a worktree, and a target with uncommitted tracked modifications is skipped with
a warning. The commit and push gates run `sync-guidance.sh --check`: a missing,
malformed, or hand-edited block — the begin marker's `sha256` no longer matching the
body — fails closed, while a block merely behind the adopted revision only warns
(consumers float same-ref, not same-revision, like the host activations). Overwrite a
hand-edited block deliberately with
`AGENT_TOOLING_GUIDANCE_FORCE=1 ./.agent-tooling/install.sh`.

The canonical text is pinned by `scripts/sync-guidance.test.sh` to stay within 150
lines and free of repo-specific residue — concrete exemplars belong in each
consumer's own half of the file. A consumer CI backstop is two commands:
`./.agent-tooling/install.sh && git diff --exit-code -- AGENTS.md CLAUDE.md`
(a stale block becomes a diff, a hand-edited one fails the install itself).

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

A fresh consumer has neither the file nor its parent directory, and `jq -s` on a
missing path fails rather than treating it as empty.

The two wirings differ in exactly one respect: Claude Code exports
`$CLAUDE_PROJECT_DIR`, while Codex has no project-root variable and substitutes
`$(git rev-parse --show-toplevel)` instead. `templates/prompt-rules.test.sh` asserts
they stay otherwise identical, so neither host quietly gains a rule the other lacks.

This wiring is deliberately independent of the installation. It never reads
`.git/agent-tooling/`, needs no bootstrap, and works in a repository that has
never installed the plugin — the consumer's `rule-recency.sh` is a committed snapshot.

The cost is drift: the plugin floats on `tooling.ref`, but this copy does **not**
follow it, and nothing detects the gap, because the copies are invisible from this
repository. Refresh one by re-running the `cp` above and committing the result. Weigh
that against the audit gates, where staleness is a correctness problem rather than a
wording one.

Four things about these files are load-bearing, and each one fails silently when it is
wrong:

- The **nested `hooks` array** inside each event entry is required:
  `UserPromptSubmit[] -> .hooks[] -> {type, command}`. Command objects placed directly
  in the event array are the obvious wrong guess and register nothing.
- Event names are **PascalCase** (`UserPromptSubmit`). Codex records hook trust under
  snake_case keys, which makes the wrong casing look plausible.
- **No comment keys.** Both hosts validate strictly and reject an unknown key at any
  depth by loading no hooks at all; Codex does it without logging a parse error.
- For Codex the project must be **trusted**, and each command-hook definition must be
  reviewed and trusted with `/hooks`. Trust is tied to the exact definition, so a
  changed command is skipped until it is reviewed again.

`templates/prompt-rules.test.sh` pins all four for both hosts, because nothing
downstream reports them. It also checks that `rule-recency.sh` still runs with nothing
else installed, which is the assumption the committed copy rests on.

The hooks feature itself needs no flag opt-in: `codex features list` reports it as
`stable` and enabled by default. Plugin hooks still require an installed, enabled
plugin and the command trust described above.

## Validate

Codex officially supports a `hooks` entry in `.codex-plugin/plugin.json` for
[plugin-bundled hooks](https://learn.chatgpt.com/docs/hooks#plugin-bundled-hooks).
The generic `plugin-creator/scripts/validate_plugin.py` bundled with some Codex
releases still rejects that documented field, so it is not a release gate for this
cross-host plugin. `host-parity.test.sh` validates the three manifests, the shared
hooks schema, every declared path, and every wired command instead.

```sh
bash plugins/boxlite-agent-tooling/host-parity.test.sh
claude plugin validate plugins/boxlite-agent-tooling
bash templates/codex-plugin-bootstrap.test.sh
bash templates/claude-plugin-bootstrap.test.sh
```

The parity suite is the cross-host check the two host validators cannot make: it
asserts Claude Code's conventional discovery, Codex's declared paths, and the generic
manifest all resolve to the same skills and agent specs, that the host hook manifests
normalize to the same behavior, that every wired command resolves its root on both
hosts, and that the marketplaces advertise the version the manifests actually carry.

After installation, configure repository Git hooks explicitly:

```sh
plugins/boxlite-agent-tooling/scripts/setup.sh /path/to/consumer
```

## Unattended runs

A turn that dies on an API error ends the run: the host fires `StopFailure` instead of
`Stop`, and that event is fire-and-forget, so nothing in the session can resume it. For
runs nobody is watching, wrap them:

```sh
plugins/boxlite-agent-tooling/scripts/resume-on-network-error.sh "<task prompt>"
```

It restarts only what another attempt could fix. The failure kind is not in the result
JSON — `terminal_reason` reports a bare `api_error` — so the wrapper reads it from the
record `.agents/hooks/record-api-failure.sh` publishes under `.agents/state/`. Without
that hook wired, or with `CLAUDE_PROJECT_DIR` unset so writer and reader disagree on the
project root, every failure degrades to the two-restart unknown budget and exits 5.

`--max-wait` is one budget for the whole run rather than per restart — six hours by
default, long enough to outlast a usage window that resets on its own schedule. Waits
double from 5s to a 30-minute ceiling and keep growing across restarts, so a multi-hour
outage costs a handful of probes instead of hundreds of rejected calls.

Exit codes a CI wrapper branches on: `0` the run completed · `1` a permanent fault
(auth, billing, invalid request) · `2` usage · `3` restart budget spent · `4` wait
budget spent · `5` the failure kind was never recorded. Needs `curl` in addition to
`claude` and `jq`.

Exit 4 says the run waited as long as it was allowed, not that the network is down — a
usage window that never reopened inside the budget ends there too, with the endpoint
reachable throughout.

## Floating updates

Consumers copy `templates/install.sh` to `.agent-tooling/install.sh` and declare the
branch they float on in `.agent-tooling/profile.json` (`tooling.ref`, normally
`main`). The bootstrap resolves the branch tip, fetches that exact revision under the
repository's common Git directory, validates the private profile, configures
worktree-local shared Git hooks, and only then records the revision in
`.git/agent-tooling/current` — so a tip that fails validation is fetched, rejected,
and never adopted.

Commits and pushes verify against that record with a pure local check: offline work
keeps running on the last adopted revision, and only the very first installation
needs the network. Checkouts, merge-based pulls, rebases, and amended commits repair
a broken installation in the foreground and otherwise spawn a throttled background
refresh (`scripts/refresh-installation.sh`) that adopts a moved tip. Set
`AGENT_TOOLING_REFRESH=0` to disable the polling, `AGENT_TOOLING_REFRESH_MINUTES` to
retune the throttle. Every adoption appends `<epoch> <source> <sha>` to
`.git/agent-tooling/history.log`, which is what answers "which tooling was active
here" now that the revision no longer lives in repository history.

To freeze the fleet — a bad tip landed, or a revision must be kept for a bisect —
write one full lowercase commit SHA to `.agent-tooling/hold` (commit it to freeze
every clone, keep it local to freeze one machine). While a hold exists nothing is
resolved, the gates stay closed until the held revision is adopted, and a malformed
hold fails the installation rather than letting it float on. Delete the file to
resume floating. Session bootstraps also honor the freeze: if an installed host
plugin differs from the held manifest version, they fail without refreshing the
marketplace or plugin until the hold is removed.

Host plugin activations (`.claude/settings.json`, the Copilot settings, the Codex
marketplace) float on the same `tooling.ref` — the profile validation enforces it.
The Claude and Codex session bootstraps compare their installed plugin version with
the adopted checkout and touch the network only on a mismatch. They first refresh and
validate the tooling tip, which reconciles a host that updated before the repository's
throttled poll; only a host that remains behind gets a plugin refresh. Every plugin
release must therefore bump all parity-checked manifests. Copilot still resolves the
ref on its host schedule, so the cross-host agreement is same-ref, not necessarily
same-revision.
`templates/install.test.sh` pins the adoption path against a local fixture remote.
