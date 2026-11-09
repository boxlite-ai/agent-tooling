# Shared candidate checks; persistence and live authorization remain with callers.
include "audit-reconciliation";
def audit_dossier_normalize_git:
  def exact_keys($wanted): (keys | sort) == ($wanted | sort);
  def bounded_line($bytes):
    type == "string" and length > 0 and utf8bytelength <= $bytes
    and (explode | all(. != 0 and . != 10 and . != 13));
  if length == 1 and (.[0] | type) == "object"
     and (.[0] | del(.history_review,.reflection_review) | exact_keys(["branch", "head",
            "command_kind", "diff_hash", "command_hash", "commit_subject_hash", "verdict",
            "findings", "advisories"]))
     and (.[0].branch | type) == "string"
     and (.[0].branch | utf8bytelength) <= 256
     and (.[0].branch | explode | all(. != 0 and . != 10 and . != 13))
     and (.[0].head | type) == "string"
     and (.[0].head | test("^[0-9a-f]{40}([0-9a-f]{24})?$|^\\?$"))
     and (.[0].command_kind == "commit" or .[0].command_kind == "push")
     and (.[0].diff_hash | type) == "string"
     and (.[0].diff_hash | test("^[0-9a-f]{64}$"))
     and (.[0].command_hash | type) == "string"
     and (.[0].command_hash | test("^[0-9a-f]{64}$"))
     and (.[0].commit_subject_hash | type) == "string"
     and (.[0].commit_subject_hash | test("^[0-9a-f]{64}$|^$"))
     and (.[0].verdict == "PASS" or .[0].verdict == "FAIL")
     and (.[0].findings | type) == "array" and (.[0].findings | length) <= 32
     and all(.[0].findings[]; bounded_line(1024))
     and (.[0].advisories | type) == "array" and (.[0].advisories | length) <= 32
     and all(.[0].advisories[]; bounded_line(1024))
  then .[0] else empty end;

# Input is the captured state. The same request is recorded by the parent or
# evaluated only in memory by the candidate validator.
def audit_dossier_record_request($payload; $id):
  . as $state |
  (if .context.gate == "verdict" then $payload else
    $payload |
    if .reflection_review == null then del(.reflection_review) else . end
  end) as $dossier |
  .attempts[-1].input.binding as $binding |
  if ($payload | has("deadline_review")) then error("deadline metadata is runtime-owned")
  elif $id == "" or $id != .attempts[-1].id or $dossier.history_review.attempt_id != $id
  then error("history_review.attempt_id does not match the current attempt")
  elif $dossier.verdict == "FAIL" and
    (($dossier.history_review.findings | length) == 0 and
      (any($dossier.history_review.dispositions[]; .status == "open" or .status == "not_assessed") | not))
  then error("FAIL requires a history finding or unresolved disposition")
  else . end |
  [$binding | to_entries[] | select(.value != $dossier[.key]) | .key] as $mismatches |
  if ($mismatches | length) > 0 then error("dossier binding mismatch: " + ($mismatches | tojson)) else . end |
  $state.attempts[-1] as $attempt |
  (now | floor) as $now |
  (if $attempt.outcome != null then $attempt.outcome.deadline_review
   elif ($attempt.input.deadline | ar_timestamp) and $now >= $attempt.input.deadline
   then {deadline:$attempt.input.deadline,recorded_at:$now} else null end) as $deadline |
  $dossier | {context:$state.context,id:$id,outcome:({verdict,evidence:del(.history_review,.reflection_review),
    history_review} + (if has("reflection_review") then {reflection_review} else {} end)
    + (if $deadline != null then {deadline_review:$deadline} else {} end))};
