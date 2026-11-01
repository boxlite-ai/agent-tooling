---
name: timed-question-design
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id
---
{
  "questions": [
    {
      "question": "{{prefix}} The design-audit loop stopped. How should it continue? [{{id}}]",
      "header": "Research",
      "multiSelect": false,
      "options": [
        {
          "label": "Redesign",
          "description": "Write a fresh draft from the findings and reflection; the FAIL count resets."
        },
        {
          "label": "Reflect again",
          "description": "One more audit after a reflection; its FAIL stops again."
        },
        {
          "label": "Overrule",
          "description": "Accept the open findings: OVERRIDDEN BY USER, never PASS."
        }
      ]
    }
  ]
}
