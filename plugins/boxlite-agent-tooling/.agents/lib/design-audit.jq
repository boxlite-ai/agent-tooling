# Design-research loop state: one record per worktree, bound to root and
# branch. A cycle ends with PASS, OVERRIDDEN or Redesign; FAILs count until then.
include "audit-reflection-contract";
include "audit-reconciliation";
include "audit-loop";
def da_keys: ["advisories","branch","content_sha256","extra","failures","findings",
  "overruled","reflection","root","stop","url","verdict"];
def da_line: type == "string" and length >= 1 and length <= 500 and (test("[[:cntrl:]]") | not);
def da_lines: type == "array" and length <= 50 and all(.[]; da_line);
def da_empty($root; $branch):
  {root:$root, branch:$branch, url:"", content_sha256:"", verdict:"NONE", findings:[],
   advisories:[], failures:[], stop:"none", extra:false, reflection:null, overruled:[]};
# Provenance is supplied by the runner that owns the worker's output channel.
def da_worker_provenance($role):
  . as $record | .worker_provenance |
  type == "object" and keys == ["content_sha256","result_sha256","role","snapshot_sha256",
    "task_id","task_sha256","verdict_task_id","version","worker_pid","worker_sha256"]
  and .version == 1 and .role == $role
  and .content_sha256 == $record.content_sha256
  and all(.content_sha256,.result_sha256,.snapshot_sha256,.task_sha256,.worker_sha256;
    type == "string" and test("^[0-9a-f]{64}$"))
  and (.task_id | type == "string" and test("^[0-9a-f]{32}$"))
  and (.worker_pid | type == "number" and . > 0 and . <= 4294967295 and . == floor)
  and (if $role == "auditor" then .verdict_task_id == ""
    else (.verdict_task_id | type == "string" and test("^[0-9a-f]{32}$")) end);
def da_valid:
  (del(.deadline_review,.worker_provenance,.progress) | keys) == da_keys
  and (.progress == null or (.progress | audit_loop_view_valid))
  and (.worker_provenance == null or da_worker_provenance("auditor"))
  and all(.url, .content_sha256; type == "string")
  and (.deadline_review == null or (.deadline_review |
    ar_keys(["deadline","recorded_at"]) and all(.deadline,.recorded_at; ar_timestamp)
    and .recorded_at >= .deadline))
  and (.verdict | IN("NONE","PASS","FAIL","OVERRIDDEN"))
  and all(.findings, .advisories, .overruled; da_lines)
  and (.failures | type == "array" and length <= 64 and all(.[]; type == "string"))
  and (.stop | IN("none","early","cap")) and (.extra | type == "boolean")
  and (.reflection == null or (.reflection | audit_reflection_body));
# A record with only the binding and verdict fields lacks the loop state; it cannot be read.
def da_pre_loop: type == "object" and keys == ["branch","content_sha256","findings","root","url","verdict"];
# Another root or branch starts fresh; a malformed record for this one fails closed.
def da_state($root; $branch):
  if type == "object" and .root == $root and .branch == $branch then
    if da_valid then . else error("research state is malformed") end
  else da_empty($root; $branch) end;
def da_blocked: .stop != "none" and (.extra | not);
def da_reflection_due:
  .verdict == "FAIL" and .reflection == null
  and ((.stop == "none" and (.failures | length) >= 2) or .extra);
def da_redesign($digest): .verdict == "NONE" and .content_sha256 == $digest;
def da_passed($url; $digest):
  .url == $url and .content_sha256 == $digest and (.verdict | IN("PASS","OVERRIDDEN"));
# The verdict an advice record answers: a FAIL's attempt id, or the PASSed
# content. An overrule needs no advice.
def da_verdict_id:
  if .verdict == "FAIL" then (.failures[-1] // "")
  elif .verdict == "PASS" then "PASS:" + .content_sha256 else "" end;
def da_request($root; $url; $digest; $history):
  (.url == $url and .content_sha256 == $digest) as $live
  | {repo_root:$root, design_url:$url, content_sha256:$digest,
   verdict:(if $live then .verdict else "NONE" end),
   verdict_id:(if $live then da_verdict_id else "" end),
   worker_task_id:(.worker_provenance.task_id // ""),
   advisories:(if $live then .advisories else [] end),
   prior_findings:(if .url == $url then (if .verdict == "FAIL" then .findings else [] end)
     + (.overruled | map("overruled: " + .)) else [] end),
   findings:(if .verdict == "FAIL" and .url == $url and .content_sha256 == $digest
     then .findings else [] end),
   open_findings:(if .verdict == "FAIL" then .findings else [] end),
   fails:(.failures | length), stop, blocked:da_blocked, reflection_due:da_reflection_due,
   recovery:(audit_loop_design_view | audit_loop_classify),
   redesign:da_redesign($digest), history_hash:$history, failure_ids:.failures};
# A converging loop continues after each reflection. A FAIL that leaves no fewer blocking
# findings than the one before it stops for the human; so does the eighth FAIL, and any
# FAIL after Reflect again. A finding repeats when its exact line returns.
def da_loop_class($previous; $current):
  [{verdict:"FAIL", count:($previous | length), repeated:false},
   {verdict:"FAIL", count:($current | length), repeated:any($current[]; IN($previous[]))}]
  | audit_loop_class;
def da_record($v; $url; $digest):
  if da_blocked then error("the research loop stopped for the human; their decision comes first")
  elif da_reflection_due then error("submit the reflection before this audit: design-doc.sh reflect")
  elif da_redesign($digest) then error("Redesign needs a fresh draft; this content already failed")
  else
    (audit_loop_design_record($v.verdict; $v.findings)) as $progress
    | del(.worker_provenance)
    | (if .verdict == "FAIL" then .findings else [] end) as $previous
    | (if .verdict == "FAIL" then .failures else [] end) as $failures
    | (if .url == $url then .overruled else [] end) as $overruled
    | if $v.verdict == "PASS" then .verdict = "PASS" | .findings = [] | .failures = [] | .stop = "none"
      else ($failures + ["\($failures | length + 1):\($digest)"]) as $next
        | .verdict = "FAIL" | .findings = $v.findings | .failures = $next
        | .stop = (if .extra or ($next | length) >= 8 then "cap"
            elif ($next | length) >= 2 and da_loop_class($previous; $v.findings) != "converging"
            then "early" else "none" end)
      end
    | .url = $url | .content_sha256 = $digest | .advisories = $v.advisories
    | .overruled = $overruled | .extra = false | .reflection = null | .progress=$progress
    | del(.deadline_review) | if $v.deadline_review != null then . + {deadline_review:$v.deadline_review} else . end
  end;
def da_reflect($body; $history):
  if (da_reflection_due | not) then error("no reflection is due")
  elif ($body | audit_reflection_body | not) or $body.history_hash != $history
    or ($body.failure_ids | sort) != (.failures | sort)
  then error("the reflection must follow audit-reflection-contract.jq and bind this history_hash and every FAIL id")
  else .reflection = $body end;
def da_decide($choice; $url; $digest):
  if (da_blocked | not) then error("no research decision is pending")
  elif $choice == "Overrule" then
    .overruled = ((if .url == $url then .overruled else [] end) + .findings | unique | .[:50])
    | .verdict = "OVERRIDDEN" | .findings = [] | .failures = [] | .stop = "none"
    | .extra = false | .reflection = null | .url = $url | .content_sha256 = $digest
    | del(.deadline_review,.worker_provenance)
  elif $choice == "Reflect again" then .extra = true | .reflection = null
  elif $choice == "Redesign" then
    .verdict = "NONE" | .findings = [] | .advisories = [] | .failures = [] | .stop = "none"
    | .extra = false | .reflection = null | .url = $url | .content_sha256 = $digest
    | del(.deadline_review,.worker_provenance)
  else error("unknown research decision") end;
