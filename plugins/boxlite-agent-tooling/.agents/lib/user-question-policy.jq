def user_question_policy($prefix):
  if $prefix | IN("commit-audit-decision:", "push-audit-decision:") then
    {template:"questions/timed-question-git-audit", fallback:"reflect-again",
      choices:["Reflect again", "Stop"]}
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

def user_question_design_choices:
  user_question_policy("design-decision:").choices | join("|");

def user_question_design_pattern:
  "^(" + user_question_design_choices + ")\\s+\\S";

def user_question_directive:
  capture("\\A(?<prefix>\\S+:) (?<id>[0-9a-f]{32}) (?<answer>[^\\r\\n]+)\\z");

def user_question_answer_valid($prefix):
  if $prefix == "design-decision:" then test(user_question_design_pattern)
  elif $prefix == "reviewed:" then test("\\S")
  else . as $answer | user_question_policy($prefix).choices | index($answer) != null end;
