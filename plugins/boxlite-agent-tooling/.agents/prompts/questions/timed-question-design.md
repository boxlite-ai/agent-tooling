---
name: timed-question-design
used-by: .agents/lib/user-question.sh
placeholders: prefix, id, label_1, label_2, label_3
---
The design audit stopped. How should it continue?

- `{{prefix}} {{id}} {{label_1}} <reason>` — Write a fresh draft from the findings and reflection. The FAIL count resets.
- `{{prefix}} {{id}} {{label_2}} <reason>` — Reflect and run one more audit. Its FAIL stops again.
- `{{prefix}} {{id}} {{label_3}} <reason>` — Accept the open findings as OVERRIDDEN BY USER.
