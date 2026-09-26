include "audit-reconciliation";
def audit_failure_ids: [.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR")) | .id];
def audit_reflection_body:
  ar_keys(["history_hash","failure_ids","diagnosis","previous_fixes_failed_because",
    "changed_approach","checks","auditor_gaps"])
  and (.history_hash | type == "string" and test("^[0-9a-f]{64}$"))
  and (.failure_ids | type == "array" and length >= 2 and length <= 8 and all(.[]; ar_text))
  and all(.diagnosis,.previous_fixes_failed_because,.changed_approach; ar_text)
  and (.checks | type == "array" and length > 0 and length <= 8
    and all(.[]; ar_keys(["command","expected","observed","evidence"])
      and all(.command,.expected,.observed,.evidence; ar_text)))
  and (.auditor_gaps | type == "array" and length <= 8
    and all(.[]; ar_keys(["attempt_id","gap","next_check"])
      and all(.attempt_id,.gap,.next_check; ar_text)))
  and (tojson | utf8bytelength <= 8192);
def audit_reflection_stored:
  . == null or (ar_keys(["body","hash"]) and (.body | audit_reflection_body)
    and (.hash | type == "string" and test("^[0-9a-f]{64}$")));
def audit_reflection_ready:
  if (audit_failure_ids | length) < 2 then true
  else .reflection != null and .reflection.body.history_hash == .history_hash end;
def audit_reflection_submit($body):
  if ($body | audit_reflection_body | not) or $body.history_hash != .history_hash
    or ($body.failure_ids | sort) != (audit_failure_ids | sort)
    or any($body.auditor_gaps[]; .attempt_id as $id | ($body.failure_ids | index($id)) == null)
  then error("reflection must cover every current failed attempt with evidence")
  elif any(.attempts[]; .outcome == null) then error("cannot replace reflection during an audit")
  else .reflection={body:$body,hash:""} end;
def audit_reflection_assess($outcome; $attempt):
  if $attempt.reflection_hash == "" or ($outcome.verdict | IN("ERROR","CANCELED")) then .
  elif ($outcome.reflection_review | ar_keys(["reflection_hash","assessment","evidence","auditor_assessment"]) | not)
    or $outcome.reflection_review.reflection_hash != $attempt.reflection_hash
    or ($outcome.reflection_review.assessment | IN("sufficient","insufficient") | not)
    or ($outcome.reflection_review.evidence | ar_text | not)
    or ($outcome.reflection_review.auditor_assessment | ar_text | not)
  then error("missing or stale independent reflection assessment")
  elif $outcome.verdict == "PASS" and $outcome.reflection_review.assessment != "sufficient"
  then error("PASS requires sufficient reflection and verified follow-through")
  else . end;
