# Speed of Code Reviews

## TL;DR

Respond promptly at natural breaks, keep reviews moving, and preserve the review standard.

## Why Should Code Reviews Be Fast? {#why}

- Optimize team throughput: delayed reviews hold up features, fixes, and dependent work.
- Slow responses make necessary rework more frustrating and discourage cleanup.
- Prompt feedback reduces pressure to accept lower-quality changes.

## How Fast Should Code Reviews Be? {#fast}

- Review shortly after a request arrives when you are free of focused work.
- The upstream target is a response within one business day, allowing multiple review rounds per day when practical.

## Speed vs. Interruption {#interruption}

- Preserve focused coding time; switching tasks has a recovery cost.
- Respond at a natural break, such as finishing a task, returning from lunch, or leaving a meeting.

## Fast Responses {#responses}

- Prioritize quick individual responses throughout review, even when the whole review takes longer.
- If busy, give an expected review time, suggest another reviewer, or offer [initial design feedback](navigate.md).
- Send even a brief response at a reasonable break rather than interrupting focused work.
- Spend enough time to ensure approval means the code meets [the standard](standard.md).

## Cross-Time-Zone Reviews {#tz}

- Respond while the author can still act during their workday when possible.
- Otherwise, aim to finish before their next workday begins.

## LGTM With Comments {#lgtm-with-comments}

The upstream process permits approval with unresolved comments under these conditions; local requirements in the skill entrypoint still govern.

| Condition | Reviewer action |
| --- | --- |
| Confident the author will address remaining comments | State that expectation. |
| Remaining comments are optional | Label them optional. |
| Only minor corrections remain | Identify them, such as import sorting, typos, or unused dependencies. |

This can avoid an unnecessary extra day between reviewers in different time zones.

## Large CLs {#large}

- Request [smaller dependent changes](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/developer/small-cls.md) when a change is too large to review promptly.
- If splitting is impractical, send overall design feedback so the author can make progress while review continues.
- Keep unblocking the author compatible with code health.

## Code Review Improvements Over Time {#time}

- Clear standards help authors submit changes requiring less rework.
- Fast responses reduce review latency; sacrificing [standards](standard.md) for apparent speed does not.

## Emergencies

Upstream permits expedited review and relaxed quality guidance only for [qualifying emergencies](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/emergencies.md#what).

Next: [How to Write Code Review Comments](comments.md)
