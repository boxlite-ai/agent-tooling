# Design-loop state bound to root and branch. PASS and OVERRIDDEN close a cycle;
# automatic Redesign preserves consumed recovery actions and the failure budget.
include "audit-reflection-contract";
include "audit-reconciliation";
include "audit-loop";
include "audit-recovery";
def da_keys: ["advisories","branch","content_sha256","extra","failures","findings",
  "overruled","reflection","root","stop","url","verdict"];
def da_line: type == "string" and length >= 1 and length <= 500 and (test("[[:cntrl:]]") | not);
def da_lines: type == "array" and length <= 50 and all(.[]; da_line);
def da_empty($root; $branch):
  {root:$root, branch:$branch, url:"", content_sha256:"", verdict:"NONE", findings:[],
   advisories:[], failures:[], stop:"none", extra:false, reflection:null, overruled:[]};
# Discard a verdict that cannot authorize work while keeping human overrules.
def da_reset($root; $branch): . as $old | da_empty($root; $branch) | .overruled = $old.overruled;
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
  (del(.deadline_review,.worker_provenance,.progress,.recovery_state) | keys) == da_keys
  and (.progress == null or (.progress | audit_loop_view_valid))
  and (.recovery_state | audit_recovery_valid)
  and (.recovery_state.shrink == null or (.recovery_state.shrink.original_design | type == "string" and length > 0))
  and (.recovery_state.referee as $referee | $referee.result == null or
    ({content_sha256:$referee.worker_provenance.content_sha256,
      worker_provenance:$referee.worker_provenance} | da_worker_provenance("referee"))
    and $referee.worker_provenance.task_id == $referee.task_id
    and $referee.worker_provenance.snapshot_sha256 == $referee.source_sha256)
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
# Another root or branch starts fresh; a malformed record for this one fails closed.
def da_state($root; $branch):
  if type == "object" and .root == $root and .branch == $branch then
    if da_valid then . else error("research state is malformed") end
  else da_empty($root; $branch) end;
def da_recovery_input:
  {view:(if .recovery_state != null and .progress != null then .progress else audit_loop_design_view end),recovery:.recovery_state,
    exhausted:(.stop == "cap" or (.failures | length) >= 8)};
def da_recovery_action:
  if .verdict == "FAIL" then da_recovery_input | audit_recovery_next(now | floor) else "none" end;
def da_effective_progress: da_recovery_input | audit_recovery_effective_view;
def da_open_findings:
  if (.verdict | IN("FAIL","NONE")) and .recovery_state != null
    then da_effective_progress | .rounds[-1].findings | map(.id)
  elif .verdict == "FAIL" then .findings else [] end;
def da_blocked:
  .stop != "none" and (.extra | not)
  and (da_recovery_action | IN("referee","shrink") | not)
  and (.stop != "early" or (da_effective_progress | audit_loop_classify | .pattern != "converging"));
def da_reflection_due:
  .verdict == "FAIL" and .reflection == null
  and (((da_blocked | not) and da_recovery_action == "none" and (.failures | length) >= 2) or .extra);
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
   prior_findings:(if .url == $url then da_open_findings
     + (.overruled | map("overruled: " + .)) else [] end),
   findings:(if .verdict == "FAIL" and .url == $url and .content_sha256 == $digest
     then .findings else [] end),
   open_findings:da_open_findings,
   fails:(.failures | length), stop, blocked:da_blocked, reflection_due:da_reflection_due,
   recovery:(da_effective_progress | audit_loop_classify),
   recovery_action:(if $live then da_recovery_action else "none" end),
   shrink_pending:(.recovery_state.shrink != null and .recovery_state.shrink.result == null),
   redesign:da_redesign($digest), history_hash:$history, failure_ids:.failures};
# Ordinary reviews retain original progress; recovery decisions affect a copied view.
def da_record($v; $url; $digest):
  if da_blocked then error("the research loop stopped for the human; their decision comes first")
  elif da_reflection_due then error("submit the reflection before this audit: design-doc.sh reflect")
  elif da_redesign($digest) then error("Redesign needs a fresh draft; this content already failed")
  else
    (audit_loop_design_record($v.verdict; $v.findings)) as $progress
    | del(.worker_provenance)
    | (if .verdict == "FAIL" or .recovery_state != null then .failures else [] end) as $failures
    | (if .url == $url then .overruled else [] end) as $overruled
    | if $v.verdict == "PASS" then .verdict = "PASS" | .findings = [] | .failures = [] | .stop = "none"
        | .recovery_state=null
      else ($failures + ["\($failures | length + 1):\($digest)"]) as $next
        | .verdict = "FAIL" | .findings = $v.findings | .failures = $next
        | .stop = (if .extra or ($next | length) >= 8 then "cap"
            elif ($next | length) >= 2 and
              ({view:$progress,recovery:.recovery_state,exhausted:false}
                | audit_recovery_effective_view | audit_loop_classify | .pattern != "converging")
            then "early" else "none" end)
      end
    | .url = $url | .content_sha256 = $digest | .advisories = $v.advisories
    | .overruled = $overruled | .extra = false | .reflection = null | .progress=$progress
    | del(.deadline_review) | if $v.deadline_review != null then . + {deadline_review:$v.deadline_review} else . end
  end;
def da_recovery_reserve($kind; $assignment):
  (da_recovery_input | audit_recovery_reserve($kind; $assignment; now | floor)) as $reserved
  | .recovery_state=$reserved.recovery;
def da_referee_record($task; $source; $result; $proof):
  (da_recovery_input | audit_recovery_finish("referee"; $task; $source; $result)) as $completed
  | .recovery_state=$completed.recovery | .reflection=null
  | .recovery_state.referee.worker_provenance=$proof
  | if da_valid then . else error("invalid referee provenance") end;
def da_shrink_reserve($assignment; $original):
  da_recovery_reserve("shrink"; $assignment)
  | .recovery_state.shrink.original_design=$original
  | .verdict="NONE" | .stop="none" | .extra=false | .reflection=null;
def da_shrink_finish($task; $source; $result):
  (da_recovery_input | audit_recovery_shrink_finish($task; $source; $result)) as $completed
  | .recovery_state=$completed.recovery
  | if ($result.removed_scope | length) == 0 then .verdict="FAIL" | .stop="early" else . end;
def da_reflect($body; $history):
  if (da_reflection_due | not) then error("no reflection is due")
  elif ($body | audit_reflection_body | not) or $body.history_hash != $history
    or ($body.failure_ids | sort) != (.failures | sort)
  then error("the reflection must follow audit-reflection-contract.jq and bind this history_hash and every FAIL id")
  else .reflection = $body end;
def da_decide($choice; $url; $digest):
  if (da_blocked | not) then error("no research decision is pending")
  elif $choice == "Overrule" then
    .overruled = ((if .url == $url then .overruled else [] end) + da_open_findings | unique | .[:50])
    | .verdict = "OVERRIDDEN" | .findings = [] | .failures = [] | .stop = "none"
    | .extra = false | .reflection = null | .url = $url | .content_sha256 = $digest
    | .recovery_state=null
    | del(.deadline_review,.worker_provenance)
  elif $choice == "Reflect again" then .extra = true | .reflection = null
  elif $choice == "Redesign" then
    .verdict = "NONE" | .findings = [] | .advisories = []
    | .failures = (if .recovery_state == null then [] else .failures end) | .stop = "none"
    | .extra = false | .reflection = null | .url = $url | .content_sha256 = $digest
    | del(.deadline_review,.worker_provenance)
  else error("unknown research decision") end;
