---
name: workflow-continue
used-by: scripts/continue-workflow.sh
placeholders: branch, pending
---
The design for '{{branch}}' passed its audit, and this turn ends with {{pending}}.
- Implementation finished and its checks pass: commit, push, and open a draft PR now, without asking.
- Paused for a reason the workflow's Progression rule permits: stop again.
This reminder appears once per work state.
