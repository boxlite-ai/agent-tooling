---
name: timed-question-git-audit
used-by: .agents/lib/timed-user-prompt.sh
placeholders: prefix, id, label_1, label_2
---
{
  "questions": [{
    "question": "{{prefix}} Three failed rounds stopped the audit loop. Choose the next step; after five minutes, Reflect again applies. [{{id}}]",
    "header": "Audit retry",
    "multiSelect": false,
    "options": [
      {"label": "{{label_1}}", "description": "Reflect, fix, test, and run one fresh audit; keep all findings."},
      {"label": "{{label_2}}", "description": "Keep Git blocked and report incomplete verification."}
    ]
  }]
}
