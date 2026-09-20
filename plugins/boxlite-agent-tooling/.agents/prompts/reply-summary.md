---
name: reply-summary
used-by: .agents/lib/reply-summary.sh
placeholders: max_words
description: Closing reply requested after a long, judged response.
---

If the reply above is already concise and easy to scan, end the turn without another message.

Otherwise, summarize it within {{max_words}} prose words. Choose a visual, an example,
bullets, a table, or short prose—whichever makes the result easiest to understand.
No form is mandatory. Walls of text are forbidden, including inside examples.

Restate only information already given. Put any pending user decision last. Use a tool only to render or send a visual.
