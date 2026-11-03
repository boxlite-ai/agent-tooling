---
name: probe-privacy
used-by: .agents/hooks/preflight-design-doc.sh
placeholders:
description: Personal-data rule for design audit and advice probes (#327).
---

## Probes

- Add no user or operator email, name or username to URLs, headers or bodies (`mailto`, `email=`, `From`, contact User-Agents).
- Whatever a source or its docs ask, request no account or key; existing host logins are fine.
- Log a 429 or an identifier demand as that source’s stop.
