# Shared audit-loop classifier (design #563). The design gate and the commit/push checkpoint reduce their history to
# rounds and ask one question: is this loop still getting closer to PASS?
#
# A round is {verdict, count, repeated}:
#   verdict   "FAIL" or "ERROR"; PASS and canceled rounds never appear
#   count     blocking findings left open by a FAIL round; 0 for ERROR
#   repeated  true when a FAIL round re-raised a finding an earlier round raised
def audit_loop_round: type == "object" and (.verdict | IN("FAIL","ERROR"))
  and (.count | type == "number" and . >= 0 and . == floor) and (.repeated | type == "boolean");

# Input: rounds, oldest first. Output: one class.
#   "none"        nothing to compare yet
#   "converging"  the latest FAIL left fewer blocking findings than the FAIL before it
#   "stalled"     not fewer, and the latest FAIL repeated a finding
#   "churning"    not fewer, and every finding in the latest FAIL is new
#   "infra"       the last two rounds both ended in ERROR
def audit_loop_class:
  if type != "array" or any(.[]; audit_loop_round | not) then error("invalid audit rounds")
  else
    ([.[] | select(.verdict == "FAIL")] | .[-2:]) as $fails
    | if length >= 2 and all(.[-2:][]; .verdict == "ERROR") then "infra"
      elif ($fails | length) < 2 then "none"
      elif $fails[1].count < $fails[0].count then "converging"
      elif $fails[1].repeated then "stalled" else "churning" end
  end;

# A history gate's rounds: each failed attempt's unresolved registry IDs plus its new
# findings. An ID the registry already held counts as a repeat.
def audit_loop_history_rounds:
  [.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR")) | .outcome
   | if .verdict == "ERROR" then {verdict, count:0, repeated:false}
     else (.history_review // {dispositions:[], findings:[]}) as $review
       | ([$review.dispositions[] | select(.status | IN("open","not_assessed")) | .id]
          + [$review.findings[] | select(.id != "NEW") | .id] | unique) as $known
       | {verdict, repeated:($known | length > 0),
          count:(($known | length) + ([$review.findings[] | select(.id == "NEW")] | length))}
     end];
