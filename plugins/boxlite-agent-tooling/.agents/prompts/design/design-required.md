---
name: design-required
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: plugin_root
---
Before writing code, write a design with `boxlite-design-doc`, then register it:
bash "{{plugin_root}}/scripts/design-doc.sh" register <GitHub-issue/Notion/Linear-URL>
Shell investigation and registration remain available.
