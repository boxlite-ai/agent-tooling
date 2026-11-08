---
name: timed-question-git-audit
used-by: .agents/lib/user-question.sh
placeholders: prefix, id, label_1, label_2
---
Three failed rounds stopped the audit loop. After five minutes, Reflect again applies.

- `{{prefix}} {{id}} {{label_1}}` — Reflect, fix, test, and run one fresh audit. Keep all findings.
- `{{prefix}} {{id}} {{label_2}}` — Keep Git blocked and report incomplete verification.
