def user_question_policy($prefix):
  if $prefix | IN("commit-audit-decision:", "push-audit-decision:") then
    {template:"questions/timed-question-git-audit", fallback:"reflect-again",
      choices:["Reflect again", "Stop"], recommended:true}
  else
    {
      "pr-size-exception:": {template:"questions/timed-question-size", fallback:"split",
        choices:["Bypass limit", "Split PR"]},
      "reviewed:": {template:"questions/timed-question-review", fallback:"keep-draft",
        choices:["Keep draft", "Show diff"]},
      "design-decision:": {template:"questions/timed-question-design", fallback:"keep-blocked",
        choices:["Redesign", "Reflect again", "Overrule"]}
    }[$prefix]
  end;

def user_question_labels($policy):
  $policy.choices | if $policy.recommended then .[0] += " (Recommended)" else . end;

# Choices are fixed labels from the policy, with no regex operators.
def user_question_design_choices:
  user_question_policy("design-decision:").choices | join("|");

def user_question_design_pattern:
  "^design-decision: (?<choice>" + user_question_design_choices + ")\\s+\\S";

def user_question_git_pattern($prefix; $id):
  "^" + $prefix + " " + $id + " (" + (user_question_policy($prefix).choices | join("|")) + ")$";

def user_question_git_reply:
  capture("^(?<kind>commit|push)-audit-decision: (?<id>[0-9a-f]{32}) ") as $binding |
  select(test(user_question_git_pattern($binding.kind + "-audit-decision:"; $binding.id))) |
  $binding + {text:.};
