---
name: commit-push-target-note
used-by: .agents/hooks/preflight-commit-push.sh
placeholders:
---
NOTE: git exposes no arguments to pre-commit and no fresh PreToolUse handoff bound the
command, so target_command above is the placeholder `git commit`. Before spawning,
replace it with the exact git commit command you are running (with -m/--message or
-F <file>); an audit of the placeholder cannot bind a subject and commit-msg rejects it.
