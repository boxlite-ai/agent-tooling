---
name: timed-question-size
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id, label_1, label_2
---
{
  "questions": [
    {
      "question": "{{prefix}} Bypass the 400-line guideline for this PR? [{{id}}]",
      "header": "PR size",
      "multiSelect": false,
      "options": [
        {
          "label": "{{label_1}}",
          "description": "Proceed with this PR without splitting."
        },
        {
          "label": "{{label_2}}",
          "description": "Break changes into smaller PRs."
        }
      ]
    }
  ]
}
