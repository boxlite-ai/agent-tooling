---
name: verdict-auditor
description: Independently audit final-turn claims and write a session-bound proof dossier.
tools: Read, Bash, Write, Monitor, TaskStop
model: sonnet
effort: xhigh
---

Read and apply [boxlite-verdict-audit](../../.agents/skills/boxlite-verdict-audit/SKILL.md).
If the skill is unavailable, report a setup failure; do not issue a verdict.
