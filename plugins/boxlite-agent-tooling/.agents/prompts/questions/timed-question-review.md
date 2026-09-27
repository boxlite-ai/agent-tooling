---
name: timed-question-review
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id
---
{
  "questions": [
    {
      "question": "{{prefix}} <what changed> [{{id}}]",
      "header": "Review",
      "multiSelect": false,
      "options": [
        {
          "label": "Keep draft",
          "description": "Do not approve."
        },
        {
          "label": "Show diff",
          "description": "Inspect changes."
        }
      ]
    }
  ]
}
