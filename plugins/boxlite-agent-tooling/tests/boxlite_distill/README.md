## TL;DR

Evaluate distillation through realistic requests, completed artifacts, source comparison, and observed execution. Keep each criterion's evidence and limits separate; a small working helper does not establish whole-system behavior.

## Details

### Prepare

- Record the exact request, source revision/raw fixture, audience, environment, and skill version before generation. Declare the acceptance criteria before viewing the answer.
- Give an independent evaluator only the request, skill, permitted sources, and operational constraints. Withhold previous artifacts, suspected defects, intended answers, and this review rubric.
- Use isolated output directories. Preserve sources and skill files; apply normal authorization rules to installations, publications, and other side effects.

### Requests and review criteria

Use a pinned public libkrun checkout for the code exercises; another representative system may be substituted with its defining behavior recorded first.

| Request | Reviewer checks |
| --- | --- |
| Explain libkrun's design and produce a minimal working VMM for a reader who knows basic C. | Major responsibilities, actual components, owned state, interfaces, and connections are accounted for. A complete guest-execution path remains; a host-only queue exercise is insufficient. Verify native behavior when available. |
| Distill only libkrun's console transmit queue into a runnable learning example. | Explicit scope is honored. VM boot is not required; the real queue mechanism, supported conditions, output, and completion are exercised. |
| Explain libkrun's architecture and component responsibilities without creating a replacement implementation. | Design coverage and lifecycle are explained. Code input does not force implementation. |
| Extract the essential policy from `fixtures/retry-policy.txt`, with one example and a boundary case. | Preserve known failure and idempotence, the total-attempt bound including the first, stopping on success, and the unresolved-timeout exception. Drop irrelevant display detail. Compare with the raw fixture, not the answer's description of it. |

For libkrun, record a minimum defining behavior before testing: create a VM, provide guest memory/code, execute the guest, perform device I/O, and terminate. This is an evaluation target, not a project-specific rule in the general skill. Linux boot is required only when the chosen learning target includes it.

### Bound evidence

- Inventory evidence by claim and source class before reading. Use the caller's byte limits, reserve review headroom, and count repeat content reads and hashing. Small output from a command does not make its underlying reads free.
- Read relevant owning source and callers in bounded portions. Reuse already-read evidence in context instead of repeatedly scanning entire trees, archives, or reports. Do not evade limits through alternate tools or copies.
- Retain a compact packet: exact request/fixture, source and artifact identity, relevant excerpts, criterion-to-evidence references, commands, actual outcomes, and gaps. Identifiers/hashes establish identity, not correctness.
- If the next required check exceeds the remaining budget, stop that check and mark the criterion incomplete. Do not treat a missing original source or an author's self-description as independently verified evidence.

### Review completed output

1. Wait for completion; freeze the artifact before inspecting it. Bind checks to that version. If it changes, identify affected checks before rerunning them.
2. Check major-area coverage and a complete lifecycle/operation path against the requested scope and source. Grouped areas need roles and connections, not names alone. Mark unknown coverage.
3. Check source conditions, ownership, interactions, and declared semantic differences. Compare worked-example intermediate values with the final code or source.
4. Run the documented entrypoint and a meaningful boundary/failure case in isolation. Observe effects across the required system boundaries. A removal experiment may establish one element's necessity; do not generalize it to global minimality.
5. Answer purpose, responsibility/ownership, causal-flow, and omission-consequence questions from the main lesson. Record model review as such; it does not prove human comprehension.
6. Report coverage, fidelity, execution, reader sufficiency, and evidence completeness separately, with applicable/verified/partial/unverified status and supporting evidence. Retain failed attempts and environment-specific gaps. No complete verdict while a required check remains incomplete.

Compare revisions only when scope, source, audience, environment, and retained before/after evidence support the comparison. Report changed scope separately; omit unsupported improvement claims. Do not substitute wording/heading assertions for usage exercises.
