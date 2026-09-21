---
name: reply-summary
used-by: .agents/lib/reply-summary.sh
placeholders: max_words
description: Closing reply requested after a dense, judged response.
---

Walls of text are forbidden. Skip the summary if the reply is already concise and easy to scan.
Otherwise, prefer: visuals > tables > bullets > prose (under {{max_words}} words; 120 for complex topics).

Restate only information already given. Put any pending user decision last. Use a tool only to render or send a visual.
