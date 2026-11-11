---
name: worker-required
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: plugin_root
---
Run the assigned design worker through this exact Bash action, then retry the edit:
bash "{{plugin_root}}/scripts/design-doc.sh" run
