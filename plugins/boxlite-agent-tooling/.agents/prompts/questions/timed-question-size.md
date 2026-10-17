---
name: timed-question-size
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id
---
{
  "questions": [
    {
      "question": "{{prefix}} Bypass the 400-line guideline for this PR? [{{id}}]",
      "header": "PR size",
      "multiSelect": false,
      "options": [
        {
          "label": "Bypass limit",
          "description": "Proceed with this PR without splitting."
        },
        {
          "label": "Split PR",
          "description": "Break changes into smaller PRs."
        }
      ]
    }
  ]
}
