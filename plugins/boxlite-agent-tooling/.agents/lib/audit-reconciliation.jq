# History reconciliation is evidence bookkeeping; auditors judge evidence quality.
def ar_keys($expected): type == "object" and keys == ($expected | sort);
def ar_text: type == "string" and test("\\S") and utf8bytelength <= 2048;
def ar_id: type == "string" and test("^F[1-9][0-9]{0,3}$");
def ar_finding:
  ar_keys(["id","invariant","behavior","criterion","evidence","origin","origin_evidence",
    "review_gap","review_change","reopening","conflict","criterion_change"])
  and (.id == "NEW" or (.id | ar_id))
  and all(.invariant,.behavior,.criterion,.evidence,.origin_evidence; ar_text)
  and (.origin | IN("existing","introduced","missed_earlier","unknown"))
  and (.review_gap | type == "string") and (.review_change | type == "string")
  and (if .origin == "missed_earlier" then (.review_gap | ar_text) and (.review_change | ar_text) else true end)
  and (.reopening == null or (.reopening | ar_keys(["reason","evidence"])
    and (.reason | ar_text) and (.evidence | ar_text)))
  and (.criterion_change == null or (.criterion_change | ar_keys(["previous","reason","evidence"])
    and all(.previous,.reason,.evidence; ar_text)))
  and (.conflict == null or (.conflict | ar_keys(["previous_id","evidence","check","decision"])
    and (.previous_id | ar_id) and all(.evidence,.check,.decision; ar_text)));
def ar_disposition:
  ar_keys(["id","status","evidence"]) and (.id | ar_id)
  and (.status | IN("open","resolved","retracted","not_assessed")) and (.evidence | ar_text);
def ar_registry:
  type == "array" and length <= 128
  and all(.[]; ar_keys(["id","invariant","behavior","criterion","status","evidence"])
    and (.id | ar_id) and all(.invariant,.behavior,.criterion,.evidence; ar_text)
    and (.status | IN("open","resolved","retracted","not_assessed")))
  and ([.[].id] | length == (unique | length))
  and ([.[] | [.invariant,.behavior]] | length == (unique | length));

def audit_reconcile($review; $attempt; $verdict):
  .registry as $registry |
  if ($review | ar_keys(["history_hash","dispositions","findings","coverage"]) | not)
    or $review.history_hash != .history_hash
    or ($review.dispositions | type != "array" or length > 128 or any(.[]; ar_disposition | not))
    or ($review.findings | type != "array" or length > 32 or any(.[]; ar_finding | not))
    or ($review.coverage | ar_keys(["reviewed","unread"]) | not)
    or ($review.coverage.reviewed | type != "array") or ($review.coverage.unread | type != "array")
  then error("invalid or stale history review") else . end |
  ($review.coverage.reviewed + $review.coverage.unread) as $coverage |
  if ($coverage | sort) != ($attempt.input.snapshot | keys)
    or ($coverage | length) != ($coverage | unique | length)
    or ([$review.dispositions[].id] | sort) != ([$registry[] |
      select(.status == "open" or .status == "not_assessed") | .id] | sort)
  then error("history review omitted or duplicated required coverage/dispositions") else . end |
  if $verdict == "PASS" and (($review.findings | length) > 0
    or ($review.coverage.unread | length) > 0
    or any($review.dispositions[]; .status == "open" or .status == "not_assessed"))
  then error("PASS has unresolved history or unread evidence") else . end |
  .registry |= map(. as $entry |
    ([$review.dispositions[] | select(.id == $entry.id)][0] // null) as $disposition |
    if $disposition == null then . else .status = $disposition.status | .evidence = $disposition.evidence end) |
  reduce $review.findings[] as $finding (.;
    ([.registry[].id] | index($finding.id)) as $index |
    if $finding.id == "NEW" then
      if any(.registry[]; .invariant == $finding.invariant and .behavior == $finding.behavior)
      then error("existing invariant requires its stable finding ID")
      elif $finding.reopening != null or $finding.criterion_change != null
      then error("new finding cannot reopen or redefine another ID")
      elif $finding.origin == "existing" and any(.attempts[]; .outcome != null)
      then error("new finding on rerun must explain its introduction or earlier miss")
      else .registry += [{id:("F" + ((.registry | length) + 1 | tostring)),
        invariant:$finding.invariant,behavior:$finding.behavior,criterion:$finding.criterion,
        status:"open",evidence:$finding.evidence}] end
    elif $index == null then error("unknown finding ID")
    elif .registry[$index].invariant != $finding.invariant or .registry[$index].behavior != $finding.behavior
    then error("finding identity changed")
    elif .registry[$index].criterion != $finding.criterion
      and (.registry[$index].criterion != $finding.criterion_change.previous)
    then error("closure criterion change requires prior criterion and justification")
    elif ([$registry[] | select(.id == $finding.id)][0].status | IN("resolved","retracted")) then
      if $finding.reopening == null then error("reopening requires evidence invalidating prior closure")
      else .registry[$index].status = "open" | .registry[$index].evidence = $finding.evidence end
    elif .registry[$index].status != "open" and .registry[$index].status != "not_assessed"
    then error("finding contradicts its disposition")
    else .registry[$index].evidence = $finding.evidence end |
    if $index != null then .registry[$index].criterion = $finding.criterion else . end |
    if $finding.conflict != null and ([$registry[].id] | index($finding.conflict.previous_id)) == null
    then error("conflicting advice must reference a previous finding") else . end) |
  if (.registry | ar_registry | not) then error("invalid finding registry") else . end;
