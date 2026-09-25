# Pure transition: [persisted cycle or null, request] -> validated next cycle.
include "audit-reconciliation";
include "audit-reflection-contract";
def keys_are($expected_keys): type == "object" and keys == ($expected_keys | sort);
def text: type == "string" and length > 0 and utf8bytelength <= 4096
  and (explode | all(. >= 32 and . != 127));
def identifier: text and test("^[A-Za-z0-9_-]{1,128}$");
def context_ok:
  keys_are(["repo_root","session","epoch","branch","gate"])
  and (.repo_root | text and startswith("/")) and (.session | identifier)
  and (.epoch | identifier) and (.branch | text) and (.gate | IN("verdict","commit","push"));
def input_ok:
  keys_are(["id","binding","snapshot"]) and (.id | identifier)
  and (.binding | type == "object" and length > 0 and (tojson | utf8bytelength <= 4096))
  and (.snapshot | type == "object" and length > 0 and (tojson | utf8bytelength <= 327680));
def outcome_ok:
  (del(.history_review,.reflection_review) | keys_are(["verdict","evidence"]))
  and (.verdict | IN("PASS","FAIL","ERROR","IN_PROGRESS","CANCELED"))
  and (.evidence | type == "string" or type == "object") and (tojson | utf8bytelength <= 65536);
def attempt_ok:
  keys_are(["id","input","outcome","reflection_hash","history_hash"]) and (.input | input_ok) and .id == .input.id
  and (.history_hash | type == "string" and test("^[0-9a-f]{64}$"))
  and (.reflection_hash | type == "string" and test("^([0-9a-f]{64})?$"))
  and (.outcome == null or (.outcome | outcome_ok));
def state_ok:
  keys_are(["version","context","attempts","registry","history_hash","reflection","closed"])
  and .version == 1 and (.context | context_ok) and (.registry | ar_registry)
  and (.reflection | audit_reflection_stored)
  and (.closed | type == "array" and length <= 4 and all(.[]; type == "object"))
  and (.history_hash | type == "string" and test("^[0-9a-f]{64}$"))
  and (.attempts | type == "array" and length <= 16 and all(.[]; attempt_ok))
  and (([.attempts[].id] | unique | length) == (.attempts | length))
  and ([.attempts[] | select(.outcome == null)] | length <= 1)
  and all(.attempts[0:-1][]; .outcome != null and .outcome.verdict != "PASS");

if length != 2 then error("expected one request") else . end |
.[0] as $old | .[1] as $request |
if ($request.context | context_ok | not) then error("invalid cycle context")
elif $old != null and ($old | state_ok | not) then error("invalid history")
elif $old != null and $old.context != $request.context then error("wrong cycle context")
else $old // {version:1,context:$request.context,attempts:[],registry:[],history_hash:"",reflection:null,closed:[]} end |
if $operation == "prepare" then
  if ($request | keys_are(["context","attempt"]) | not) or ($request.attempt | input_ok | not)
  then error("invalid attempt input") else . end |
  [.attempts[] | select(.id == $request.attempt.id)] as $existing |
  if ($existing | length) > 0 then
    if $existing[0].input == $request.attempt then . else error("attempt input changed") end
  elif .attempts[-1].outcome.verdict == "PASS" then
    .closed = ((.closed + [del(.closed)]) | .[-4:]) |
    .attempts = [{id:$request.attempt.id,input:$request.attempt,outcome:null,reflection_hash:"",history_hash:""}] |
    .registry=[] | .reflection=null
  elif any(.attempts[]; .outcome == null) then error("another attempt is active")
  elif (.attempts | length) >= 16
    or ([.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR"))] | length) >= 8
  then error("audit history exhausted; report incomplete verification")
  elif (audit_reflection_ready | not) then error("reflection required before another audit; submit a current evidence-backed reflection")
  else .attempts += [{id:$request.attempt.id,input:$request.attempt,outcome:null,history_hash:"",
    reflection_hash:(if (audit_failure_ids | length) >= 2 then .reflection.hash else "" end)}] end
elif $operation == "record" then
  if ($request | keys_are(["context","id","outcome"]) | not) or ($request.outcome | outcome_ok | not)
  then error("invalid audit outcome") else . end |
  ([.attempts[].id] | index($request.id)) as $index |
  if $index == null then error("unknown attempt")
  elif .attempts[$index].outcome != null and .attempts[$index].outcome != $request.outcome
  then error("attempt outcome changed")
  elif .attempts[$index].outcome == $request.outcome then .
  else
    audit_reflection_assess($request.outcome; .attempts[$index]) |
    if $request.outcome.history_review != null then
      audit_reconcile($request.outcome.history_review; .attempts[$index]; $request.outcome.verdict)
    elif (.registry | length) > 0 and ($request.outcome.verdict | IN("ERROR","CANCELED") | not)
    then error("history review is required for existing findings") else . end |
    .attempts[$index].outcome = $request.outcome
  end
elif $operation == "submit" and ($request | keys_are(["context","reflection"])) then
  audit_reflection_submit($request.reflection)
elif $operation == "status" and ($request | keys_are(["context"])) then .
else error("unknown audit operation") end
