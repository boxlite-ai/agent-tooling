# How to write code review comments

## TL;DR

Give respectful, actionable feedback that explains the reason and distinguishes required changes from suggestions.

## Summary

- Be kind and explain your reasoning.
- Balance direct guidance with room for the developer to choose a solution.
- Prefer clearer code or useful source comments over explanations confined to review.

## Courtesy

- Be [courteous and respectful](https://chromium.googlesource.com/chromium/src/+/master/docs/cr_respect.md), especially during disagreement.
- Comment on the code and its consequences; avoid judging the developer.

| Avoid | Prefer |
| --- | --- |
| “Why did you use threads here?” | “This concurrency adds complexity without a demonstrated performance benefit; single-threaded code would be simpler.” |

## Explain Why {#why}

Explain the intent, engineering principle, or code-health benefit when the reason for a suggestion is unclear.

## Giving Guidance {#guidance}

- The developer owns the fix; reviewers need not design or implement every solution.
- Identify the problem and leave room for the developer's closer knowledge of the code.
- Give direct suggestions or code when that helps produce a better change.
- Reinforce good practices, such as clearer algorithms or useful test coverage, and explain [why](#why) they help.

## Label comment severity {#label-comment-severity}

Label intent so authors can prioritize feedback without treating every comment as mandatory.

| Label | Meaning |
| --- | --- |
| Nit | Minor polish. |
| Optional / Consider | Suggested improvement. |
| FYI | Information for future work; no change expected here. |

## Accepting Explanations {#explanations}

- When code needs explanation, usually ask for clearer code; a useful comment can explain a necessary mechanism.
- Avoid comments that merely narrate unnecessary complexity.
- Keep explanations useful to future readers in the source.
- Review-only explanations suffice when they cover background normal readers would already know.

Next: [Handling Pushback in Code Reviews](pushback.md)
