---
name: pr-watch-schedule
used-by: .agents/prompts/watch/watch-attach-codex.md
placeholders: KEEPALIVE_PATH_JSON, TARGETS_JSON
---
# PR watcher schedule

## Setup

Create/reuse one 10-minute heartbeat per chat. Preserve opt-outs, pauses, and mutes.
Verify saved destination, targets, cadence, and status through the app.

Render only the block below:
- `KEEPALIVE_PATH_JSON`: JSON-quoted absolute path to ../../watch/pr-watch-keepalive.sh.
- `TARGETS_JSON`: verified objects with absolute worktree, branch, optional PR number string.

## Scheduled prompt

```text
Keep PR watchers alive.
Run bash with script {{KEEPALIVE_PATH_JSON}} and one JSON argument: {{TARGETS_JSON}}
Pause this schedule when active=0. Stay silent.
```
