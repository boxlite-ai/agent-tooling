---
name: timed-question-design
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id, label_1, label_2, label_3
---
{
  "questions": [
    {
      "question": "{{prefix}} The design-audit loop stopped. How should it continue? [{{id}}]",
      "header": "Research",
      "multiSelect": false,
      "options": [
        {
          "label": "{{label_1}}",
          "description": "Write a fresh draft from the findings and reflection; the FAIL count resets."
        },
        {
          "label": "{{label_2}}",
          "description": "One more audit after a reflection; its FAIL stops again."
        },
        {
          "label": "{{label_3}}",
          "description": "Accept the open findings: OVERRIDDEN BY USER, never PASS."
        }
      ]
    }
  ]
}
