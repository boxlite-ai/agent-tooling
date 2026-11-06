# The Standard of Code Review

## TL;DR

Favor changes that improve overall code health while allowing useful progress; require technical evidence rather than personal preference.

## Approval standard

- Balance developer progress with the reviewer's responsibility for consistent, maintainable code.
- Approve a change that clearly improves overall code health even when it is imperfect.
- Do not delay useful improvements for optional polish; mark such comments `Nit:`.
- A well-designed feature can still be rejected when it does not belong in the system.
- Do not accept declining code health except under the upstream [emergency process](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/emergencies.md).

Use [What to look for](looking-for.md) to assess the change.

## Mentoring

- Share useful language, framework, and design knowledge.
- Mark purely educational feedback as optional when it is unnecessary to meet the review standard.

## Principles {#principles}

| Concern | Rule |
| --- | --- |
| Evidence | Technical facts and data outweigh opinions. |
| Style | Follow the applicable [style guide](http://google.github.io/styleguide/); otherwise retain existing style or accept the author's when none exists. |
| Design | Compare engineering principles and evidence; respect the author's preference among equally valid options. |
| Consistency | Follow existing conventions when no stronger rule applies and doing so preserves code health. |

## Resolving Conflicts {#conflicts}

1. Seek agreement using this guide, [the author's guide](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/developer/index.md), and [the reviewer guide](index.md).
2. If comments stall, discuss directly and record the outcome on the change for future readers.
3. If unresolved, seek a team, technical lead, maintainer, or engineering-manager decision rather than leaving the change idle.

Next: [What to look for in a code review](looking-for.md)
