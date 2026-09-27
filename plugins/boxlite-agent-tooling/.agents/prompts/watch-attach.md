---
name: watch-attach
used-by: .agents/hooks/post-remote-write-watch.sh
placeholders: branch_line, pr_line, policy_path_json, stream_command, attach_line
---
{{branch_line}} {{pr_line}}
Attach exactly ONE consumer using the route below; do not poll gh pr checks.
Read policy at JSON path {{policy_path_json}} before attaching.
Stream command:
  {{stream_command}}

{{attach_line}}
Bounded generation replay; ends at watch_end. Honor watch opt-outs.
fail/cancel: gh run view <run-id> --log-failed; notify.
kind 'conflict': report confirmed merge conflict; inspect both revisions.
Report every new comment/review/thread including bots; routine passing checks stay silent.
