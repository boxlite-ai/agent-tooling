# Iteration Ledger Contract

The ledger is the cumulative source of truth for one adversarial loop. Serialize it as
a session-local artifact outside the repository and model context. Use a private
directory/file (POSIX `0700`/`0600` or host equivalent), generation counter, content
digest, and temp-file plus atomic replacement. Reload and validate it before every
round. Round summaries are bounded projections, not replacements.

Canonicalize as UTF-8 JSON with sorted object keys and schema-defined array order.
Compute the content hash with `ledger_digest` omitted, then store that value in the
artifact; verification repeats the same omission. Canonicalize the surface fingerprint
by stable item ID and include lifecycle, paths, ordered origins/attempt deltas, kind/mode,
content/patch digests, and adjacent-contract digests.

## Initialization and surface

Bind the review to the code that actually entered the loop:

```text
review_surface(K)
  = lifecycle-aware entries(original change at loop start)
  ∪ lifecycle-aware entries(fix attempt delta 1..K)

review_context(K)
  = unchanged producers, consumers, schemas, lifecycle collaborators, and variants
    identified by local context discovery ∪ fixer REFLECT
```

Record:

```yaml
ledger_artifact:
  schema_version: 1
  generation: <monotonic integer>
  path: <session-private path outside the repository>
  ledger_digest: <digest validated after atomic replacement>
  permissions: private
snapshot_policy:
  max_files: <finite repository/host-policy limit>
  max_bytes: <finite repository/host-policy limit>
  observed_files: <integer>
  observed_bytes: <integer>
projection_policy:
  max_projection_bytes: <finite host/model-policy limit>
  max_projection_entries: <finite host/model-policy limit>
execution_policy:
  timeout_policies: <allowlisted runner class to finite timeout_ms mappings>
  runner_contracts: <runner IDs to immutable termination/exit/signal predicate contracts>
  role_timeout_policies: <reviewer, class-adjudicator, potency-adjudicator, and fixer
    policy IDs with finite deadline_ms and result-byte limits>
  max_timeout_ms: <finite host-policy ceiling>
  max_output_bytes: <finite combined stdout/stderr capture limit>
  sandbox_policies: <OS sandbox IDs with filesystem, network, CPU, memory, file, and process limits>
  termination_grace_ms: <finite process-group cleanup grace>
  max_fix_dispatch_retries: <finite nonnegative host-policy limit>
  max_role_retries: <finite per-role retry limits>
change_contract:
  objective_artifact: <immutable bounded user change objective>
  change_objective_digest: <exact objective digest>
  applicable_instructions:
    - binding_id: <stable ID>
      kind: user | repository-instruction | spec
      source: <conversation or normalized authorized-root-relative locator>
      scope: <exact paths/behavior governed>
      precedence: <resolved order>
      authority_artifact: <protected immutable pre-loop content locator>
      content_digest: <exact bytes digest>
      binding_digest: <canonical complete-record digest>
  applicable_instructions_digest: <canonical ordered set digest>
context_discovery_receipts:
  - discovery_id: <stable append-only ID>
    surface_fingerprint: <exact pre-review surface>
    authoritative_tree_digest: <HEAD, status, and ordinary item digests>
    methods: <repository index, forward/reverse references, schema/event, lifecycle, variants>
    limits: <finite file/byte/query limits>
    discovered_adjacent_ids: <validated stable IDs added before review>
    unread_or_excluded: <opaque IDs and reasons>
    complete: <boolean; false cannot authorize a review>
    context_discovery_digest: <canonical receipt digest>
base_revision: <resolved immutable full commit object ID; comparison only, not restoration>
loop_start_snapshot:
  artifact: <immutable restorable tracked and untracked content>
  snapshot_digest: <digest of that artifact>
  restoration_test: <temporary-copy round-trip result>
pre_round_snapshots:
  - fix_attempt_id: <R<N>-A<M>>
    artifact: <immutable restorable state immediately before that fixer>
    snapshot_digest: <digest of that artifact>
    restoration_test: <temporary-copy round-trip result>
candidate_snapshots:
  - fix_dispatch_id: <single-use dispatch that returned this candidate>
    fix_attempt_id: <matching R<N>-A<M>>
    artifact: <immutable isolated post-candidate state>
    snapshot_digest: <exact candidate state digest>
    candidate_handoff_digest: <fully validated structured handoff digest>
    restoration_test: <temporary-copy round-trip result>
fixed_snapshots:
  - fix_attempt_id: <R<N>-A<M>>
    artifact: <immutable restorable authoritative state after that fix>
    surface_fingerprint: <fingerprint captured with this artifact>
    snapshot_digest: <digest of that artifact>
    restoration_test: <temporary-copy round-trip result>
    captured_by: orchestrator
fix_attempts:
  - fix_attempt_id: <R<N>-A<M>>
    review_round: <R<N>>
    attempt_sequence: <M>
    authorized_by_receipt_id: <FINDINGS reviewer receipt or prior BLOCKED receipt>
    authorization_status: FINDINGS | BLOCKED
    fixer_projection_digest: <canonical digest shared by valid dispatch retries>
    change_objective_digest: <exact immutable objective binding>
    applicable_instructions_digest: <exact immutable scoped-rule binding>
    pre_round_snapshot: <matching append-only snapshot artifact and digest>
    candidate_snapshot: <matching isolated candidate artifact and digest>
    fixed_snapshot: <matching append-only snapshot artifact and digest, after return>
    state: dispatch_pending | dispatch_rejected | candidate_returned | verified | blocked
fix_dispatches:
  - fix_dispatch_id: <fresh single-use opaque ID>
    fix_attempt_id: <exact attempt>
    retry_of_dispatch_id: <prior rejected dispatch ID or null>
    authorization_receipt_id: <receipt consumed by the attempt>
    pre_round_snapshot_digest: <exact immutable digest>
    authoritative_surface_fingerprint: <exact pre-attempt fingerprint>
    fixer_projection_digest: <exact bounded projection digest>
    parent_generation_chain_digest: <issuance plus only bound potency transitions>
    change_objective_digest: <exact immutable objective binding>
    applicable_instructions_digest: <exact immutable scoped-rule binding>
    state: pending | candidate_accepted | rejected
fix_dispatch_rejections:
  - rejection_id: <stable append-only ID>
    fix_dispatch_id: <matching pending dispatch>
    reason_code: crash | timeout | output_limit | potency | malformed | overbroad | binding | sensitivity
    no_authoritative_delta_applied: true
    evidence_digest: <sanitized failure evidence digest>
role_timeout_rejections:
  - rejection_id: <stable append-only ID>
    role: reviewer | class-adjudicator | potency-adjudicator | fixer
    invocation_id: <single-use request/dispatch ID>
    timeout_policy_id: <host-owned finite policy>
    deadline_ms: <resolved finite deadline>
    cancellation: process_group_reaped | task_cancelled
    result_bytes_retained: 0
    terminal_mapping: review_request_rejection | fix_dispatch_rejection
pending_adjudication_requests:
  - adjudication_request_id: <fresh class_adjudication_request_id or potency_request_id>
    role: class-adjudicator | potency-adjudicator
    parent_id: <pending review_request_id or fix_dispatch_id>
    issued_generation: <exact ledger generation>
    parent_generation_chain_digest: <parent chain before this issuance>
    projection_digest: <exact bounded adjudicator input>
    timeout_policy_id: <host-owned finite policy>
    deadline_ms: <resolved finite deadline>
    state: pending
consumed_adjudication_request_ids: []
adjudication_request_rejections:
  - rejection_id: <stable append-only ID>
    adjudication_request_id: <matching pending ID>
    role: class-adjudicator | potency-adjudicator
    parent_id: <matching parent>
    rejected_generation: <exact atomic transition generation>
    reason_code: timeout | output_limit | malformed | binding | sensitivity | rejected
    evidence_digest: <sanitized decisive failure digest>
adjudication_results:
  - adjudication_request_id: <consumed single-use subordinate ID>
    role: class-adjudicator | potency-adjudicator
    parent_id: <still-pending parent request/dispatch>
    accepted_generation: <exact atomic consume generation>
    projection_digest: <matching pending request digest>
    result_digest: <canonical immutable decision digest>
blocked_receipts:
  - receipt_id: <stable append-only ID>
    failed_fix_attempt_id: <R<N>-A<M>>
    failed_phase: <verification phase>
    failed_target_ids: <exact finding, mutant, contract, or preflight IDs>
    surface_fingerprint: <fingerprint of failed candidate>
    change_objective_digest: <exact immutable objective binding>
    applicable_instructions_digest: <exact immutable scoped-rule binding>
    evidence_receipt_ids: <exact failed verification receipts>
    allowed_correction:
      invariant: <smallest evidence-bound correction>
      permitted_existing_entry_ids: <exact stable entry IDs>
      permitted_new_normalized_paths: <exact repository-relative paths or empty>
      permitted_roles: <test, setup, and/or production>
      required_verification_phases: <exact phases to rerun>
consumed_fix_authorization_receipt_ids: []
divergence_evaluations:
  - evaluated_generation: <exact ledger generation evaluated>
    source: pre_dispatch | fixer_proposal
    fix_dispatch_id: <source dispatch for fixer_proposal, else NOT_APPLICABLE>
    proposal_digest: <bound proposal digest or NOT_APPLICABLE>
    reviewer_receipt_id: <current receipt>
    is_diverged: <boolean>
    trigger: consecutive_fix_induced | post_preflight_recurrence | NONE
    evidence_receipt_ids: <exact reviewer receipt IDs>
    finding_ids: <exact material finding IDs>
    introduced_by_attempt_ids: <ordered exact attempt IDs>
    failure_class: <stable slug or NOT_APPLICABLE>
    preflight_id: <installed check ID or NOT_APPLICABLE>
    evidence_digest: <canonical digest of this bounded decision>
surface_fingerprint: <canonical hash of all review items, origins, and attempt deltas>
next_preflight_sequence: <next unused K for stable preflight ID pf-K>
next_mutant_sequence: <next unused K for stable mutant ID mut-K>
mutant_id_mappings:
  - mutant_id: <stable orchestrator-allocated mut-K>
    fix_dispatch_id: <accepted parent dispatch>
    mutant_local_id: <unique MUT#k from that candidate>
    finding_id: <stable finding ID>
    mutant_digest: <exact protected patch digest>
    potency_receipt_id: <matching representative receipt>
surface_entries:
  - surface_entry_id: <stable ID>
    path: <current or last path>
    prior_path: <rename source or null>
    sensitivity: ordinary | likely-secret
    sensitivity_reasons: <user/host label, path, type, binary, local secret scan, or hardlink>
    sensitivity_scan_digest: <scanner policy/version, input digest, and decision; no match text>
    redacted_token: <opaque stable token used outside the private ledger>
    lifecycle: present | deleted | renamed
    origins: <ordered unique list containing original and/or fix_attempt_id values>
    old_kind_mode: <blob/symlink/gitlink and mode, or null>
    new_kind_mode: <blob/symlink/gitlink and mode, or null>
    symlink_target: <raw link text or null; never target contents>
    symlink_class: internal | dangling-internal | escaping | not-a-symlink
    gitlink_oid: <exact commit object ID for a submodule entry, or null>
    hardlink_count: <`st_nlink` value for regular files, else NOT_APPLICABLE>
    content_digest: <current or prior blob digest>
    patch_digest: <content, lifecycle, and mode/type transition digest>
    review_artifact: <read-only path or bounded payload for prior blob and patch>
    review_item_digest: <canonical digest of all identity, lifecycle, mode, content, patch, and artifact fields>
attempt_deltas: <fix_attempt_id to surface-entry IDs>
adjacent_contracts:
  - adjacent_contract_id: <stable ID>
    path: <path in review snapshot>
    sensitivity: ordinary | likely-secret
    sensitivity_reasons: <same local classification inputs as a surface entry>
    sensitivity_scan_digest: <no-log decision digest>
    redacted_token: <opaque stable token>
    kind_mode: <blob/symlink/gitlink and mode>
    symlink_target: <raw link text or null; never target contents>
    symlink_class: internal | dangling-internal | escaping | not-a-symlink
    gitlink_oid: <exact commit object ID or null>
    hardlink_count: <`st_nlink` value or NOT_APPLICABLE>
    reason: <producer/consumer/schema/lifecycle invariant>
    content_digest: <reviewed content digest>
    review_artifact: <read-only locator or bounded payload>
    review_item_digest: <canonical digest of ID, reason, content, artifact, and check fields>
    check_kind: executable | evidence-bound-manual
    check_id: <stable adjacent-check ID>
    check_artifact: <test definition or manual invariant/evidence definition>
    check_digest: <check definition and assertion/invariant digest>
```

Every reviewer, class-adjudicator, potency-adjudicator, and fixer invocation uses a
fresh single-use ID, host-owned finite deadline, bounded input/result, and explicit
cancellation. Before a class/potency dispatch, atomically append its pending request
with parent, generation, projection, and deadline. Acceptance atomically consumes it
with the bound decision/receipt and `adjudication_results`; rejection or timeout consumes it into
`adjudication_request_rejections` and rejects the parent review request/fix dispatch in
the same transition. Never retry a subordinate under the same parent; retry requires a
fresh parent and subordinate ID within the parent's finite cap. Replays and late results
are `INPUT_ERROR`. On
timeout or output overflow, discard late output, cancel the task or
terminate/reap its process group, atomically consume/reject the request or dispatch,
and append `role_timeout_rejections`. Exhaustion is `INPUT_ERROR`.
An adjudication result is usable only by its still-pending parent and exact chain; parent
rejection leaves it immutable but orphaned and never reusable.

Resolve any branch/ref to the full commit object ID at loop start. Never store a moving
name such as `main`; abort with `INPUT_ERROR` if the review checkout's comparison OID
or HEAD changes during the loop.

Freeze the exact user objective plus every applicable instruction/spec artifact before
review. Resolve repository scope and precedence from the authorized root; record exact
content, locators, and digests. Include the bounded authority artifacts and both
digests in reviewer and fixer projections/receipts. Revalidate the protected authority
snapshot—not a deliberately edited source file—before each dispatch/review. Drift,
unresolved precedence, truncation, or conflict is `INPUT_ERROR`.
Candidate intake rejects paths or behavior outside this immutable change contract;
neither agent may broaden or reinterpret it. An instruction/spec source intentionally
changed in the review surface is reviewed as output but does not become loop authority.
External authority drift or a newly applicable external binding requires `INPUT_ERROR`;
adopting proposed authority or changed user intent requires explicit rebaseline. Apply
the same no-log sensitivity and projection boundary as review artifacts.

Before capture or any projection, enumerate changed tracked and untracked entries
without logging contents. Combine user/host sensitivity labels, path/type policy, and a
local no-log content scan. Ambiguous encodings, unclassified binaries, high-risk secret
patterns, or unavailable required scanning classify the item `likely-secret`; record
only decision metadata/digests, never matched text. Reject special files, insufficient free space, absent finite limits, or a
file/byte total over policy. Likely-secret paths stay out of prompts and logs, and their
contents may enter only protected local snapshot storage. If private bounded capture
is unavailable, return `INPUT_ERROR` before a fixer starts.

At loop start and after every authoritative-tree change, inspect entry identity with
`lstat` and symlink text with `readlink`; never dereference a symlink during capture,
review, restoration validation, or candidate intake. Resolve its target lexically from
the link's parent only to classify it. Absolute or repository-escaping targets become
`escaping`, likely-secret review items and may be handled only through inert link-object
artifacts by explicitly authorized local-only agents; otherwise return `INPUT_ERROR`.
Snapshots restore the link object, never copy or hash the target's contents.

For regular files, record `st_nlink`. A multiply linked inode is `likely-secret` unless
the host proves every link is inside the authorized root and ordinary. Never edit a
hardlink in place; candidate application uses a new-file atomic replacement so no
outside alias is mutated.

Treat every submodule/gitlink as an inert commit-OID artifact. Never traverse,
initialize, or read a populated submodule worktree during this loop. A dirty submodule
worktree is `INPUT_ERROR` unless explicitly declared as a separate bounded review root
with its own authorization, ledger, and snapshot. The superproject review inspects only
the gitlink OID and patch.

The private ledger may retain a likely-secret path and locator, but every non-local or
unauthorized projection replaces them with `redacted_token` and omits content. Such an
entry remains `unread` until an explicitly authorized local-only reviewer validates the
private artifact; without that review, zero findings is impossible.

The snapshot must actually restore changed tracked files, modes/types, symlink objects, and
untracked contents; a path list or fingerprint alone is insufficient. Preserve it in
the same private session storage and prove a round trip in a temporary copy before any
fixer edit. Record whether artifacts were retained or cleaned; clean them under host
retention policy only after a terminal handoff, never while verification may rerun.

Before dispatch, round-trip the append-only pre-attempt snapshot and materialize an
isolated candidate copy from it. The fixer edits only that copy, never the authoritative
tree. Confine its filesystem/process access to the candidate and approved tooling;
surface symlinks/gitlinks are inert artifacts, and no link can escape the sandbox.
After return, validate the full candidate/handoff before authoritative CAS: binding,
complete lifecycle delta, proposed identities/adjacent/preflight records, every required
accumulated phase recipe, stable/local references, runner/argv/timeout allowlists,
artifact digests, and objective/instruction scope. Blob bytes come from the candidate;
inert symlink/gitlink changes require structured fields, never metadata-file inference.
Build and round-trip an isolated `candidate_snapshots` artifact after provisional ID
mapping, then obtain every required independent potency decision against its digest.
Any structural, binding, recipe, or potency failure rejects the dispatch and discards
the candidate with no authoritative delta applied.

Only then recapture authoritative preimages and apply the validated delta. Commit
provisional allocations with candidate acceptance, recompute the surface fingerprint,
and round-trip a `fixed_snapshots` entry whose state matches the candidate snapshot.
Once apply succeeds, an independently executed evidence failure produces `BLOCKED`,
not dispatch rejection or rollback. Any later
authoritative-tree write invalidates its use as the current-candidate snapshot and
stales attempt-current receipts bound to it. The immutable artifact remains valid as a
historical red snapshot, with finding-red receipts governed by their own bound digests.

Snapshot, fix-attempt, and BLOCKED-receipt lists are append-only and keyed by
`fix_attempt_id`; never overwrite an older artifact needed to replay a finding. The
first attempt in a review round consumes that round's `FINDINGS` receipt authorization.
Each correction is a new attempt and consumes the immediately preceding evidence-bound
`BLOCKED` receipt. Never use an attempt ID for another candidate lineage or consume its
authorization twice. If a fixer crashes or returns malformed/overbroad output before
any authoritative delta is applied, atomically reject its `fix_dispatch_id`, discard the
candidate copy, and append `fix_dispatch_rejections`. A same-attempt retry gets a fresh
dispatch ID bound through `retry_of_dispatch_id` and is allowed only when authorization,
pre-attempt snapshot, actual authoritative fingerprint, and fixer projection all remain
byte-identical. Otherwise return `INPUT_ERROR` and require a fresh review binding.
Exceeding `max_fix_dispatch_retries` is `INPUT_ERROR`, not another silent retry. Retain
every locator through terminal cleanup.

After accepting a review and before allocating any fix attempt, the orchestrator—not a
fixer—evaluates both divergence rules from the full immutable ledger and appends
`divergence_evaluations`. If true, emit `DIVERGED` without dispatch. If false, bind that
exact evaluation into the fixer projection; omitted prior receipts cannot be
reconstructed from summaries.

If a fixer returns `proposed_divergence_evidence`, validate every referenced receipt,
finding, attempt, class, preflight, and artifact against the full ledger before any
candidate apply. Malformed evidence rejects/discards the dispatch as `INPUT_ERROR`.
Valid evidence appends a `source: fixer_proposal` evaluation; a true result discards the
candidate and emits `DIVERGED`, while a false result permits normal candidate validation.

For a correction, normalize and map its actual candidate delta, then
require every existing entry, proposed new path, role, and verification phase to be a
subset of structured `allowed_correction`. If anything exceeds that scope, discard only
the isolated candidate, return `INPUT_ERROR`, and do not add the delta to the surface.

Before applying a validated candidate, safely recapture authoritative HEAD, status, and
every preimage digest and require an exact pre-attempt match. If user/external work
appeared, leave it untouched and return `INPUT_ERROR`. Apply with expected-preimage
compare-and-swap semantics. On partial failure, revert an entry only if its current
digest still equals the orchestrator-written postimage; never overwrite a foreign edit.
Capture the fixed snapshot only after this safe apply completes.

Before any receipt, resolve every existing stable or candidate-local entry reference
against the pre-attempt surface and validated touched proposals. Rewrite local IDs to
allocated stable IDs; reject unknown, ambiguous, wrong-role, or digest-mismatched
references. Accumulated evidence may keep existing stable IDs even when that entry is
unchanged in the current attempt.

Never rebuild the surface from only the latest summary or fix. Deduplicate identities
while retaining every value in `origins`. A deletion stays reviewable through its prior blob and
deletion patch; a rename keeps both paths and its rename patch. Mode and file-kind
transitions remain reviewable even when content is unchanged. A newly discovered
adjacent contract does not imply it changed; record why it matters separately.

Before every reviewer request, the orchestrator runs a bounded local read-only context
discovery against the actual tree. Trace both forward and reverse references plus
schema/event, serialization, lifecycle, generated, and variant relationships; do not
rely on changed files naming their consumers. Expand to a fixed point within the finite
limits. Validate discovered paths through the
same no-follow/sensitivity boundary and add ordinary adjacent contracts before freezing
the request. Record `context_discovery_receipts`. Truncation, an unsupported required
index/search, or any unexplained unread ordinary source sets `complete: false` and
returns `INPUT_ERROR`; likely-secret results require the authorized local-only route.

Reviewer-discovered adjacent paths are proposals, not coverage. Validate each path and
content locally with the same no-follow/sensitivity boundary. Require its normalized
path and no-follow identity to be absent from the surface/adjacent registry and unique
across proposals after hardlink classification; duplicates are schema `INPUT_ERROR`,
not expansion. Then allocate its stable
`adjacent_contract_id`, and append it before another review. Atomically reject the
pending request with reason `surface_expanded`; do not accept findings or zero against
the old surface. A fresh request must fully review the expansion. Each proposal includes
an executable or evidence-bound-manual check definition; absent/invalid check evidence
rejects the proposal rather than creating an unfixable missing-check state.

A fixer may also propose an unchanged adjacent contract with an artifact-local ID.
Require the same path/no-follow identity novelty across the registry, touched proposal,
and adjacent proposal sets. After validating path, reason, content, and check, allocate the stable ID,
rewrite all local references, add it before the fixed-snapshot fingerprint and
verification, and include it in the next full review. The fixer cannot claim coverage.

Whenever a class has at least two recorded occurrences and no valid installed
preflight, require exactly one `proposed_preflights` entry until installation succeeds.
It contains a unique
`preflight_local_id`, stable class and occurrence finding IDs, kind, exact class
invariant, `check_artifact`, `check_artifact_digest`, and expected touched-item local
IDs. Executable checks bind to a validated candidate test/setup entry; manual checks
bind a protected revision-scoped evidence definition and use `NOT_APPLICABLE` touched
entries. Validate objective/instruction scope, identity, bytes, role, digest, and
references or reject the candidate as `INPUT_ERROR`. Then allocate the next stable
`pf-K`, rewrite the registry and every verification candidate from the local ID to that
stable `check_id`, and only then capture/verify the fixed snapshot. Fixers never
allocate stable preflight IDs.

## Independent reviewer receipt

Only the read-only reviewer may report `FINDINGS` or `ZERO_FINDINGS`. Record request
issuance before invoking it: append a pending request and atomically advance the ledger
to the generation named by `review_invocation_generation`. No surface, tree,
change-contract, or unrelated ledger write may occur before acceptance/rejection. Only
parent-bound subordinate adjudication transitions may advance the generation, and each
must extend `parent_generation_chain_digest` atomically.

```yaml
pending_review_requests:
  - review_request_id: <fresh opaque single-use ID>
    review_round: <R<N>>
    reviewed_after_attempt: loop_start | <R<n>-A<m>>
    review_invocation_generation: <generation containing this pending request>
    parent_generation_chain_digest: <issuance plus only bound class-adjudication transitions>
    base_revision: <exact value from ledger>
    surface_fingerprint: <exact current value>
    sanitized_baseline_digest: <exact synthetic reviewer baseline digest>
    review_target_digest: <exact sanitized review tree supplied to the reviewer>
    reviewer_projection_digest: <exact bounded reviewer projection digest>
    context_discovery_digest: <current complete discovery receipt digest>
    change_objective_digest: <exact immutable objective digest>
    applicable_instructions_digest: <exact scoped-rule-set digest>
reviewer_receipts:
  - receipt_id: <stable append-only ID>
    status: FINDINGS | ZERO_FINDINGS
    review_round: <exact invocation round>
    reviewed_after_attempt: loop_start | <exact fix_attempt_id>
    review_invocation_generation: <exact pending-request generation>
    review_request_id: <single-use pending ID consumed on acceptance>
    accepted_generation: <current parent-bound generation plus one>
    parent_generation_chain_digest: <complete validated subordinate journal digest>
    base_revision: <exact value from ledger>
    surface_fingerprint: <exact reviewed value>
    sanitized_baseline_digest: <exact supplied synthetic baseline digest>
    review_target_digest: <exact sanitized review tree supplied to the reviewer>
    reviewer_projection_digest: <exact reviewer projection supplied for this receipt>
    context_discovery_digest: <exact supplied discovery receipt digest>
    change_objective_digest: <exact supplied objective digest>
    applicable_instructions_digest: <exact supplied scoped-rule-set digest>
    reviewed_full: []
    reviewed_partial: []
    unread: []
    dispositions: <every supplied non-closed finding ID mapped to resolved, still_open, or not_assessed>
    remaining_risk: <exact open risk IDs; empty for ZERO_FINDINGS>
    next_steps: <normalized public result; empty for ZERO_FINDINGS>
    findings: []
    class_decision_receipts:
      - class_adjudication_request_id: <consumed pending subordinate ID>
        review_request_id: <matching parent request>
        adjudicator_projection_digest: <exact pending-request projection digest>
        finding_candidate_digest: <exact proposed finding digest>
        effective_failure_class_registry_digest: <registry plus earlier provisional classes>
        decision: <existing slug or NEW>
        compared_classes: <exact complete effective-registry slug set>
        observation: <semantic invariant comparison by a separate read-only adjudicator>
    reviewer_evidence:
      - review_item_id: <surface entry or adjacent contract ID>
        review_item_digest: <matching canonical digest of every required artifact>
        evidence_ref: <blob, hunk, mode/type, or contract reference>
        observation: <specific invariant or flow inspected>
review_request_rejections:
  - rejection_id: <stable append-only ID>
    review_request_id: <matching pending request>
    review_invocation_generation: <exact pending-request generation>
    rejected_generation: <current parent-bound generation plus one>
    reason_code: schema | transport | timeout | output_limit | coverage | class | sensitivity | binding | surface_expanded
    expanded_adjacent_ids: <allocated IDs for surface_expanded, else empty>
    expansion_digest: <canonical allocated adjacent records digest or NOT_APPLICABLE>
    evidence_digest: <digest of sanitized decisive failure evidence>
consumed_review_request_ids: []
```

Accept only while the request remains pending and every generation after
`review_invocation_generation` belongs to its contiguous, digest-valid subordinate
class-adjudication chain; all subordinate IDs must be consumed exactly once.
Immediately before either acceptance or terminal
`COMPLETE`, safely recapture actual HEAD, canonical status, entry/item digests, adjacent
contract versions, the protected objective/authority artifacts and complete ordered
instruction/spec records,
both change-contract digests, `surface_fingerprint`, and `review_target_digest`; require
exact equality with the pending or accepted binding and reject unrelated dirty entries.
New external bindings require a fresh request/rebaseline; instruction/spec source files
in the intended surface remain review output, not adopted authority. Changed intent
requires rebaseline. An
external tree write does not need to advance the ledger, so generation equality alone
is insufficient. In one atomic replacement, remove the request from pending,
append its ID to `consumed_review_request_ids`, append the immutable receipt, and set
`accepted_generation` to the new generation. Finding/class allocations and sequence
increments commit in that same write only after all checks; rejection discards them.
On invalid transport, receipt, or class
adjudication, perform the same atomic pending removal and consumption but append a
`review_request_rejections` entry at `rejected_generation`; then return `INPUT_ERROR`.
Retry only with a fresh request ID at the new generation. Replays are `INPUT_ERROR`. A fixer later
validates the stored `receipt_id`, consumed request ID, reviewed surface, and projection
digests; it does not compare the receipt to the ledger's now-newer current generation.

Coverage lists contain every `review_item_id`: surface entries and adjacent contracts,
not bare paths. Every full/partial claim requires exactly one structured evidence item
bound to its complete `review_item_digest`. Reviewing a deleted or renamed entry requires its patch
and prior blob; it need not exist on disk.
Missing/malformed receipt fields or a base/surface mismatch produce `INPUT_ERROR`.
`ZERO_FINDINGS` is valid only when every review item is in `reviewed_full`,
`reviewed_partial`, `unread`, findings, remaining risk, and public-command `next_steps`
are explicitly empty. An empty prompt section, missing payload, or inherited earlier
read never means zero.

## Finding lineage

Give every finding a stable ID that survives later rounds:

```yaml
finding_id: R2-F1
finding_invariant: <canonical specific defect invariant, immutable for this ID>
state: open | fixed | verified | closed
severity: critical | high | medium | low
materiality: material
detected_in: R2
introduced_by: original | <fix_attempt_id> | unknown
introduction_evidence: <revision-bound lifecycle/mode/type/path/patch evidence, or unknown>
parent_finding: <stable ID or null>
failure_class: <stable registry slug>
affected_contracts: []
detection_review_item_id: <supplied surface/adjacent ID>
detection_review_item_digest: <matching complete item digest>
detection_evidence_ref: <public-location-map-bound hunk/line evidence>
preflight_id: <stable class-registry check ID or NOT_APPLICABLE>
reproducer_id: <stable test/symbol ID>
reproducer_artifact: <protected immutable test-only patch locator>
reproducer_digest: <test patch and exact assertion digest>
reproducer_expected_touched_entries: <test/setup entry IDs only>
red_snapshot_attempt_id: loop_start | <fix_attempt_id whose fixed snapshot exhibits the defect>
red_snapshot_artifact: <protected immutable defect-state snapshot locator>
red_snapshot_digest: <exact immutable defect-state snapshot digest>
compatibility_adapter:
  artifact: <protected test-only patch locator or NOT_APPLICABLE>
  adapter_digest: <patch digest or NOT_APPLICABLE>
  expected_touched_entries: <test/setup entries only>
expected_failure: <defect-specific assertion, hang, panic, or other signal>
representative_mutant:
  mutant_id: <stable ID>
  mutant_artifact: <protected immutable patch locator>
  mutant_digest: <patch digest>
  expected_touched_entries: <exact production surface-entry IDs>
  expected_kill_signal: <defect-specific assertion/signal>
  expected_kill_signal_digest: <exact approved signal/assertion digest>
  potency_receipt_id: <accepted independent potency receipt>
```

Store recurring-class controls once, outside individual findings:

```yaml
failure_class_registry:
  - failure_class: <stable slug>
    invariant: <canonical invariant-level shape>
    occurrences: <ordered stable finding IDs>
    preflight:
      check_id: <stable ID>
      kind: executable | evidence-bound-manual
      artifact: <check definition and positive/negative fixtures>
      check_digest: <artifact digest>
```

A first occurrence allocates its registry slug and uses
`preflight_id: NOT_APPLICABLE`. On the second, install the class-level preflight and
reference its check ID from every later occurrence. Reviewer invocations carry the
registry's slugs, invariants, occurrence IDs, and preflight IDs/digests so a reviewer
must reuse an existing class instead of evading recurrence by renaming it. Against a
non-empty registry, a proposed new class requires a separately bound semantic
`class_decision_receipt`; string inequality alone cannot allocate a new slug.

Detection is not introduction. Attribute `introduced_by` only when revision-bound
lifecycle/mode/type/path/patch evidence establishes it; context or a prior summary is
not provenance. Use `unknown`
instead of guessing.

Only an evidence-backed correctness, security, data, lifecycle, or compatibility defect
that can block shipping is `material`; style, preference, and speculative cleanup are
excluded from reviewer findings. Persist the reviewer's severity and materiality. Only
`material` findings count toward the consecutive fix-induced divergence threshold.

```yaml
mutant_potency_receipts:
  - potency_receipt_id: <stable append-only ID>
    potency_request_id: <consumed fresh single-use request ID>
    fix_attempt_id: <candidate attempt that proposed the mutant>
    finding_id: <stable finding ID>
    finding_invariant_digest: <exact canonical finding-invariant digest>
    detection_evidence_digest: <bound finding location/evidence digest>
    candidate_snapshot_digest: <exact isolated candidate interface contract inspected>
    mutant_local_id: <candidate-local ID bound before parent acceptance>
    mutant_artifact: <protected immutable patch locator>
    mutant_digest: <exact patch digest>
    expected_touched_entries_digest: <canonical mapped entry-set digest>
    expected_kill_signal_digest: <adjudicator-approved exact signal/assertion digest>
    adjudicator_projection_digest: <bounded input digest>
    decision: representative | reject
    observation: <semantic fault recreated or mismatch>
    adjudicated_by: fresh-read-only | authorized-local-only
```

The fixer only proposes a mutant. A fresh read-only potency adjudicator runs before authoritative apply
and compares it with the exact finding invariant, detection evidence, and candidate-snapshot interface
contract. It must confirm the intended semantic fault, not an easier or different
break. Sensitive inputs require the authorized local-only route. Only an immutable
`representative` receipt permits execution or later `KILLED` credit; stale, rejected,
or missing potency evidence is `INPUT_ERROR`.
Candidate mutant IDs are unique artifact-local values. After representative potency,
provisionally allocate `mut-K`, bind it in `mutant_id_mappings`, and rewrite every
recipe before authoritative apply; commit the mapping with parent acceptance. Reject
local/stable collisions, unknown finding/digest bindings, or unmapped references.

## Guarded finding transitions

Only the orchestrator changes finding state:

- `open → fixed`: an exact `fix_attempt_id` consumed a valid `FINDINGS` or corrective
  `BLOCKED` authorization and its attempt delta plus fixed snapshot are recorded;
- `fixed → verified`: a valid finding-level red receipt proves the defect signal, and
  current-attempt receipts prove the fixed pass, every representative mutant killed,
  and adjacent-contract passes;
- `verified → closed`: a later full-surface reviewer receipt on the current fingerprint
  explicitly marks the ID resolved, or a valid `ZERO_FINDINGS` receipt resolves every
  verified ID. Absence is not closure;
- any matching recurrence reopens the stable ID and preserves its prior history.

A change to evidence actually bound by a receipt stales that receipt and demotes
`verified` or `closed` to `fixed` until independently re-proved. Historical red and
attempt-current scopes follow the distinct rules below.

## Reproducer and mutation evidence

For each finding, retain both proofs:

1. **Two-side proof:** capture the reproducer patch before production edits and bind it
   to the finding's immutable `red_snapshot_attempt_id`, artifact, and digest. In an
   isolated disposable copy, restore that exact defect snapshot and apply only that
   test patch plus the recorded compatibility-adapter artifact; validate its
   digest and test/setup-only touched entries first. Never revert the
   original loop-start implementation to `base_revision`. Reach `expected_failure`,
   remove the adapter, then use the fixed snapshot and pass. The adapter may adapt setup
   or invocation for a changed API/signature/schema; it cannot implement the fix, alter
   the check, or become the red signal. An earlier compile/setup failure is `INVALID`
   unless it is the defect.
2. **Potency proof:** validate the independent representative potency receipt, protected
   mutant artifact, digest, and expected touched entries. In a fresh isolated copy, apply
   that exact `representative_mutant`, require the intended failure, then discard it.
   Never apply baseline reverts or mutants to the authoritative working tree. A
   survivor, no coverage, invalid baseline, or weakened assertion blocks verification.
   `KILLED` requires the decisive signal to match the adjudicator-approved
   `expected_kill_signal_digest`; unrelated lint/setup failure is `INVALID` or
   `NO_COVERAGE`. Replace equivalent mutants and re-adjudicate another fault.

Every fix attempt re-runs every accumulated reproducer on its current fixed snapshot
and every representative mutant. A historical `EXPECTED_FAILURE` receipt may be reused
only while its red snapshot, reproducer/assertion, compatibility adapter, and expected
signal digests are unchanged; a corrective attempt's pre-snapshot is not automatically
a red snapshot. Older tests may not inherit a prior `KILLED` or fixed-pass result after
their assertion or covered production path changes.

## Verification receipt

The orchestrator independently re-runs evidence-bearing commands. Store one receipt
per execution phase; never make one exit code prove two trees:

```yaml
verification_receipts:
  - verification_receipt_id: <stable append-only ID>
    phase: reverted | fixed | mutant | adjacent | preflight
    evidence_scope: finding_red | attempt_current
    fix_attempt_id: <exact R<N>-A<M> for attempt_current, else NOT_APPLICABLE>
    produced_during_fix_attempt_id: <attempt that ran this command>
    target_id: <baseline, fixed snapshot, mutant, contract, or preflight ID>
    surface_fingerprint: <exact target red or current surface>
    snapshot_artifact: <protected append-only snapshot locator>
    snapshot_digest: <exact pre-fix or fixed snapshot used by this run>
    finding_id: <stable finding ID or NOT_APPLICABLE>
    adjacent_contract_id: <stable contract ID or NOT_APPLICABLE>
    check_id: <stable preflight/adjacent check ID or NOT_APPLICABLE>
    check_digest: <exact check digest or NOT_APPLICABLE>
    reproducer_id: <stable test/symbol ID or NOT_APPLICABLE>
    reproducer_digest: <test/assertion digest or NOT_APPLICABLE>
    adapter_digest: <exact digest for reverted phase, else NOT_APPLICABLE>
    mutant_digest: <exact mutant digest for mutant phase, else NOT_APPLICABLE>
    potency_receipt_id: <representative receipt for mutant phase, else NOT_APPLICABLE>
    expected_kill_signal_digest: <approved digest for mutant phase, else NOT_APPLICABLE>
    runner_id: <orchestrator-resolved runner/target or NOT_APPLICABLE>
    runner_contract_id: <orchestrator-owned contract ID or NOT_APPLICABLE>
    runner_contract_digest: <exact termination/exit/signal semantics digest or NOT_APPLICABLE>
    timeout_policy_id: <orchestrator-owned finite policy or NOT_APPLICABLE>
    timeout_ms: <resolved finite deadline or NOT_APPLICABLE>
    sandbox_policy_id: <host-owned OS sandbox policy or NOT_APPLICABLE>
    sandbox_attestation_digest: <effective confinement digest or NOT_APPLICABLE>
    argv: <validated argument-token array or NOT_APPLICABLE>
    command_display: <escaped display only or NOT_APPLICABLE; never executed>
    evidence_artifact: <manual-check evidence locator or NOT_APPLICABLE>
    evidence_digest: <manual-check evidence digest or NOT_APPLICABLE>
    expected_termination: exited | timed_out | NOT_APPLICABLE
    expected_exit_code: <integer or NOT_APPLICABLE>
    signal_predicate_id: <repository assertion/check predicate>
    signal_predicate_digest: <exact protected predicate digest>
    expected_result: EXPECTED_FAILURE | PASS | KILLED
    exit_code: <integer or NOT_APPLICABLE>
    duration_ms: <observed monotonic duration or NOT_APPLICABLE>
    termination: exited | timed_out | NOT_APPLICABLE
    process_group_cleanup: completed | NOT_APPLICABLE
    output_artifact: <protected bounded stdout/stderr locator or manual evidence locator>
    output_digest: <exact captured bytes digest>
    output_sensitivity: ordinary | likely-secret
    decisive_signal: <sensitivity-safe projection or opaque token>
    decisive_signal_digest: <projection, source-output, and scanner-policy digest>
    authoritative_recapture_digest: <matching before/after authoritative-state digest>
    result: EXPECTED_FAILURE | PASS | KILLED | SURVIVED | NO_COVERAGE | INVALID | BLOCKED
    verified_by: orchestrator
```

### Phase-result mapping

- `EXPECTED_FAILURE`: reverted phase only; termination/exit matches the runner contract
  and the protected predicate matches the finding's exact defect signal.
- `PASS`: fixed, adjacent, or preflight only; termination/exit and pass predicate all
  match. Printing expected text while teardown exits differently is `INVALID`.
- `KILLED`: mutant only; termination/exit matches and the protected predicate plus
  `expected_kill_signal_digest` match the independent potency receipt.
- A mutant satisfying the fixed-pass contract is `SURVIVED`; an unexecuted assertion is
  `NO_COVERAGE`. Any other phase, exit, timeout, predicate, or digest mismatch is
  `INVALID` and cannot authorize `PASS`, `KILLED`, or `COMPLETE`.

The orchestrator resolves `runner_contract_id` and predicates from protected repository
tooling; fixer free text is never result authority. Predicate evaluation occurs inside
the protected verifier before output redaction and binds its source-output digest.

`reverted` uses `evidence_scope: finding_red` and `fix_attempt_id: NOT_APPLICABLE`; its
`produced_during_fix_attempt_id` is audit provenance, not evidence identity. Only a
change to its bound red snapshot/fingerprint, reproducer/assertion, adapter, or expected
signal stales it; an unrelated later current-surface change does not erase historical
red proof. The other phases use `evidence_scope: attempt_current` and an exact
`fix_attempt_id`. For `fixed`, `mutant`, `adjacent`, and `preflight`, any
relevant current surface, attempt snapshot, reproducer, assertion, adapter, mutant,
check, or manual-evidence digest change stales the receipt. Agent prose and
self-reported counts are not receipts. Only the orchestrator
writes verification receipts; preserve blockers instead of converting them to success.
Fixer candidates are untrusted: resolve runners from repository tooling, validate argv
against an allowlist, and invoke without a shell or interpolation. Treat repository
runners and candidate code as untrusted executables. Run each reverted/fixed/mutant or
executable adjacent/preflight phase in a host-attested OS sandbox over only its
disposable snapshot and immutable tooling: scrubbed environment/credentials, no
authoritative-write access, default-deny network, and finite CPU, memory, file, and
process limits. Recapture authoritative state before and after execution and bind the
matching `authoritative_recapture_digest`; any mismatch can never prove PASS/COMPLETE
and must preserve foreign work rather than overwrite it.
Capture stdout/stderr without logging into protected storage capped by
`max_output_bytes`; overflow before a decisive signal is `INVALID`. Apply the same no-log
classification used for source artifacts to command output, manual evidence, and the
derived decisive signal. Persist only a sensitivity-safe bounded projection plus its
digest; likely-secret evidence uses an opaque token and may be inspected only by an
authorized local-only verifier. Never copy raw protected output into the ledger,
handoff, or agent projection.
Every executable phase uses an orchestrator-owned finite `timeout_policy_id` and runs in
a separately terminable process group. A timeout counts as `EXPECTED_FAILURE` only when
the finding explicitly names that bounded timeout as its defect signal, the configured
deadline elapsed, and the whole process group was terminated and reaped. Any unrelated
timeout or incomplete cleanup is `INVALID` or `BLOCKED`, never a pass.
For an evidence-bound manual adjacent check or preflight, `runner_id`, `argv`, timeout,
termination, exit, runner-contract, sandbox, duration, and process fields are
`NOT_APPLICABLE`; the
orchestrator inspects the current revision-bound artifact and records its digest and
decisive evidence instead of pretending a command ran. Its `command_display` and
`exit_code` are also `NOT_APPLICABLE`; executable phases require those fields and set
manual-evidence fields to `NOT_APPLICABLE`.

## Bounded attempt projection

Keep the full ledger outside the fixer context. A fixer prompt contains the immutable
objective/instruction artifacts and digests, exact authorization receipt, current
surface/adjacent-contract entries, open findings,
one-line closed finding IDs with evidence digests, active preflights, and accumulated
reproducer/mutant IDs plus protected artifact locators and digests. Project
likely-secret entries only as opaque IDs and non-sensitive metadata. Do not paste prior
review receipts, full diffs, or superseded prose summaries.

Serialize and measure each exact role-specific projection before spawning an agent;
compute its canonical digest with its own digest field omitted. Never truncate it. If
it exceeds either finite projection limit, return
`INPUT_ERROR` and propose an invariant-boundary split/rebaseline rather than silently
dropping entries or evidence.

## Divergence and outcomes

Keep reviewer status separate from orchestrator outcome:

- `CANDIDATE`: fixer-only handoff containing an untrusted attempt delta, evidence
  recipes, and possibly a provisional blocker; it is neither a reviewer status nor
  proof that verification passed or failed.
- `INPUT_ERROR`: required review/ledger evidence is missing, malformed, stale, or bound
  to another surface.
- `FINDINGS`: valid review findings are ready for a fix round.
- `ZERO_FINDINGS`: an independent full-surface review explicitly found none; all other
  termination gates must still pass.
- `BLOCKED`: valid evidence shows a reproducer, mutant, adjacent, preflight, snapshot,
  or verification gate failed. Preserve the receipt and return the smallest correction;
  only the orchestrator emits/persists it after independent execution. Do not review
  again or terminate yet.
- `DIVERGED`: two consecutive reviewer receipts found material defects introduced by
  their immediately preceding `fix_attempt_id` values, or a class recurred after its
  preflight. Stop fixing, do not commit, and return
  an invariant-boundary split or rebaseline plan.
- `COMPLETE`: the current `ZERO_FINDINGS` receipt and every independent termination gate
  pass. Only the orchestrator emits this terminal outcome.

## Risk-first handoff

Put truncation-sensitive information first:

1. Status.
2. Remaining risk.
3. Coverage and surface fingerprint.
4. Findings and evidence-bound provenance.
5. Root-cause class and fix delta.
6. Reproducer/mutant results.
7. Independent verification receipts and next action.

Example:

```yaml
finding_id: R3-F1
introduced_by: R2-A2
detected_in: R4
reproducer_id: exact-state-pin
reproducer_digest: <current digest>
representative_mutant: "exact state -> broad /state/ match"
expected_failure: "READY assertion rejects BROKEN"
phase: mutant
result: KILLED
```
