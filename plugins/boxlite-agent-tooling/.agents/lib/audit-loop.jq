# Both count-based checkpoints and typed diagnostics use the same progress rule.
def audit_loop_compare_counts($previous; $current; $repeated):
  if $current < $previous then "converging" elif $repeated then "stalled" else "churning" end;

def audit_loop_round:
  type == "object" and (.verdict | IN("FAIL","ERROR"))
  and (.count | type == "number" and . >= 0 and . == floor) and (.repeated | type == "boolean");
def audit_loop_class:
  if type != "array" or any(.[]; audit_loop_round | not) then error("invalid audit rounds")
  else [.[] | select(.verdict == "FAIL")] as $fails
    | if length >= 2 and all(.[-2:][]; .verdict == "ERROR") then "infra"
      elif ($fails | length) < 2 then "none"
      else audit_loop_compare_counts($fails[-2].count; $fails[-1].count; $fails[-1].repeated) end
  end;
def audit_loop_history_rounds:
  [.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR")) | .outcome
   | if .verdict == "ERROR" then {verdict,count:0,repeated:false}
     else (.history_review // {dispositions:[],findings:[]}) as $review
       | ([$review.dispositions[] | select(.status | IN("open","not_assessed")) | .id]
          + [$review.findings[] | select(.id != "NEW") | .id] | unique) as $known
       | {verdict,repeated:($known | length > 0),
          count:(($known | length) + ([$review.findings[] | select(.id == "NEW")] | length))}
     end];

# Read-only progress diagnostics. A pattern never grants action or audit authority.
def audit_loop_rounds_valid:
  type == "array" and length <= 16 and all(.[];
    type == "object" and keys == ["findings","kind"]
    and (.kind | IN("PASS","FAIL","ERROR","CANCELED","IN_PROGRESS","OVERRIDDEN"))
    # Registry capacity plus one conservative gap per possible attempt.
    and (.findings | type == "array" and length <= (128 + 16)
      and ([.[].id] | length == (unique | length)) and all(.[];
      type == "object" and keys == ["id","severity"]
      and (.id | type == "string" and length > 0 and utf8bytelength <= 2048
        and (test("[[:cntrl:]]") | not))
      and (.severity | IN("critical","high")))));
def audit_loop_view_valid:
  type == "object" and keys == ["history_complete","rounds"]
  and (.history_complete | type == "boolean") and (.rounds | audit_loop_rounds_valid);
def audit_loop_severity: if . == "high" then "high" else "critical" end;
def audit_loop_merge_findings:
  group_by(.id) | map({id:.[0].id,
    severity:(if any(.[]; .severity == "critical") then "critical" else "high" end)});
def audit_loop_classify:
  if (audit_loop_view_valid | not) then error("invalid audit loop view") else . end
  | .rounds as $rounds | [$rounds[] | select(.kind == "FAIL")] as $failed
  | ($rounds[-1] // {kind:"",findings:[]}) as $last
  | {pattern:(if $last.kind == "PASS" then "complete"
      elif $last.kind == "OVERRIDDEN" then "overridden"
      elif $last.kind == "CANCELED" then "canceled"
      elif $last.kind == "IN_PROGRESS" then "partial"
      elif $last.kind == "ERROR" then
        if $rounds[-2].kind == "ERROR" then "infra" else "error" end
      elif ($failed | length) < 2 then "initial"
      else audit_loop_compare_counts(($failed[-2].findings | length); ($failed[-1].findings | length);
        any($failed[-1].findings[]; .id as $id | any($failed[-2].findings[]; .id == $id))) end),
    blocking_count:($last.findings | length),
    critical_ids:([$last.findings[] | select(.severity == "critical") | .id] | unique),
    history_complete,
    compared_failures:([$failed | length, 2] | min)};

# Reconstruct each round from accepted dispositions and stable registry identities.
# ERROR/cancellation retain findings; an opaque legacy failure stays unverified.
def audit_loop_history_view:
  .registry as $registry
  | reduce .attempts[] as $attempt ({rounds:[],open:[],history_complete:true};
      $attempt.outcome as $outcome
      | if $outcome == null then . else
          if $outcome.verdict == "PASS" then .open=[] | .history_complete=true
          elif ($outcome.verdict | IN("FAIL","IN_PROGRESS")) then
            if $outcome.history_review == null then
              .history_complete=false
              | .open += [{id:("untracked:" + $attempt.id),severity:"critical"}]
            else .open as $prior
              | ([$prior[] | select(.id | startswith("untracked:"))]
                + [$outcome.history_review.dispositions[]
                  | select(.status | IN("open","not_assessed")) | .id as $id
                  | ([$prior[] | select(.id == $id)][0] // {id:$id,severity:"critical"})]
                + [$outcome.history_review.findings[] | . as $finding
                  | (if .id == "NEW" then
                      [$registry[] | select(.invariant == $finding.invariant and .behavior == $finding.behavior)][0].id
                     else .id end) as $id
                  | {id:$id,severity:(.severity | audit_loop_severity)}])
                as $open
              | .open=($open | audit_loop_merge_findings)
            end
          else . end
          | .rounds += [{kind:$outcome.verdict,findings:.open}]
        end)
  | {rounds,history_complete};

def audit_loop_design_findings:
  map(. as $line | {id:$line,
    severity:(if startswith("high:") then "high" else "critical" end)})
  | audit_loop_merge_findings;
def audit_loop_design_view:
  if .verdict == "PASS" then {rounds:[{kind:"PASS",findings:[]}],history_complete:true}
  elif .verdict == "OVERRIDDEN" then {rounds:[{kind:"OVERRIDDEN",findings:[]}],history_complete:true}
  elif .verdict != "FAIL" then {rounds:[],history_complete:true}
  elif .progress != null then .progress
  else {rounds:[{kind:"FAIL",findings:(.findings | audit_loop_design_findings)}],
    history_complete:((.failures | length) <= 1)} end;
def audit_loop_design_record($verdict; $findings):
  (if .verdict == "FAIL" then audit_loop_design_view else {rounds:[],history_complete:true} end)
  | if $verdict == "PASS" then {rounds:[{kind:"PASS",findings:[]}],history_complete:true}
    else .rounds += [{kind:$verdict,findings:($findings | audit_loop_design_findings)}]
      | if (.rounds | length) > 16 then .history_complete=false | .rounds=.rounds[-16:] else . end
    end;
