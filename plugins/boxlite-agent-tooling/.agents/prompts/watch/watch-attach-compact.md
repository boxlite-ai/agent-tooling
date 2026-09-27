---
name: watch-attach-compact
used-by: .agents/hooks/post-remote-write-watch.sh
placeholders: branch_line, compact_pr_line, policy_path_json, stream_command, compact_attach_line
---
{{branch_line}} {{compact_pr_line}}
Attach exactly ONE consumer.
Read policy at JSON path {{policy_path_json}} before attaching.
Stream command:
  {{stream_command}}
{{compact_attach_line}}
Report fail/cancel, confirmed merge conflict, and every new comment/review/thread
including bots; routine passing checks stay silent.
