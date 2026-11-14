---
name: advice-required
used-by: .agents/hooks/preflight-design-doc.sh
placeholders: verdict, advisories, instruction
---
The design audit recorded {{verdict}} for the current design. Before code edits, its assigned advisor must advise on it.
Advice never changes the verdict.
Advisories (not blocking):
{{advisories}}
Once it records, start implementing without waiting. Report each advisory and advice
item with your view in the final reply and the PR;
adopt an item only after the human accepts it.

{{instruction}}
