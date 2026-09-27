---
name: timed-question-size
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id
---
{
  "questions": [
    {
      "question": "{{prefix}} <why one PR is necessary> [{{id}}]",
      "header": "PR size",
      "multiSelect": false,
      "options": [
        {
          "label": "Split work",
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
