---
name: pr-size-exception
used-by: .agents/lib/pr-size.sh
placeholders: lines, base, head, request_id, state, tooling
description: A measured oversized PR needs a concrete human reason or splitting.
---

PR size: {{lines}} lines; maximum 400. Base {{base}}, head {{head}}.
Show this diff and a concrete split plan. Request human-typed
pr-size-exception: <change, concrete constraint, and why that split is unsafe or impractical>.
Reject generic urgency or convenience. The reason needs at least 12 words; length alone
does not make it concrete. Never invent or pre-fill a reason.
Claude's native question hook records valid replies automatically. Otherwise run
{{tooling}}/scripts/timed-user-prompt.sh respond for a valid human reply
with arguments {{state}}, {{request_id}}, and the verbatim reply, safely quoted.
Record the reason and diff context in the PR and parent issue; then retry.
On timeout create parent/child issues, a milestone, and small tested PRs.
