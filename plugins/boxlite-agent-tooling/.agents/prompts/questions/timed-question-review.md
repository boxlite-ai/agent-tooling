---
name: timed-question-review
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id, label_1, label_2
---
{
  "questions": [
    {
      "question": "{{prefix}} <what changed> [{{id}}]",
      "header": "Review",
      "multiSelect": false,
      "options": [
        {
          "label": "{{label_1}}",
          "description": "Do not approve."
        },
        {
          "label": "{{label_2}}",
          "description": "Inspect changes."
        }
      ]
    }
  ]
}
