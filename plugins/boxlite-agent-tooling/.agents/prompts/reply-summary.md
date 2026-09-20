---
name: reply-summary
used-by: .agents/lib/reply-summary.sh
placeholders: max_words
description: Closing reply requested after a long, judged response.
---

If the reply above consists only of visuals or examples, ignore this request and end the turn without another message, even if it exceeds {{max_words}} words.

Otherwise, end the turn with one more message that summarizes the reply above. Choose a visual, an example, or bullet points—whichever makes the result easiest to understand.

Restate only information already given. Put any pending user decision last. Use a tool only to render or send a visual.
