# Reviewer Receipt Adapter

Use this boundary before accepting any independent review. The loop receipt is richer
than most reviewer outputs; tool success or a clean verdict is not sufficient.

## Invocation envelope

Give the fresh read-only reviewer these orchestrator-owned facts:

```yaml
review_round: <R<N>>
reviewed_after_attempt: loop_start | <R<n>-A<m>>
review_invocation_generation: <ledger generation containing this pending request>
review_request_id: <fresh single-use opaque ID recorded as pending>
base_revision: <resolved immutable full commit object ID>
surface_fingerprint: <current ledger fingerprint>
review_target_digest: <canonical status/diff plus review-item artifact digest>
sanitized_baseline_digest: <synthetic baseline containing only supplied review artifacts>
reviewer_projection_digest: <digest of the exact bounded reviewer projection>
context_discovery_digest: <digest of current complete local discovery receipt>
change_objective: <bounded immutable user change objective artifact>
change_objective_digest: <exact objective artifact digest>
applicable_instructions: <ordered scoped protected pre-loop authority artifacts>
applicable_instructions_digest: <canonical precedence/scope/content digest>
surface_entries: <IDs, paths, lifecycle, kind/modes, content/patch digests, origins,
  and read-only review-artifact locators>
adjacent_contracts: <IDs, paths, reasons, content digests, and artifact locators>
public_location_map: <item ID/digest, public synthetic file, allowed line ranges,
  evidence references, and line-map digest>
existing_findings: <IDs, open/fixed/verified/closed state, one-line invariants, and class slugs>
non_closed_finding_ids: <exact IDs requiring dispositions>
closed_finding_ids: <exact IDs available for recurrence reuse but not dispositions>
next_finding_sequence: <next unused M for round N>
known_fix_attempts: <fix_attempt_id values and exact attempt-delta
  lifecycle/mode/type/path/patch evidence digests>
failure_class_registry: <stable slugs, canonical invariants, occurrence IDs, and
  preflight check IDs/digests or NOT_APPLICABLE>
failure_class_registry_digest: <canonical digest of the complete registry>
next_failure_class_sequence: <next unused K for stable slug fc-K>
```

This is a sanitized projection produced only after local label/path/type, binary,
hardlink, and no-log content classification. Likely-secret paths and artifact locators become
redacted opaque entries containing only `review_item_id`, `redacted_token`,
lifecycle, and non-sensitive digests. Never send their names, locators, or content to
`/codex:adversarial-review`; they must remain `unread` unless an explicitly authorized
local-only reviewer receives the private artifact.

Apply that same sensitivity boundary to the objective/instruction artifacts. The
reviewer assesses the supplied surface against them and may not redefine their scope or
precedence. Both artifacts and their digests are covered by
`reviewer_projection_digest`; an opaque change contract requires the local-only route.

Do not invoke `/codex:adversarial-review` when any review item is opaque. Route the
whole receipt to an explicitly authorized local-only reviewer, or return `INPUT_ERROR`;
the command's automatic diff collection would bypass focus-text redaction.

Require the reviewer to validate each artifact digest and read each present entry, or
the deletion/rename patch plus its prior blob for non-present entries. Mode and
file-kind transitions are review material even when content is unchanged. For a
symlink, inspect only the inert link-object artifact and raw target text; never
dereference it. For a submodule/gitlink, inspect only its commit OID and patch; never
traverse or initialize it. It must
return `reviewed_full`,
`reviewed_partial`, and `unread` by `review_item_id` for both surface entries and
adjacent contracts. It must reuse a matching stable
finding ID or mark a new one `[NEW]`, and cite file/hunk/contract evidence.
For every finding it must reuse the registry slug whose invariant matches, or emit the
exact marker `[NEW_CLASS]` plus a new canonical invariant. Renaming a matching class is
invalid; a new class marker is not permission to bypass an installed preflight.

## Codex command compatibility

`/codex:adversarial-review` has a fixed public result with `verdict`, `summary`,
`findings`, and `next_steps`. It cannot add top-level ledger fields. When using it,
include the invocation envelope in the focus text and require `summary` to start with
this single-line embedded envelope:

```text
REVIEW_RECEIPT_V1 review_round=R<N>; reviewed_after_attempt=<loop_start|R<n>-A<m>>; review_invocation_generation=<value>; review_request_id=<value>; base_revision=<value>; surface_fingerprint=<value>; sanitized_baseline_digest=<value>; review_target_digest=<value>; reviewer_projection_digest=<value>; context_discovery_digest=<value>; change_objective_digest=<value>; applicable_instructions_digest=<value>; reviewed_full=[item IDs]; reviewed_partial=[item IDs]; unread=[item IDs]; dispositions=[finding ID:resolved|still_open|not_assessed]; remaining_risk=[existing finding IDs or NEW#k]
```

Never expose the actual checkout, Git object database, or unrelated base-tree files to
the public command. Build a disposable synthetic Git repository whose baseline and
worktree contain only supplied ordinary review-item, adjacent, and change-contract
artifacts, bound by
`sanitized_baseline_digest` to their actual-base digests. Replace every symlink and
gitlink with inert metadata containing kind, mode, raw link text or OID, and patch
digest. Validate the sanitized status/diff and item artifacts against
`review_target_digest`, then pass `--scope working-tree`; `--base` would omit dirty fixes.

Run the public reviewer behind an OS-enforced data-read allowlist containing only the
synthetic repository and supplied artifacts; deny direct network and broker only the
model transport. Scrub inherited environment variables and use isolated HOME/temp,
disabled system/global Git config and credentials, an empty hooks path, no init
templates, and deterministic dummy author/committer metadata. The reviewer runtime may
read only its immutable executables/libraries in addition to the allowlisted data. If
this confinement is unavailable, do not invoke the public command; use an authorized
local-only reviewer or return `INPUT_ERROR`.

Run the command in the foreground with `--wait --json`. Require process exit zero, a
null `parseError`, and an object at `.result`; normalize that object, never the rendered
Markdown. Never accept its rendered output directly. If the installed command rejects
this transport or changes the payload shape, return `INPUT_ERROR` or use a fresh
read-only reviewer that emits the loop receipt directly.

Every public-review and class-adjudication request uses a fresh ID, host-owned finite deadline,
bounded input/result, and cancellation policy. Timeout/overflow consumes and
rejects that ID, kills/reaps the process group or cancels the task, discards late output,
and rejects its parent. Retry requires capped fresh parent/subordinate IDs.

Require each finding title to start with either an existing stable `[R<N>-F<M>]` ID or
the exact marker `[NEW]`. Existing IDs in the invocation envelope must be reused for the
same invariant, including a recurrence of a closed finding. In original
`.result.findings` order, mechanically replace each `[NEW]`
with the next unused round-local sequence in a provisional normalization transaction.
In `remaining_risk`, `NEW#1`, `NEW#2`, and so on refer to new findings in their original
result order. Require exact, gap-free correspondence, then rewrite those tokens to the
same allocated stable IDs. Existing still-open/not-assessed IDs and every new finding
must appear; resolved IDs must not.
Require each finding body to start with this JSON metadata line:

```text
REVIEW_FINDING_V1 {"materiality":"material","finding_invariant":"canonical specific defect invariant","detection_review_item_id":"ID","detection_review_item_digest":"digest","detection_evidence_ref":"mapped hunk/line evidence","introduced_by":"original|R-n-A-m|unknown","introduction_evidence":"entry ID:lifecycle/mode/type/path/patch evidence digest|unknown","parent":"stable ID|null","failure_class":"existing slug|[NEW_CLASS]","failure_class_invariant":"canonical class invariant","affected_contracts":["IDs"]}
```

The public result's `.file`, `line_start`, and `line_end` plus the detection fields must
resolve exactly through the orchestrator-owned `public_location_map`. Ordinary present
blobs map synthetic lines to the supplied blob/hunk. Deleted, renamed, symlink, and
gitlink items map lines in synthetic inert prior-blob/patch/metadata artifacts; those
coordinates never authorize an actual-tree path by inference. Every affected contract
must be supplied and evidence-bound. An existing finding ID requires its exact
canonical finding invariant; otherwise use `[NEW]` or fail validation.

An introduced `fix_attempt_id` must be present in `known_fix_attempts` with matching
attempt-delta evidence; otherwise `introduced_by` is `unknown`. Normalize findings in original
order and maintain an effective registry containing both stored and earlier
provisionally accepted classes. Existing classes carry their exact registry invariant.
Whenever that effective registry is non-empty, pause every finding's normalization and
give a separate fresh read-only class adjudicator the finding candidate, its digest,
and the complete registry. This applies whether the reviewer claimed an existing slug
or `[NEW_CLASS]`; require this bound result:

```text
CLASS_DECISION_V1 {"class_adjudication_request_id":"...","review_request_id":"...","finding_candidate_digest":"...","effective_failure_class_registry_digest":"...","decision":"existing slug|NEW","compared_classes":["every effective-registry slug"],"observation":"semantic invariant comparison"}
```

If any source review item is opaque or likely-secret, this adjudicator must be equally
authorized local-only. Otherwise it receives only a sensitivity-safe invariant
projection bound to the private `finding_candidate_digest`; if that projection is not
enough for a semantic decision, return `INPUT_ERROR` rather than disclose the candidate
or guess.

The compared list must cover the effective registry exactly. Its decision must equal
the reviewer-claimed slug or `NEW` for `[NEW_CLASS]`; disagreement rejects the receipt.
`NEW` authorizes the next deterministic `fc-K` allocation and adds that provisional
class before the following finding. Only the first new class may allocate directly
when both stored and provisional registries are empty.
Thus two paraphrased findings in one response cannot silently allocate two classes.
Persist every adjudication with the reviewer receipt. The adapter copies bound
decisions and sets `detected_in` from `review_round`; it never derives lineage or
semantic class equivalence from prose.

After the receipt line, require one JSON record in `summary` for every item claimed
full or partial:

```text
REVIEW_EVIDENCE_V1 {"review_item_id":"E1","review_item_digest":"...","evidence_ref":"blob+hunk+mode/contract","observation":"specific invariant or flow inspected"}
```

An inferred unchanged collaborator absent from the invocation is not silently omitted
or assigned an ID by the reviewer. Emit this ordered proposal without claiming it read:

```text
ADJACENT_PROPOSAL_V1 {"adjacent_local_id":"ADJ#1","proposed_normalized_path":"relative/path","reason":"producer/consumer/schema/lifecycle invariant","source_review_item_ids":["E1"],"check_kind":"executable|evidence-bound-manual","check_invariant":"exact behavior to verify","check_ref_kind":"repository_target|source_evidence","check_ref":"normalized target or supplied item:evidence ref"}
```

The orchestrator resolves `check_ref` only through repository tooling or already
validated review evidence, then creates and digests the protected check artifact during
local expansion. Never accept an absolute/arbitrary locator or reviewer-supplied command.

The adapter validates unique item IDs, matching complete review-item digests, a concrete evidence
reference, and a non-empty item-specific observation. The summary grammar is exhaustive:
after its first receipt line, it contains exactly the evidence records followed by zero
or more ordered `ADJACENT_PROPOSAL_V1` records and no other summary lines. A receipt
line echoed without required evidence, extra prose, blank records, or an unrecognized
trailing line is not review evidence.

## Validation and mapping

Fail with `INPUT_ERROR` without starting a fixer when any check fails:

1. the embedded envelope is absent, duplicated, malformed, or not the first summary
   line, or the summary contains anything except that line, the exact evidence records,
   and ordered adjacent-proposal records;
2. review round, reviewed-after-attempt, `review_invocation_generation`, pending
   `review_request_id`, base revision, surface fingerprint, sanitized-baseline digest,
   review-target, reviewer-projection, context-discovery, change-objective, or
   applicable-instructions digest differs from the invocation envelope;
3. the three coverage lists do not form an exact, duplicate-free partition of every
   `review_item_id`, including adjacent contracts;
4. a full/partial item lacks exactly one valid `REVIEW_EVIDENCE_V1` record, or a review
   artifact is unavailable/digest-mismatched;
5. an unauthorized reviewer marks a likely-secret opaque entry fully or partially read;
6. a finding lacks a unique known ID or `[NEW]` marker, schema severity,
   `materiality=material`, a reusable registry class or `[NEW_CLASS]`, its canonical
   invariant, or evidence required by its claimed `introduced_by` value; an existing
   ID's `finding_invariant` differs from its exact canonical finding invariant;
7. parent or affected-contract IDs are absent, or finding `.file`/`line_start`/`line_end`,
   detection item ID/digest/evidence ref, or affected-contract evidence fails the
   supplied `public_location_map`;
8. dispositions do not cover exactly every supplied `non_closed_finding_ids` entry once, mark a
   reported finding resolved, or silently treat absence as closure;
9. verdict, finding cardinality, and `remaining_risk` contradict each other;
10. an approval has non-empty `.result.next_steps`, including advice that implies
    unresolved work or risk;
11. any finding against a non-empty effective registry lacks a separately produced
    `CLASS_DECISION_V1`, or its claimed class/marker, request, finding,
    pending/consumed `class_adjudication_request_id`, adjudicator projection,
    effective-registry digest, complete comparison set, or semantic observation does
    not match the bound decision;
12. an adjacent proposal has a duplicate/nonsequential local ID, non-normalized or
    unsafe path, empty reason, source item absent from the invocation, or missing/unbound
    executable/manual check definition or safely resolvable check reference; or its
    normalized path/no-follow identity already exists in the surface/adjacent registry
    or duplicates another proposal after hardlink classification.

When a valid adjacent proposal exists, do not map the response to `FINDINGS` or
`ZERO_FINDINGS`. The orchestrator locally validates and classifies the proposed entry,
allocates its stable adjacent/check state, atomically consumes the request into
`review_request_rejections` with reason `surface_expanded`, and issues a fresh review
over the expanded target. Findings in the rejected response receive no stable IDs.
Existing/duplicate identities are schema `INPUT_ERROR`, never `surface_expanded`.

Map only these combinations:

- `needs-attention` + non-empty `findings` → `FINDINGS`;
- `approve` + empty `findings` + empty `next_steps` + empty `remaining_risk` + complete coverage + every disposition resolved →
`ZERO_FINDINGS`.

Here, complete coverage means every review item is in `reviewed_full`, with
`reviewed_partial` and `unread` empty. Empty `next_steps` means the schema-valid empty
array `[]`; missing, null, strings, or placeholder entries are invalid. Any other
combination is `INPUT_ERROR`.

The adapter may copy deterministic invocation facts and perform the specified `[NEW]`
finding-ID and `[NEW_CLASS]` registry-ID allocations. It may not infer a read, finding,
zero result, provenance, class match, or evidence that the reviewer did not report.

All finding IDs, class IDs, risk rewrites, adjudications, occurrences, and sequence
increments remain provisional until every transport/schema/coverage/class/adjacent and
actual-tree check succeeds. Commit them atomically with the accepted reviewer receipt.
On any rejection—including surface expansion—discard them all; no phantom ID or
sequence advancement may survive.

Accept a response only while its request ID is pending and every later ledger generation
is a contiguous parent-bound subordinate adjudication transition with a valid chain
digest and consumed single-use ID. First safely recapture actual HEAD, canonical status,
every review-item digest, adjacent-contract version, protected objective/authority
artifacts, ordered instruction/spec records, both change-contract digests, `surface_fingerprint`, and
`review_target_digest`; each must match the root and pending request, with no unrelated
dirty entry or newly applicable external binding. An instruction/spec source changed
inside the intended surface remains review output, not adopted authority. Changed
intent requires rebaseline; other drift consumes/rejects the request as `binding`.
Generation equality alone cannot
detect an external tree write. Atomically
consume that ID and append an immutable
entry plus its provisional allocations to `reviewer_receipts` at
`accepted_generation`, exactly the next generation; a
consumed or absent ID is `INPUT_ERROR`. For any invalid response or failed class
adjudication, atomically consume the pending ID instead into
`review_request_rejections` at `rejected_generation`, exactly the next generation, and
return `INPUT_ERROR`; a retry requires a fresh request ID. Later fix attempts validate the stored receipt
ID, accepted request, reviewed-after-attempt value, and fingerprints—not equality with
the now-newer ledger generation.
