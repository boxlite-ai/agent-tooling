# Gate owners persist these transitions under their existing transaction lock.
include "audit-loop";
def recovery_keys($names): type == "object" and keys == ($names | sort);
def recovery_hash: type == "string" and test("\\A[0-9a-f]{64}\\z");
def recovery_task: type == "string" and test("\\A[0-9a-f]{32}\\z");
def recovery_decisions:
  type == "array" and length <= 144 and all(.[];
    recovery_keys(["id","status","evidence"])
    and (.id | type == "string" and length > 0 and utf8bytelength <= 2048)
    and (.status | IN("upheld","retracted"))
    and (.evidence | type == "string" and length > 0 and utf8bytelength <= 2048
      and (test("[[:cntrl:]]") | not)))
  and ([.[].id] | length == (unique | length));
def recovery_texts:
  type == "array" and length > 0 and length <= 50 and all(.[];
    type == "string" and length > 0 and utf8bytelength <= 2048 and (test("[[:cntrl:]]") | not));
def recovery_shrink_result:
  recovery_keys(["candidate_sha256","removed_scope","affected_sections","preserved_requirements","findings"])
  and (.candidate_sha256 | recovery_hash)
  and all(.preserved_requirements,.findings; recovery_texts)
  and all(.removed_scope,.affected_sections; . == [] or recovery_texts)
  and ([.findings[]] | length == (unique | length));
def recovery_reservation($kind):
  (del(.worker_provenance,.original_design) | recovery_keys(["task_id","source_sha256","deadline","round","findings","result"]))
  and (.task_id | recovery_task) and (.source_sha256 | recovery_hash)
  and (.deadline | type == "number" and . > 0 and . == floor)
  and (.round | type == "number" and . >= 0 and . < 16 and . == floor)
  and ([{kind:"FAIL",findings:.findings}] | audit_loop_rounds_valid)
  and (.original_design == null or (.original_design | type == "string" and length <= 32000 and index("\u0000") == null))
  and (.result == null or (if $kind == "referee" then (.result | recovery_decisions)
    and ([.result[].id] | sort) == ([.findings[].id] | sort)
    else (.result | recovery_shrink_result) and (.result.findings | sort) == ([.findings[].id] | sort)
      and (if (.result.removed_scope | length) == 0 then (.result.affected_sections | length) == 0
        else .result.candidate_sha256 != .source_sha256 and (.result.affected_sections | length) > 0 end) end));
def audit_recovery_valid:
  . == null or ((del(.shrink) | recovery_keys(["version","loop_id","referee"]))
    and .version == 1 and (.loop_id | recovery_task)
    and (.referee == null or (.referee | recovery_reservation("referee")))
    and (.shrink == null or (.shrink | recovery_reservation("shrink"))));
def recovery_input:
  recovery_keys(["view","recovery","exhausted"])
  and (.view | audit_loop_view_valid) and (.recovery | audit_recovery_valid)
  and (.exhausted | type == "boolean")
  and (. as $input | all(.recovery.referee,.recovery.shrink;
    . == null or (.round < ($input.view.rounds | length)
      and .findings == $input.view.rounds[.round].findings)));
def recovery_checked:
  if recovery_input then . else error("invalid recovery state") end;

# The ordinary outcomes remain immutable. Retractions affect their copied view.
def audit_recovery_effective_view:
  recovery_checked | .view as $view | .recovery.referee as $referee
  | if $referee.result == null then $view else
      $view | .rounds[$referee.round].findings |= map(. as $finding
        | select(.severity == "critical" or
          (any($referee.result[]; .id == $finding.id and .status == "retracted") | not)))
    end;
def audit_recovery_next($time):
  recovery_checked
  | (audit_recovery_effective_view | audit_loop_classify) as $progress
  | if ($progress.critical_ids | length) > 0 then "critical"
    elif .exhausted then "capped"
    elif ($progress.pattern | IN("stalled","churning") | not) then "none"
    else (if $progress.pattern == "stalled" then "referee" else "shrink" end) as $kind
      | .recovery[$kind] as $used
      | if $used == null then $kind
        elif $used.round == ((.view.rounds | length) - 1)
          and $used.result == null and $used.deadline >= $time then "pending"
        else "stuck" end
    end;
def audit_recovery_reserve($kind; $assignment; $time):
  recovery_checked
  | if ($kind | IN("referee","shrink") | not) or audit_recovery_next($time) != $kind
      or ($assignment | recovery_keys(["task_id","source_sha256","deadline"]) | not)
      or ($assignment.task_id | recovery_task | not)
      or ($assignment.source_sha256 | recovery_hash | not)
      or ($assignment.deadline | type != "number" or . != floor or . <= $time)
    then error("recovery reservation is unavailable or invalid") else . end
  | .recovery //= {version:1,loop_id:$assignment.task_id,referee:null,shrink:null}
  | .recovery[$kind] = ($assignment + {round:((.view.rounds | length) - 1),
      findings:.view.rounds[-1].findings,result:null});
def audit_recovery_finish($kind; $task; $source; $result):
  recovery_checked | .recovery[$kind] as $reservation
  | if $kind != "referee" or $reservation == null or $reservation.result != null
      or $reservation.task_id != $task or $reservation.source_sha256 != $source
      or ($result | recovery_decisions | not)
      or ([$result[].id] | sort) != ([$reservation.findings[].id] | sort)
    then error("stale, duplicate or invalid referee result") else . end
  | .recovery.referee.result = ($result | map(
      if .status == "retracted" and (.evidence | test("[^[:space:]]:[1-9][0-9]*|tool output:"))
      then . else .status="upheld" end));
def audit_recovery_shrink_finish($task; $source; $result):
  recovery_checked | .recovery.shrink as $reservation
  | if $reservation == null or $reservation.result != null
      or $reservation.task_id != $task or $reservation.source_sha256 != $source
      or ($result | recovery_shrink_result | not)
      or (if ($result.removed_scope | length) == 0 then ($result.affected_sections | length) != 0
          else $result.candidate_sha256 == $source or ($result.affected_sections | length) == 0 end)
      or ($result.findings | sort) != ([$reservation.findings[].id] | sort)
    then error("stale, duplicate or invalid shrink completion") else . end
  | .recovery.shrink.result=$result;
