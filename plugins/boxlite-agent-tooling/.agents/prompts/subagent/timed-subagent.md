---
name: timed-subagent
used-by: .agents/lib/subagent.sh
placeholders: finish_at
description: One native Monitor reminder to finish a timed subagent's report.
---

## Timed subagent

Before starting work, use one available Monitor with `timeout_ms: 600000` to run:

```bash
finish_at={{finish_at}}
remaining=$(( finish_at - $(date +%s) ))
if (( remaining > 0 )); then sleep "$remaining"; fi
printf '%s\n' 'SUBAGENT_FINISH_NOW: Stop new checks and report collected evidence.'
```

On the notice, finish the task's required report with collected evidence and explicit
unchecked work. Follow its result contract; elapsed time never grants approval.
TaskStop the active timer before returning early; never rearm it.
If Monitor is unavailable, skip the reminder. Do not create another scheduler or poll.
