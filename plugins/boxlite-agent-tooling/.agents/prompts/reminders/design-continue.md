---
name: design-continue
used-by: scripts/continue-workflow.sh
placeholders: branch
---
The design gate blocked an edit on '{{branch}}' this turn, and no passed design exists yet.
- Follow the gate's last instruction now, without asking: write, publish and register the design, or run its audit.
- Paused for a reason the workflow's Progression rule permits: stop again.
This reminder appears once per blocked edit.
