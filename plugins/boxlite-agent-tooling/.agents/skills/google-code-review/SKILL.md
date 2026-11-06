---
name: google-code-review
description: Review code using Google's engineering practices and the repository's own requirements.
license: CC-BY-3.0
---

## Review

Apply Google's review guidance to the assigned change; preserve the caller's scope and repository contracts.

1. Read the standard, coverage, and navigation references below before reviewing.
2. Establish intent and constraints; inspect the main changes first, then every assigned file in its surrounding context.
3. Compare viable designs using `boxlite-design-doc`'s option-selection principles; weigh technical evidence over personal preference.
4. Support findings with source locations, triggering conditions, and consequences; distinguish required changes from optional improvements.
5. Use the caller's required review format; report incomplete coverage and missing evidence explicitly.

For example, an optional naming preference is a nit; classify a missing regression check under the caller's evidence and deadline policies.

## References

The [guide index](references/reviewer/index.md) links the condensed reviewer guide.

| Read | When |
| --- | --- |
| [The Standard of Code Review](references/reviewer/standard.md) | Every review: code health, technical evidence, style, and equally valid choices |
| [What to Look For](references/reviewer/looking-for.md) | Every review: design, functionality, complexity, tests, names, comments, style, documentation, and context |
| [Navigating a CL](references/reviewer/navigate.md) | Every review: broad intent, main changes, remaining scope |
| [Writing Comments](references/reviewer/comments.md) | When writing findings or feedback |
| [Handling Pushback](references/reviewer/pushback.md) | When reconciling disagreement |
| [Review Speed](references/reviewer/speed.md) | When discussing review timing or handoffs |

## Local application

Repository and caller requirements govern where upstream process advice differs.

| Upstream convention | Local application |
| --- | --- |
| Google style guides | Use the repository's style rules; consult Google guidance only where compatible. |
| Equally valid designs | Apply the design skill's selection principles first; respect the author's preference among equally supported remaining options. |
| Early feedback or partial review | Complete the assigned audit scope, even after a blocker; report any unchecked required area using the caller's contract. |
| LGTM with unresolved work or emergencies | Never waive required evidence, security checks, approvals, or blocking findings. |
| Comment labels and teaching | Preserve the caller's severity and output format; personal preferences and purely educational points remain nonblocking. |
| Timing, escalation, and other reviewers | Follow the caller's deadlines and permissions; upstream advice grants no authority to publish, contact people, or delegate. |

## Source and license

Adapted by BoxLite from Google's Engineering Practices, [How to do a code review](https://github.com/google/eng-practices/tree/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/reviewer).
Source revision: `3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c`.
This adaptation and the condensed guide retain [CC BY 3.0](LICENSE); the complete upstream license is included.

Reviewer prose is condensed into checklists and tables; external guide links point to the pinned upstream revision.
This entrypoint adds reference routing and repository-specific application rules.
