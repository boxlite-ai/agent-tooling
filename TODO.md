## TL;DR

Pending API compatibility fix from PR #251.

## Details

- [ ] Preserve API confirmation across CRLF/LF conversion in [specification fingerprints](plugins/boxlite-agent-tooling/.agents/lib/api_contract.py). A confirmed CRLF working copy must remain approved after Git stores LF. Other content changes must still require confirmation. Cover commit, push, and push-ref with a regression test.
