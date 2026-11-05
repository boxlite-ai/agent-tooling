---
name: timed-route-design-async
used-by: .agents/lib/timed-user-prompt.sh
placeholders: question
---
Ask once with `request_user_input_async` using this exact payload; retain the request ID in the title:

{{question}}

Free-text answers need `design-decision: <choice> <reason>`. Never relay an answer through a command.
